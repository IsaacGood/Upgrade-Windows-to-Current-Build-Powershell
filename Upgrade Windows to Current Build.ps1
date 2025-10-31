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
    - In the same folder, open the most recent CompatData_<datestamp>.xml and check for any items with BlockingType="Hard"
    - Run 'chkdsk /f', 'dism /Online /Cleanup-Image /CheckHealth', 'sfc /scannow' (in that order) to try and fix corruption/filesystem issues.
    - On rare occasions, virtual printer drivers have caused issues, you can remove them with the following commands:
        Remove-Printer -Name "Microsoft Print to PDF"
        Remove-Printer -Name "Microsoft XPS Document Writer"
    - If there's an error in setuperr.log: "Error encountered while adding provisioned APPX package: The package repository is corrupted."
      you can try running this, rebooting and trying upgrade again: https://github.com/mardahl/PSBucket/blob/master/invoke-StateRepositoryReset.ps1
    - If the setup fails before rebooting, try running the Update Assistant interactively. It is important to use right-click and "Run as administrator", bizarrely it has worked when script has not.
    - If you get "You can't install Windows on a USB flash drive using Setup" Error:  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PortableOperatingSystem' -Value 0

Future development ideas:
    - Write attempted method to file/reg and then progressively try next method/alert if failed on next script run
    - Integrate ISO upgrade script as another fallback method

Changelog:
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
$UpgradeWindows10 = $true

# Set uninstall window, in days (10-60, default 10)
$UninstallWindow = '10'

# Free disk space needed before using Update Assistant method
# Failures observed with <20GB free for build updates and <40GB free for 10 to 11 upgrades
$DiskSpaceRequired = '40' # in GBs

# Reboot after upgrade (if changing this to $false also set $AttemptUpdateAssistant to $false)
$RebootAfterUpgrade = $true
[int]$RebootDelay = '5' # in minutes
$RebootWarningMessage = "Your computer needs to restart to complete an update, please save your work. It will restart automatically in $RebootDelay minutes if you do not do so manually."

# Attempt Cumulative Update if UBR is not new enough for enablement
$AttemptCumulativeUpdate = $true

# Attempt Update Assistant method if enablement fails/not possible
# $true can cause a reboot regardless of reboot setting above as UA forces a restart
$AttemptUpdateAssistant = $true

# Handle Windows Update Blocks from ProductVersion/TargetRelease registry settings
$IgnoreRegistryBlocks = $false # Allows script to run, but leaves registry settings in place
$RemoveRegistryBlocks = $false # Removes registry settings so future upgrades aren't blocked

# How long to wait before assuming something went wrong and exiting.
# Depending on the machine and bandwidth upgrades can take up to several hours.
$TimeToWaitForCompletion = '180' # in minutes

# Disable Privacy Settings Experience at first sign-in (optional)
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE /f /v DisablePrivacyExperience /t REG_DWORD /d 1 | Out-Null

# Latest version of Windows currently available
# This is ONLY for determining if updates are needed, not for selecting which version to install
# If invoked by script logic, Update Assistant will always install the latest version available
# To install a previous version, you need to use the ISO upgrade method (not included in this script, yet)
$Win11LatestVersion = "25H2"

# Enablement Packages
$Win11EPURLx64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/fa84cc49-18b2-4c26-b389-90c96e6ae0d2/public/windows11.0-kb5054156-x64_a0c1638cbcf4cf33dbe9a5bef69db374b4786974.msu'
$Win11EPURLARM64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/78b265e5-83a8-4e0a-9060-efbe0bac5bde/public/windows11.0-kb5054156-arm64_3d5c91aaeb08a87e0717f263ad4a61186746e465.msu'
$Win11EPRequiredBuild = "26100"
$Win11EPRequiredUBR = "5074"

# Cumulative Updates required for Enablement Packages
$Win11CUKB = 'KB5065426'
$Win11CUURLx64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/7342fa97-e584-4465-9b3d-71e771c9db5b/public/windows11.0-kb5065426-x64_32b5f85e0f4f08e5d6eabec6586014a02d3b6224.msu'
$Win11CUURLARM64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/9107423f-d969-4584-b66d-d71bda583ee7/public/windows11.0-kb5065426-arm64_a41360977755965f6afa21f6a39dc0adaeff326a.msu'
$Win11CURequiredBuild = "26100"
$Win11CURequiredUBR = "863"

# Update Assistants
$Win11UAURL = 'https://go.microsoft.com/fwlink/?LinkID=2171764'

# Location to download files
$TargetFolder = "$env:Temp"

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
    Start-Sleep 10 # Give us a chance to view output when running interactively
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
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
    $DownloadSize = (Invoke-WebRequest $URL -Method Head -UseBasicParsing).Headers.'Content-Length'
    Write-Output "Downloading: $URL ($([math]::round($DownloadSize/1MB, 2)) MB)`nDestination: $TargetFolder\$FileName..."
    # Check if file already exists
    if ($DownloadSize -ne (Get-ItemProperty $TargetFolder\$FileName -ErrorAction SilentlyContinue).Length) {
        Start-BitsTransfer -Source $URL -Destination $TargetFolder\$FileName -Priority Normal -TransferPolicy Unrestricted
        # Verify download success
        $DownloadSizeOnDisk = (Get-ItemProperty $TargetFolder\$FileName -ErrorAction SilentlyContinue).Length
        if ($DownloadSize -ne $DownloadSizeOnDisk) {
            Remove-Item $TargetFolder\$FileName
            Exit-WithError "Download size ($DownloadSize) and size on disk ($DownloadSizeOnDisk) do not match, download failed."
        }
    } else { Write-Output 'File with same size already exists at download target.' }
}

function Invoke-CumulativeUpdate {
    # Determine destination filename
    $KBFile = [io.path]::GetFileName("$KBURL")
    try { Get-Download -URL $KBURL -TargetFolder $TargetFolder -FileName $KBFile }
    catch { Exit-WithError "Cumulative Update download failed: $($_.Exception.Message)" }
    Start-Process -FilePath "WUSA.exe" -ArgumentList "$TargetFolder\$KBFile /quiet /norestart"
    # WUSA.exe only kicks off the update, so -Wait has no affect, we have to monitor event log instead
    $BeginTime = Get-Date
    Write-Output "Waiting for Cumulative Update to install..."
    while ($null -eq ((New-Object -ComObject 'Microsoft.Update.Session').QueryHistory("", 0, 1) | Where-Object { $_.Date -gt $BeginTime -and $_.Title -like "*$KB*" }) -and $minutes -lt $TimeToWaitForCompletion) {
        Start-Sleep 60
        $minutes = $minutes + 1
    }
    if (((New-Object -ComObject 'Microsoft.Update.Session').QueryHistory("", 0, 1) | Where-Object { $_.Date -gt $BeginTime -and $_.Title -like "*$KB*" }).ResultCode -eq "4") {
        Exit-WithError "Cumulative Update install failed."
    } else {
        Remove-Item $TargetFolder\$KBFile
        if ($minutes -eq $TimeToWaitForCompletion) {
            Exit-WithError "It's been over $TimeToWaitForCompletion minutes, something probably went wrong. Here's the Windows Update event logs:`n$((Get-EventLog -Log 'System' -Source 'Microsoft-Windows-WindowsUpdateClient' -After $BeginTime -ErrorAction SilentlyContinue).Message)"
        } else {
            Write-Output "Cumulative Update has completed successfully."
            Clear-Alert
        }
        Invoke-Reboot
    }
}

function Invoke-EnablementUpgrade {
    # Determine destination filename
    $CABFile = [io.path]::GetFileName("$EPURL")
    try { Get-Download -URL $EPURL -TargetFolder $TargetFolder -FileName $CABFile }
    catch { Exit-WithError "Enablement package download failed: $($_.Exception.Message)" }
    try {
        Write-Output "Adding the enablement package to the image..."
        $Arguments = "/Online /Add-Package /PackagePath:$TargetFolder\$CABFile /Quiet /NoRestart"
        $Process = Start-Process 'dism.exe' -ArgumentList $Arguments -PassThru -Wait -NoNewWindow
        if ($Process.ExitCode -eq '3010') {
            Write-Output "Exit Code 3010: Package added successfully."
            Clear-Alert
        } elseif ($null -ne $Process.StdError) {
            Exit-WithError "DISM error: $($Process.StdError)"
        }
        Remove-Item $TargetFolder\$CABFile
    } catch {
        Write-Output "Enablement package install failed. Error: $($_.exception.Message)"
        if ($AttemptUpdateAssistant) {
            Write-Output "Attempting Update Assistant method instead."
            Invoke-UpdateAssistant
        } else { Exit-WithError "Error: $($_.exception.Message)" }
    }
    Invoke-Reboot
}

function Invoke-UpdateAssistant {
    # Check for free space
    $DiskSpace = [Math]::Round((Get-CimInstance -Class Win32_Volume | Where-Object { $_.DriveLetter -eq $env:SystemDrive } | Select-Object -ExpandProperty FreeSpace) / 1GB)
    if ($DiskSpace -lt $DiskSpaceRequired) {
        Exit-WithError "Only $DiskSpace GB free, $DiskSpaceRequired GB required."
    } else {
        # Retrieve headers to make sure we have the actual file URL after any redirections
        $UAURL = (Invoke-WebRequest -UseBasicParsing -Uri $UAURL -MaximumRedirection 0 -ErrorAction Ignore).headers.location
        # Determine destination filename
        $UAFile = [io.path]::GetFileName("$UAURL")
        try { Get-Download -URL $UAURL -TargetFolder $TargetFolder -FileName $UAFile }
        catch { Exit-WithError "Update Assistant download failed: $($_.Exception.Message)" }
        if (-not (Test-Path "$TargetFolder\$UAFile")) {
            Exit-WithError "Update Assistant download file not found."
        } else {
            Write-Output "Update Assistant download successful, starting upgrade."
            if ((Get-Process 'Windows10UpgraderApp' -ErrorAction SilentlyContinue).Count -gt 0) {
                Exit-WithError "Update Assistant already running, wait for it to complete or reboot and try again."
            } else {
                try {
                    $Arguments = "/QuietInstall /SetPriorityLow /SkipEULA /CopyLogs $TargetFolder"
                    Start-Process "$TargetFolder\$UAFile" -ArgumentList "$Arguments"
                    Start-Sleep -s 120
                    Remove-Item "$TargetFolder\$UAFile" -Force
                } catch { Exit-WithError "Update Assistant error: $($_.exception.Message)" }
                Write-Output "Waiting for Update Assistant to complete..."
                $BeginTime = Get-Date
                while ((Get-EventLog -Log 'System' -Source 'Microsoft-Windows-Kernel-General' -EntryType 'Information' -InstanceId '16' -After $BeginTime -ErrorAction SilentlyContinue | Where-Object { $_.Message -like '*NewOS\WINDOWS\System32\config\BCD-Template*' }).Count -eq 0 -and $minutes -lt $TimeToWaitForCompletion) {
                    if ((Get-EventLog -Log 'Application' -Source 'Windows Error Reporting' -EntryType 'Information' -InstanceId '1001' -After $BeginTime -ErrorAction SilentlyContinue).Message -match 'WinSetupDiag') {
                        Exit-WithError "Update Assistant has failed, try running interactively."
                    } elseif ((Get-EventLog -Log 'Application' -Source 'Application Error' -EntryType 'Error' -InstanceId '1000' -After $BeginTime -ErrorAction SilentlyContinue).Message -match 'Faulting application name: setuphost.exe') {
                        Invoke-Reboot
                        Exit-WithError "SetupHost.exe failed. Windows may need a reboot (doing so now if enabled), then try running script again."
                    }
                    Start-Sleep 60
                    $minutes = $minutes + 1
                }
                if ($minutes -eq $TimeToWaitForCompletion) {
                    Exit-WithError "It's been over $TimeToWaitForCompletion minutes, something probably went wrong. Here's the Windows Update event logs:`n$((Get-EventLog -Log 'System' -Source 'Microsoft-Windows-WindowsUpdateClient' -After $BeginTime -ErrorAction SilentlyContinue).Message)"
                } else {
                    Write-Output "Update Assistant completed successfully."
                    Clear-Alert
                }
                Invoke-Reboot
            }
        }
    }
}

### END FUNCTIONS / START MAIN SCRIPT ###

# Get OS/version/build info
$MajorVersion = ([System.Environment]::OSVersion.Version).Major
$CurrentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$DisplayVersion = $CurrentVersion.DisplayVersion

# Get build and UBR (we keep separate as UBR can be 3 or 4 digits which confuses comparison operators in combined form)
$Build = $CurrentVersion.CurrentBuildNumber
$UBR = $CurrentVersion.UBR

# Set MajorVersion
if ($Build -ge 22000) { $MajorVersion = '11' }

# Set variables based on OS version
switch ($MajorVersion) {
    {10,11} {
        $WinLatestVersion = $Win11LatestVersion
        $EPRequiredBuild = $Win11EPRequiredBuild; $EPRequiredUBR = $Win11EPRequiredUBR
        $CURequiredBuild = $Win11CURequiredBuild; $CURequiredUBR = $Win11CURequiredUBR
        $KB = $Win11CUKB; $UAURL = $Win11UAURL; $EPURL = $Win11EPURLx64
        if ((Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture -like "ARM*") {
            $EPURL = $Win11EPURLARM64; $KBURL = $Win11CUURLARM64
        } else { $EPURL = $Win11EPURLx64; $KBURL = $Win11CUURLx64;}
    }
}

Write-Output "Windows $MajorVersion $DisplayVersion build $Build.$UBR detected."

# Convert versions to numerical form so comparison operators can be used
$DisplayVersionNumerical = ($DisplayVersion).replace('H1', '05').replace('H2', '10')
$WinLatestVersionNumerical = ($WinLatestVersion).replace('H1', '05').replace('H2', '10')

# Create the $TargetFolder directory if it doesn't exist
if (-not (Test-Path -Path "$TargetFolder" -PathType Container)) {
    New-Item -Path "$TargetFolder" -ItemType Directory | Out-Null
}

# Set uninstall window
reg add "HKLM\SYSTEM\Setup" /f /v UninstallWindow /t REG_DWORD /d $UninstallWindow | Out-Null

# Remove Windows Update ProductVersion/TargetRelease registry settings
$WUPolicyRegLocation = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\'
if ($RemoveRegistryBlocks -eq $true -and ((Get-Item $WUPolicyRegLocation -ErrorAction SilentlyContinue).Property -like "TargetReleaseVersion*")) {
    Remove-ItemProperty $WUPolicyRegLocation -Name 'ProductVersion' -ErrorAction SilentlyContinue
    Remove-ItemProperty $WUPolicyRegLocation -Name 'TargetReleaseVersion' -ErrorAction SilentlyContinue
    Remove-ItemProperty $WUPolicyRegLocation -Name 'TargetReleaseVersionInfo' -ErrorAction SilentlyContinue
    Write-Output "ProductVersion/TargetRelease registry settings were found and removed."
}

# Ineligible Upgrade Conditions
if ($CurrentVersion.InstallationType -ne 'Client') {
    Write-Output "Device is not running a client OS."
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

# Eligible Upgrade Conditions
if ($AttemptCumulativeUpdate -eq $true -and
    $Build -ge $EPRequiredBuild -and $UBR -lt $EPRequiredUBR -and
    $Build -ge $CURequiredBuild -and $UBR -ge $CURequiredUBR) {
    Write-Output "Windows $MajorVersion UBR's older than $EPRequiredUBR cannot be upgraded with enablement package. Installing required Cumulative Update."
    Invoke-CumulativeUpdate
} elseif ($Build -ge $EPRequiredBuild -and $UBR -ge $EPRequiredUBR -and
    $Build -ne '22631') {
    Invoke-EnablementUpgrade
} elseif ($AttemptUpdateAssistant -eq $true) {
    Write-Output "Build is not compatible with enablement upgrade, attempting Update Assistant method instead."
    Invoke-UpdateAssistant
} elseif ($MajorVersion -lt '11' -and $UpgradeWindows10 -eq $true -and $AttemptUpdateAssistant -eq $true) {
    Write-Output "Upgrading Windows 10 using Update Assistant method."
    Invoke-UpdateAssistant
} else {
    Exit-WithError "Eligibility logic failed, check script for issues."
}
