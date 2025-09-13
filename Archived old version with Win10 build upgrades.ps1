<# Upgrade Windows 10 & 11 to Current Build
https://github.com/IsaacGood/Upgrade-Windows-to-Current-Build-Powershell/

This script will attempt to upgrade in various ways depending on the current version installed
and the options selected below. Assuming all methods are allowed, it will:
    - Exit if less than Windows 10 or already on current build or build is incompatible with all allowed methods.
    - If the build is compatible with enablement, it applies the enablement CAB file. If that fails, it attempts the Update Assistant method.
    - If the build is compatible with enablement but the UBR is not, it attempts to install the required cumulative update.
    - If the build is incompatible with enablement (too old or 24H2) it attempts to upgrade via Update Assistant.

Notes:
    - Read all the variables and make sure they're set appropriately for your environment!
    - This script is optimized for Syncro RMM but runs without error on other platforms.
      If you wish to remove/replace Syncro references, they're all in the Exit-WithError and Clear-Alert functions.
    - Make sure to increase the script timeout in your RMM to longer than your
      $TimeToWaitForCompletion + download time or you won't get full output in logs.
      Keep in mind depending on your RMM, it's possible no other scripts will run until it completes/times out.
    - For some reason silent install for Windows 11 Update Assistant doesn't work well in
      ScreenConnect Backstage, but works ok from RMM (usually).

Future development ideas:
    - Write attempted method to file/reg and then progressively try next method/alert if failed on next script run
    - Set UpgradeEligibility registry key to avoid needing PC Health Check?
    - Use scheduled task for running Win11 upgrade?
    - Option for Start-BitsTransfer -TransferPolicy Unrestricted
    - Options to allow upgrade from 7 to 10/11, 10 to 11
    - Integrate ISO upgrade script as another fallback method
    - Integrate DISM upgrade method?

Changelog:
  1.3 / 2024-10-09
        Changed - $Win11LatestVersion = 24H2
        Added - Support for Win11 24H2 via Update Assistant (no enablement available)
        Added - Support for ARM64 CPU enablement package
        Added - Option to remove Windows Update Target Release Version registry settings (option to ignore only still exists)
        Added - $RebootDelay variable and output of delay used
        Added - $RebootWarningMessage variable to inform user of pending reboot
        Fixed - Added decimal places to download function so enablement packages don't show as 0 MB
	Fixed - Added TLS protocol settings to Get-Download to fix SSL error with some devices
        Fixed - Corrected output for 'Already current or newer' condition to use $WinLatestVersion instead of $Win10LatestVersion
  1.2 / 2023-11-19
        Changed - Refactored to use more functions & variables (less redundant code)
        Changed - Minimum build for enablement to 19042.1865 for 22H2
        Changed - $Win1xTargetVersion to $Win1xLatestVersion to clarify they are only for determining if updates are needed
        Added - Windows 11 Update Assistant & 23H2 enablement capabilities
        Added - Optional installation of cumulative updates required for enablement packages
        Added - Error catching and notification for failed downloads
        Removed - Windows 10 21H2 enablement packages (end of servicing 6/13/2023)
        Fixed - Wrapped Syncro commands in if's to eliminate errors when used with other platforms or in testing
1.1.1 / 2023-08-04
        Fixed - TargetReleaseVersion registry check had no Write-Output
  1.1 / 2023-08-03
        Changed - Syncro Alert name to 'Upgrade Windows', update any Automated Remediations accordingly
        Changed - Improved error catching and notification
        Added - Groundwork for support for Windows 11 (no enablement packages yet and UA won't upgrade under SYSTEM user)
        Added - General code cleanup, improved consistency and documentation
        Added - Support for Windows 10 x86 and 21H2 enablement packages
        Fixed - Correct enablement minimum build (from 1247 to 1237)
        Fixed - Removed UBR 1237 requirement for non-enablement that was causing script to fail on 18362.1856
  1.0 / 2022-12-08 - Initial release
#>

# Reboot after upgrade (if changing this to $false also set $AttemptUpdateAssistant to $false)
$RebootAfterUpgrade = $true
[int]$RebootDelay = '5' # in minutes
$RebootWarningMessage = "Your computer needs to restart to complete an update, please save your work. It will restart automatically in $RebootDelay minutes if you do not do so manually."

# Attempt Cumulative Update if UBR is not new enough for enablement
$AttemptCumulativeUpdate = $true

# Attempt Update Assistant method if enablement fails/not possible
# $true can cause a reboot regardless of reboot setting above as UA forces a restart
$AttemptUpdateAssistant = $true

# Ignore Windows Update TargetReleaseVersion registry settings
$IgnoreTargetReleaseVersion = $false

# Remove Windows Update TargetReleaseVersion registry settings
$RemoveTargetReleaseVersion = $false

# Location to download files
$TargetFolder = "$env:Temp"

# How long to wait before assuming something went wrong and exiting.
# Depending on the machine and bandwidth upgrades can take up to several hours.
$TimeToWaitForCompletion = '180' # in minutes

# Disable Privacy Settings Experience at first sign-in (optional)
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE /f /v DisablePrivacyExperience /t REG_DWORD /d 1 | Out-Null

# Latest version of Windows currently available (for determining if updates are needed)
$Win10LatestVersion = "22H2"
$Win11LatestVersion = "24H2"

# Enablement Packages (Windows 11 x86 doesn't exist)
$Win10EPURLx64 = 'https://catalog.s.download.windowsupdate.com/c/upgr/2022/07/windows10.0-kb5015684-x64_d2721bd1ef215f013063c416233e2343b93ab8c1.cab'
$Win10EPURLx86 = 'https://catalog.s.download.windowsupdate.com/c/upgr/2022/07/windows10.0-kb5015684-x86_3734a3f6f4143b645788cc77154f6288c8054dd5.cab'
$Win10EPRequiredBuild = "19042"
$Win10EPRequiredUBR = "1865"
$Win11EPURLx64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/49a41627-758a-42b7-8786-cc61cc19f1ee/public/windows11.0-kb5027397-x64_955d24b7a533f830940f5163371de45ff349f8d9.cab'
$Win11EPURLARM64 = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/719ca7b9-26eb-4de4-a45b-04ad2b58c807/public/windows11.0-kb5027397-arm64_1f7d9a4314296e4c35879d5438167ba7b60d895f.cab'
$Win11EPRequiredBuild = "22621"
$Win11EPRequiredUBR = "2506"

# Cumulative Updates required for Enablement Packages
$Win10CUKB = 'KB5026361'
$Win10CUURL = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2023/05/windows10.0-kb5026361-x64_961f439d6b20735f067af766e1813936bf76cb94.msu'
$Win10CURequiredBuild = "19042"
$Win10CURequiredUBR = "985"
$Win11CUKB = 'KB5032190'
$Win11CUURL = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/cd35ece3-585a-48e9-a9b5-ad5cd3699d32/public/windows11.0-kb5032190-x64_fdbd38c60e7ef2c6adab4bf5b508e751ccfbd525.msu'
$Win11CURequiredBuild = "22621"
$Win11CURequiredUBR = "521"

# Update Assistants
$Win10UAURL = 'https://go.microsoft.com/fwlink/?LinkID=799445'
$Win11UAURL = 'https://go.microsoft.com/fwlink/?LinkID=2171764'

# Windows Update Policy registry location
$WUPolicyRegLocation = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\'

### END OF VARIABLES / START FUNCTIONS ###

if ($null -ne $env:SyncroModule) { Import-Module $env:SyncroModule -DisableNameChecking }

function Exit-WithError {
    param ( $Text )
    Write-Output $Text
    if (Get-Module | Where-Object { $_.ModuleBase -match 'Syncro' }) {
        Rmm-Alert -Category "Upgrade Windows" -Body $Text
    }
    Start-Sleep 10 # Give us a chance to see the error when running interactively
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
        Start-BitsTransfer -Source $URL -Destination $TargetFolder\$FileName -Priority Normal
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
    $DiskSpaceRequired = '11' # in GBs
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

# Get version/build info
# 19041 and older do not have DisplayVersion key, if so we grab ReleaseID instead (no longer updated in new versions)
$MajorVersion = ([System.Environment]::OSVersion.Version).Major
$CurrentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
if ($CurrentVersion.DisplayVersion) {
    $DisplayVersion = $CurrentVersion.DisplayVersion
} else { $DisplayVersion = $CurrentVersion.ReleaseId }

# Get build and UBR (we keep separate as UBR can be 3 or 4 digits which confuses comparison operators in combined form)
$Build = $CurrentVersion.CurrentBuildNumber
$UBR = $CurrentVersion.UBR

# Correct Microsoft's version number for Windows 11
if ($Build -ge 22000) { $MajorVersion = '11' }

# Set variables based on OS version
switch ($MajorVersion) {
    10 {
        $WinLatestVersion = $Win10LatestVersion
        $EPRequiredBuild = $Win10EPRequiredBuild; $EPRequiredUBR = $Win10EPRequiredUBR
        $CURequiredBuild = $Win10CURequiredBuild; $CURequiredUBR = $Win10CURequiredUBR
        $KB = $Win10CUKB; $KBURL = $Win10CUURL; $UAURL = $Win10UAURL
        if ([Environment]::Is64BitOperatingSystem) {
            $EPURL = $Win10EPURLx64
        } else { $EPURL = $Win10EPURLx86 }
    }
    11 {
        $WinLatestVersion = $Win11LatestVersion
        $EPRequiredBuild = $Win11EPRequiredBuild; $EPRequiredUBR = $Win11EPRequiredUBR
        $CURequiredBuild = $Win11CURequiredBuild; $CURequiredUBR = $Win11CURequiredUBR
        $KB = $Win11CUKB; $KBURL = $Win11CUURL; $UAURL = $Win11UAURL; $EPURL = $Win11EPURLx64
        if ((Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture -like "ARM*") {
            $EPURL = $Win11EPURLARM64
        } else { $EPURL = $Win11EPURLx64 }
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

# Remove Windows Update TargetReleaseVersion registry settings
if ($RemoveTargetReleaseVersion -eq $true -and ((Get-Item $WUPolicyRegLocation).Property -like "TargetReleaseVersion*")) {
    Remove-ItemProperty $WUPolicyRegLocation -Name 'TargetReleaseVersion' -ErrorAction SilentlyContinue
    Remove-ItemProperty $WUPolicyRegLocation -Name 'TargetReleaseVersionInfo' -ErrorAction SilentlyContinue
    Write-Output "TargetReleaseVersion registry settings were found and removed."
}

# Ineligible Upgrade Conditions
if ($MajorVersion -lt '10') {
    Write-Output "Windows versions prior to 10 cannot be updated with this script."
    Start-Sleep 10; exit 0
} elseif ($DisplayVersionNumerical -ge $WinLatestVersionNumerical) {
    Write-Output "Already running $DisplayVersion which is the same or newer than target release $WinLatestVersion, no update required."
    Clear-Alert
    Start-Sleep 10; exit 0
} elseif ($AttemptCumulativeUpdate -eq $false -and $AttemptUpdateAssistant -eq $false -and
    $Build -lt $EPRequiredBuild -and $UBR -lt $EPRequiredUBR) {
    Exit-WithError "Windows $MajorVersion builds older than $EPRequiredBuild.$EPRequiredUBR cannot be upgraded with enablement package and Cumulative Update/Update Assistant methods are disabled."
} elseif ($IgnoreTargetReleaseVersion -eq $false -and (Test-Path $WUPolicyRegLocation) -eq $true) {
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
} else {
    Exit-WithError "Eligibility logic failed, check script for issues."
}
