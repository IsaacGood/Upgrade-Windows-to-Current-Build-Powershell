<# Upgrade Windows to Current Build
https://github.com/IsaacGood/Upgrade-Windows-to-Current-Build-Powershell/

This script will attempt to upgrade in various ways depending on the current version installed
and the options selected below. Assuming all methods are allowed, it will:
    - Exit if already on current build or build is incompatible with all allowed methods.
    - If the build is compatible with enablement, it applies the enablement MSU file. If that fails, it attempts the Update Assistant method.
    - If the build is compatible with enablement but the UBR is not, it attempts to install the required cumulative update so that enablement can be applied after the next reboot.
    - If the build is incompatible with enablement it attempts to upgrade via Update Assistant.
    - If Windows 10 and $UpgradeWindows10 = $true, it uses Update Assistant to upgrade to 11.

Notes:
    - Read all the variables and make sure they're set appropriately for your environment!
    - Make sure to increase the script timeout in your RMM to longer than your
      $TimeToWaitForCompletion + download time or you won't get full output in logs.
      Keep in mind depending on your RMM, it's possible no other scripts will run until it completes/times out.
    - For some reason silent install for Windows 11 Update Assistant doesn't work well in
      ScreenConnect Backstage, but works ok from RMM (usually).

If you have issues upgrading, here are some things to check in order of commonality:
    - The script output and any errors therein.
    - Verify the device meets the Secure Boot, TPM, and CPU requirements and check the experience
      indicators: https://www.deploymentresearch.com/understanding-upgrade-experience-indicators-for-windows-11-upgrade-readiness/
    - Check for BIOS and driver updates from the hardware vendor.
    - Western Digital NVMe SSD models SN580 and SN770 need a firmware update, use Sandisk Dashboard to update
    - Check for corrupt/leftover/unneeded user profiles in c:\Users\ and HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList and remove them.
    - Check for Windows Safeguard/Feature Blocks:
        https://github.com/AdamGrossTX/FU.WhyAmIBlocked
        https://garytown.com/windows-safeguard-hold-id-lookup-crowd-sourced
        https://www.asquaredozen.com/2020/07/26/demystifying-windows-10-feature-update-blocks/
    - Check c:\$Windows.~BT\Sources\Panther\setuperr.log for clues/error codes to look up.
    - In the same folder, open the most recent CompatData_<datestamp>.xml and check for any items with BlockingType="Hard" or BlockMigration="True"
	    Get-ChildItem CompatData*.xml | Select-String 'BlockMigration="True"','BlockingType="Hard"'
    - Run 'chkdsk /f', 'dism /Online /Cleanup-Image /CheckHealth', 'sfc /scannow' (in that order) to try and fix corruption/filesystem issues.
    - On rare occasions, virtual printer drivers have caused issues, you can remove them with the following commands:
        Disable-WindowsOptionalFeature -Online -FeatureName Printing-PrintToPDFServices-Features
        Disable-WindowsOptionalFeature -Online -FeatureName Printing-XPSServices-Features
    - If there's an error in setuperr.log: "Error encountered while adding provisioned APPX package: The package repository is corrupted."
      you can try running this, rebooting and trying upgrade again: https://github.com/mardahl/PSBucket/blob/master/invoke-StateRepositoryReset.ps1
    - If the setup fails before rebooting, try running the Update Assistant interactively. It is important to use right-click and "Run as administrator", bizarrely it has worked when script has not.
    - If you get "You can't install Windows on a USB flash drive using Setup" Error:  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PortableOperatingSystem' -Value 0

Future development ideas:
    - Write attempted method to file/reg and then progressively try next method/alert if failed on next script run
    - Integrate ISO upgrade script as another fallback method

Changelog:
  2.2 / 2026-11-24
        Added - Handling 26H1 as a special case due to it being a weird release only for new devices and not eligible for 26H2, hopefully it will be normal for 27H2
        Added - Update Assistant method improvements including preventing automatic reboot and check for required AC power
        Added - Variable to choose if downloads are allowed over metered connections
        Added - Variable to choose whether to disable the Privacy Settings Experience at first sign-in (OOBE)
        Added - Comments clarifying code and logic behind it
        Changed - 26H2 enablement packages, required cumulative updates and build numbers
        Changed - Improved DISM exit code handling/reporting
        Changed - Cumulative Update method now uses DISM and falls back to Update Assistant like Enablement does
        Changed - Enablement apply failure now falls back to Update Assistant method in catch block as well as for DISM error exit code
        Fixed - Windows LTSC/IoT editions are now properly identified as an ineligible
        Fixed - Moved registry changes for uninstall window and privacy experience to after ineligibility checks so they don't get set unnecessarily
        Fixed - Set variables to integers/booleans instead of strings to avoid comparison issues
        Fixed - Don't attempt Update Assistant method on ARM devices
        Removed - No longer needed eligibility block for 22631 (23H2)
  2.1 / 2025-10-30
        Added - 25H2 enablement packages, required cumulative updates and build numbers (now does CU for ARM64 also)
        Added - More troubleshooting notes
        Added - Clarification that WUA always installs latest version, $Win11LatestVersion is ONLY for determining if update is needed
        Fixed - Restored missing code for determining RMM environment
  2.0 / 2025-08-16 - Initial release of Windows 11 only version
        Added - Check for client OS name so upgrade is not attempted on servers
        Added - Variable for setting number of days for upgrade uninstall window
        Changed - $DiskSpaceRequired to 40GB, this seems sufficient for all 10 to 11 upgrades, you might be able to get by with 30ish depending on the machine
        Changed - Bypass Windows metered connection restriction by adding '-TransferPolicy Unrestricted' to Start-BitsTransfer in Get-Download function
        Fixed - Remove ProductVersion registry setting along with TargetRelease/Version (optional)
        Fixed - Use -ErrorAction SilentlyContinue on Get-ItemProperty for TargetReleaseVersion removal to avoid error if not present
#>

# Upgrade Windows 10 to 11
[bool]$UpgradeWindows10 = $true

# Set uninstall window, in days (10-60, default 10)
[int]$UninstallWindow = 10

# Free disk space needed before using Update Assistant method
# Failures observed with <20GB free for build updates and <40GB free for 10 to 11 upgrades
[int]$DiskSpaceRequired = 40 # in GBs

# Reboot after upgrade
[bool]$RebootAfterUpgrade = $false
[int]$RebootDelay = 5 # in minutes
$RebootWarningMessage = "Your computer needs to restart to complete an update, please save your work. It will restart automatically in $RebootDelay minutes if you do not do so manually."

# Attempt Cumulative Update if UBR is not new enough for enablement
# Then the next time the script runs hopefully enablement will be possible,
# avoiding the need for Update Assistant which is a larger download and forces a reboot
[bool]$AttemptCumulativeUpdate = $true

# Attempt Update Assistant method if enablement fails/not possible
[bool]$AttemptUpdateAssistant = $true

# Allow downloading updates over metered connections like cellular
[bool]$AllowMeteredDownload = $true 

# Handle Windows Update Blocks from ProductVersion/TargetRelease registry settings
[bool]$IgnoreRegistryBlocks = $false # Allows script to run, but leaves registry settings in place
[bool]$RemoveRegistryBlocks = $false # Removes registry settings so future upgrades aren't blocked

# How long to wait before assuming something went wrong and exiting.
# Depending on the machine and bandwidth upgrades can take up to several hours.
[int]$TimeToWaitForCompletion = 180 # in minutes

# Disable Privacy Settings Experience at first sign-in
[bool]$DisablePrivacyExperience = $true

# Latest version of Windows currently available
# This is ONLY for determining if updates are needed, not for selecting which version to install
# If invoked by script logic, Update Assistant will always install the latest version available
# To install a previous version, you need to use the ISO upgrade method (not included in this script, yet)
$Win11LatestVersion = "26H2"

# Enablement Packages
$Win11EPURLx64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/94520a88-858f-4832-a57d-7211f6d84a4e/public/Windows11.0-KB5121794-x64_5e20a3cce48d6611b16bdec42b07167f5456586a.msu'
$Win11EPURLARM64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/9d8dc3d0-9cbf-4eb1-9411-722e3e6a19b3/public/Windows11.0-KB5121794-arm64_77a76caf2d362bb293a4d18058388f2717365abe.msu'
[int]$Win11EPRequiredBuild = 26100 # matches equal or greater
[int]$Win11EPRequiredUBR = 9278 # matches equal or greater

# Cumulative Updates required for Enablement Packages
$Win11CUKB = 'KB5120998'
$Win11CUURLx64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/7416ff4e-4741-42fb-a16b-0a92e2dfc42b/public/windows11.0-kb5120998-x64_5cdebefaecf780c7487e56a0d5472830a24a673a.msu'
$Win11CUURLARM64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/14103cad-d3d4-452e-a112-1d6fecfe3167/public/windows11.0-kb5120998-arm64_383aa004fabf4946be5f4f6a6cf9200c6b7d2a5e.msu'
[int]$Win11CURequiredBuild = 26100 # matches equal or greater
[int]$Win11CURequiredUBR = 863 # matches equal or greater

# Update Assistants
$Win11UAURL = 'https://go.microsoft.com/fwlink/?LinkID=2171764'

# File download location
$TargetFolder = "$env:Temp"

# Windows Update policy location
$WUPolicyRegLocation = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\'

### END OF VARIABLES / START FUNCTIONS ###

# Determine if running in Datto RMM or Syncro
$Datto = Get-Service | Where-Object { $_.DisplayName -match 'Datto RMM' }
$Syncro = Get-Module | Where-Object { $_.ModuleBase -match 'Syncro' }
if ($Syncro) { Import-Module $env:SyncroModule -DisableNameChecking }

function Exit-WithError {
    param ($Text)
    if ($Datto) {
        Write-Output "<-Start Result->Alert=$Text<-End Result->"
    } elseif ($Syncro) {
        Write-Output $Text
        Rmm-Alert -Category "Upgrade Windows" -Body $Text
    } else {
        Write-Output $Text
    }
    if ([Environment]::UserInteractive) { Start-Sleep 10 } # Give us a chance to view output when running interactively
    exit 1
}

function Clear-Alert {
    if (Get-Module | Where-Object { $_.ModuleBase -match 'Syncro' }) {
        Close-Rmm-Alert -Category "Upgrade Windows"
    }
}

function Invoke-Reboot {
    if ($RebootAfterUpgrade) {
        Write-Output "Reboot variable enabled, rebooting in $RebootDelay minutes."
        # If Automatic Restart Sign-On is enabled, /g allows the device to automatically sign in and lock
        # based on the last interactive user. After sign in, it restarts any registered applications.
        shutdown /g /f /t $($RebootDelay * 60) /c $RebootWarningMessage
        exit
    }
}

function Get-Download {
    param ($URL, $TargetFolder, $FileName)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $DownloadSize = (Invoke-WebRequest $URL -Method Head -UseBasicParsing).Headers.'Content-Length'
    Write-Output "Downloading: $URL ($([math]::round($DownloadSize/1MB, 2)) MB)`nDestination: $TargetFolder\$FileName..."
    # Check if file already exists
    if ($DownloadSize -ne (Get-ItemProperty $TargetFolder\$FileName -ErrorAction SilentlyContinue).Length) {
        $TransferPolicy = if ($AllowMeteredDownload) { 'Unrestricted' } else { 'Standard' }
        Start-BitsTransfer -Source $URL -Destination $TargetFolder\$FileName -Priority Normal -TransferPolicy $TransferPolicy
        # Verify download success
        $DownloadSizeOnDisk = (Get-ItemProperty $TargetFolder\$FileName -ErrorAction SilentlyContinue).Length
        if ($DownloadSize -ne $DownloadSizeOnDisk) {
            Remove-Item $TargetFolder\$FileName
            Exit-WithError "Download size ($DownloadSize) and size on disk ($DownloadSizeOnDisk) do not match, download failed."
        }
    } else { Write-Output 'File with same size already exists at download target.' }
}
function Install-Package {
    param ($PackagePath)
    $Arguments = "/Online /Add-Package /PackagePath:`"$PackagePath`" /Quiet /NoRestart"
    (Start-Process 'dism.exe' -ArgumentList $Arguments -PassThru -Wait -NoNewWindow -ErrorAction Stop).ExitCode
}

function Invoke-CumulativeUpdate {
    # Determine destination filename
    $KBFile = [io.path]::GetFileName("$KBURL")
    try { Get-Download -URL $KBURL -TargetFolder $TargetFolder -FileName $KBFile }
    catch { Exit-WithError "Cumulative Update download failed: $($_.Exception.Message)" }
    Write-Output "Installing Cumulative Update $KB, this can take a while..."
    try { $ExitCode = Install-Package -PackagePath $TargetFolder\$KBFile; $Message = "DISM exit code $ExitCode." }
    catch { $ExitCode = -1; $Message = "Error: $($_.Exception.Message)" }  
    if ($ExitCode -in @(0, 3010)) {
        Write-Output "Cumulative Update install successful, $Message"
        Remove-Item $TargetFolder\$KBFile -Force -ErrorAction SilentlyContinue
        Clear-Alert
        Invoke-Reboot
    } elseif ($AttemptUpdateAssistant) {
        Write-Output "Cumulative Update install failed, $Message Attempting Update Assistant method instead."
        Invoke-UpdateAssistant
    } else {
        Exit-WithError "Cumulative Update install failed, $Message"
    }
}

function Invoke-EnablementUpgrade {
    # Determine destination filename
    $CABFile = [io.path]::GetFileName("$EPURL")
    try { Get-Download -URL $EPURL -TargetFolder $TargetFolder -FileName $CABFile }
    catch { Exit-WithError "Enablement package download failed: $($_.Exception.Message)" }
    Write-Output "Adding the enablement package to the image..."
    try { $ExitCode = Install-Package -PackagePath $TargetFolder\$CABFile; $Message = "DISM exit code $ExitCode." }
    catch { $ExitCode = -1; $Message = "Error: $($_.Exception.Message)" }    
    if ($ExitCode -in @(0, 3010)) {
        Write-Output "Package added successfully, $Message Reboot to complete upgrade."
        Remove-Item $TargetFolder\$CABFile -Force -ErrorAction SilentlyContinue
        Clear-Alert
        Invoke-Reboot
    } elseif ($AttemptUpdateAssistant) {
        Write-Output "Enablement package install failed, $Message Attempting Update Assistant method instead."
        Invoke-UpdateAssistant
    } else {
        Exit-WithError "Package adding failed, $Message"
    }
}

function Invoke-UpdateAssistant {
    if ($isARM -eq $true) {
        Exit-WithError "Update Assistant cannot be used on ARM devices."
    }
    if ((Get-Process 'Windows10UpgraderApp' -ErrorAction SilentlyContinue).Count -gt 0) {
        Exit-WithError "Update Assistant already running, wait for it to complete or reboot and try again."
    }
    $Battery = Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryStatus' -ErrorAction SilentlyContinue
    if ($Battery -and -not ($Battery | Where-Object { $_.PowerOnline })) {
        Exit-WithError "Device is running on battery power, Update Assistant requires AC power."
    }
    # Check for free space
    $DiskSpace = [Math]::Round((Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace / 1GB)
    if ($DiskSpace -lt $DiskSpaceRequired) {
        Exit-WithError "Only $DiskSpace GB free, $DiskSpaceRequired GB required."
    } 
    # Retrieve headers to make sure we have the actual file URL after any redirections
    $UAURL = (Invoke-WebRequest -UseBasicParsing -Uri $UAURL -MaximumRedirection 0 -ErrorAction Ignore).headers.location
    # Determine destination filename
    $UAFile = [io.path]::GetFileName("$UAURL")
    try { Get-Download -URL $UAURL -TargetFolder $TargetFolder -FileName $UAFile }
    catch { Exit-WithError "Update Assistant download failed: $($_.Exception.Message)" }
    if (-not (Test-Path "$TargetFolder\$UAFile")) {
        Exit-WithError "Update Assistant download failed, file not found."
    }
    Write-Output "Update Assistant download successful, starting upgrade."
    try {
        $BeginTime = Get-Date
        $Arguments = "/QuietInstall /SetPriorityLow /SkipEULA /CopyLogs $TargetFolder"
        Start-Process "$TargetFolder\$UAFile" -ArgumentList "$Arguments"
        Start-Sleep -s 120
        Remove-Item "$TargetFolder\$UAFile" -Force -ErrorAction SilentlyContinue
    } catch { Exit-WithError "Update Assistant error: $($_.exception.Message)" }
    Write-Output "Waiting for Update Assistant to complete..."
    # Monitor status of upgrade until errors found or all processes have exited for 3 minutes
    $Workers = 'DISMHost', 'SetupHost', 'SetupPrep'
    $Deadline = ($BeginTime).AddMinutes($TimeToWaitForCompletion)
    $Idle = 0
    $WorkersSeen = $false
    while ($Idle -lt 3) {
        if (Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; Id = 1001; StartTime = $BeginTime } -ErrorAction SilentlyContinue | Where-Object Message -match 'WinSetupDiag') {
            Exit-WithError "Update Assistant has failed, try running interactively."
        }
        if (Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $BeginTime } -ErrorAction SilentlyContinue | Where-Object Message -match 'Faulting application name: setuphost\.exe') {
            if ($RebootAfterUpgrade) { shutdown /g /f /t $($RebootDelay * 60) /c $RebootWarningMessage } # can't use Invoke-Reboot here because it will exit without surfacing the error
            Exit-WithError "SetupHost.exe failed. Windows may need a reboot (doing so now if enabled), then try running script again."
        }
        if ((Get-Date) -gt $Deadline) {
            $WULog = (Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; StartTime = $BeginTime } -ErrorAction SilentlyContinue).Message -join "`n"
            Exit-WithError "It's been over $TimeToWaitForCompletion minutes, unless Internet/machine is slow, something probably went wrong. Here's the recent Windows Update event logs:`n$WULog"
        }
        if (Get-Process -Name $Workers -ErrorAction SilentlyContinue) { $WorkersSeen = $true; $Idle = 0 } elseif ($WorkersSeen) { $Idle++ }
        if (-not (Get-Process -Name 'Windows10UpgraderApp' -ErrorAction SilentlyContinue)) { 
            Exit-WithError "Update Assistant process has prematurely exited, something went wrong."
        }
        Start-Sleep -Seconds 60
    }
    # Check if the upgrade staging was actually successful
    $Progress = (Get-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' -ErrorAction SilentlyContinue).SetupProgress
    if ($Progress -ne 100) {
        Exit-WithError "Upgrade did not complete (progress: $(if ($null -eq $Progress) { 'unknown' } else { "$Progress%" }))."
    }
    Write-Output 'Upgrade staging complete. Reboot to complete upgrade.'
    # Kill the Update Assistant process so it doesn't reboot automatically after 30mins
    Stop-Process -Name 'Windows10UpgraderApp' -Force -ErrorAction SilentlyContinue
    Clear-Alert
    Invoke-Reboot
}

### END FUNCTIONS / START MAIN SCRIPT ###

# Get OS/version/build info
$MajorVersion = ([System.Environment]::OSVersion.Version).Major
$CurrentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$EditionID = $CurrentVersion.EditionID
$DisplayVersion = $CurrentVersion.DisplayVersion
# Correct for 26H1 being a weird release only for new devices and not eligible for 26H2, hopefully it will be normal for 27H2
if ($DisplayVersion -eq '26H1') { $DisplayVersion = '26H2' }
# Check for ARM architecture, Update Assistant doesn't run on ARM and enablement packages are different
$IsARM = (Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture -like "ARM*"

# Get build and UBR (we keep separate as UBR can be 3 or 4 digits which confuses comparison operators in combined form)
[int]$Build = $CurrentVersion.CurrentBuildNumber
[int]$UBR = $CurrentVersion.UBR

# Set MajorVersion
if ($Build -ge 22000) { [int]$MajorVersion = '11' }

# Set variables based on OS version (structured this way in case we need to add Windows 12 in the future)
switch ($MajorVersion) {
    { $_ -in 10,11 } {
        $WinLatestVersion = $Win11LatestVersion
        $EPRequiredBuild = $Win11EPRequiredBuild; $EPRequiredUBR = $Win11EPRequiredUBR
        $CURequiredBuild = $Win11CURequiredBuild; $CURequiredUBR = $Win11CURequiredUBR
        $KB = $Win11CUKB; $UAURL = $Win11UAURL
        if ($IsARM) {
            $EPURL = $Win11EPURLARM64; $KBURL = $Win11CUURLARM64
        } else { $EPURL = $Win11EPURLx64; $KBURL = $Win11CUURLx64;}
    }
}

Write-Output "Windows $MajorVersion $DisplayVersion build $Build.$UBR detected."

# Convert versions to numerical form so comparison operators can be used
$DisplayVersionNumerical = ($DisplayVersion).replace('H1', '05').replace('H2', '10')
$WinLatestVersionNumerical = ($WinLatestVersion).replace('H1', '05').replace('H2', '10')

# Ineligible Upgrade Conditions
if ($CurrentVersion.InstallationType -ne 'Client') {
    Write-Output "Device is not running a client OS."
    Start-Sleep 10; exit 0
} elseif ($EditionID -in ('EnterpriseS', 'EnterpriseSN', 'IoTEnterpriseS', 'IoTEnterpriseSK')) {
    Write-Output "Windows $EditionID edition (LTSC/IoT) is not eligible for upgrading, exiting."
    Start-Sleep 10; exit 0
} elseif ($MajorVersion -lt '11' -and $UpgradeWindows10 -eq $false) {
    Write-Output "Upgrading Windows 10 is disabled in script variables, exiting."
    Start-Sleep 10; exit 0
} elseif ($DisplayVersionNumerical -ge $WinLatestVersionNumerical) {
    Write-Output "Already running $DisplayVersion which is the same or newer than target release $WinLatestVersion, no update required."
    Clear-Alert
    Start-Sleep 10; exit 0
} elseif ($AttemptCumulativeUpdate -eq $false -and $AttemptUpdateAssistant -eq $false -and
    $Build -lt $EPRequiredBuild -and $UBR -lt $EPRequiredUBR) {
    Exit-WithError "Windows $MajorVersion builds older than $EPRequiredBuild.$EPRequiredUBR cannot be upgraded with enablement package and Cumulative Update/Update Assistant methods are disabled."
} elseif ($IgnoreRegistryBlocks -eq $false -and (Test-Path $WUPolicyRegLocation) -eq $true) {
    $WindowsUpdateKey = Get-ItemProperty -Path $WUPolicyRegLocation -ErrorAction SilentlyContinue
    if ($WindowsUpdateKey.TargetReleaseVersion -eq 1 -and $WindowsUpdateKey.TargetReleaseVersionInfo) {
        $WindowsUpdateTargetReleaseNumerical = ($WindowsUpdateKey.TargetReleaseVersionInfo).replace('H1', '05').replace('H2', '10')
        if ($WindowsUpdateTargetReleaseNumerical -lt $winLatestVersionNumerical) {
            Exit-WithError "Windows Update TargetReleaseVersion registry settings are in place limiting upgrade to $($WindowsUpdateKey.TargetReleaseVersionInfo). These settings can be ignored or removed by changing the appropriate script variable and running again."
        }
    }
}

# Create the $TargetFolder directory if it doesn't exist
if (-not (Test-Path -Path "$TargetFolder" -PathType Container)) {
    New-Item -Path "$TargetFolder" -ItemType Directory | Out-Null
}

# Set uninstall window
reg add "HKLM\SYSTEM\Setup" /f /v UninstallWindow /t REG_DWORD /d $UninstallWindow | Out-Null

# Disable Privacy Settings Experience at first sign-in
if ($DisablePrivacyExperience -eq $true) {
    reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE /f /v DisablePrivacyExperience /t REG_DWORD /d 1 | Out-Null
}

# Remove Windows Update ProductVersion/TargetRelease registry settings
if ($RemoveRegistryBlocks -eq $true) {
    Remove-ItemProperty $WUPolicyRegLocation -Name 'ProductVersion' -ErrorAction SilentlyContinue
    Remove-ItemProperty $WUPolicyRegLocation -Name 'TargetReleaseVersion' -ErrorAction SilentlyContinue
    Remove-ItemProperty $WUPolicyRegLocation -Name 'TargetReleaseVersionInfo' -ErrorAction SilentlyContinue
    Write-Output "Windows Update ProductVersion/TargetRelease registry settings removed."
}

# Eligible Upgrade Conditions
if ($AttemptCumulativeUpdate -eq $true -and
    $Build -ge $EPRequiredBuild -and $UBR -lt $EPRequiredUBR -and
    $Build -ge $CURequiredBuild -and $UBR -ge $CURequiredUBR) {
    Write-Output "Windows $MajorVersion UBR's older than $EPRequiredUBR cannot be upgraded with enablement package. Installing required Cumulative Update."
    Invoke-CumulativeUpdate
} elseif ($Build -ge $EPRequiredBuild -and $UBR -ge $EPRequiredUBR) {
    Write-Output "Windows $MajorVersion build $Build.$UBR is compatible with enablement package, attempting upgrade."
    Invoke-EnablementUpgrade
} elseif ($MajorVersion -eq '11' -and $AttemptUpdateAssistant -eq $true) {
    Write-Output "Build is not compatible with enablement upgrade, attempting Update Assistant method instead."
    Invoke-UpdateAssistant
} elseif ($MajorVersion -eq '10' -and $UpgradeWindows10 -eq $true -and $AttemptUpdateAssistant -eq $true) {
    Write-Output "Upgrading Windows 10 using Update Assistant method."
    Invoke-UpdateAssistant
} else {
    Exit-WithError "Eligibility logic failed, check script for issues."
}
