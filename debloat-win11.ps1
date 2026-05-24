#Requires -RunAsAdministrator
<#
Debloat-Windows11-Appx.ps1

Removes selected Windows 11 inbox / consumer Appx packages from:
  1. Existing users
  2. Provisioned image, so future users do not receive them

Use:
  .\Debloat-Windows11-Appx.ps1 -WhatIfMode
  .\Debloat-Windows11-Appx.ps1

Tested approach:
  - Get-AppxPackage -AllUsers
  - Remove-AppxPackage -AllUsers
  - Get-AppxProvisionedPackage -Online
  - Remove-AppxProvisionedPackage -Online
#>

[CmdletBinding()]
param(
    [switch]$WhatIfMode,

    [string]$LogPath = "$env:SystemDrive\Windows\Temp\Debloat-Windows11-Appx.log"
)

$ErrorActionPreference = 'Continue'

$Targets = @(
    # Common consumer / promotional apps
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',

    # New Outlook / Mail related
    'Microsoft.OutlookForWindows',
    'microsoft.windowscommunicationsapps',

    # Teams variants
    'MicrosoftTeams',
    'MSTeams',

    # Xbox / gaming
    'Microsoft.GamingApp',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',

    # Windows 11 Notepad (Store app) – replaced below with classic notepad.exe
    'Microsoft.WindowsNotepad',

    # Optional / often unwanted
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MixedReality.Portal',
    'Microsoft.SkypeApp',
    'Microsoft.549981C3F5F10',             # Cortana, older builds
    'MicrosoftCorporationII.MicrosoftFamily'
)

# Things I would not remove by default.
# Add to $Targets manually only if you are sure.
$ProtectedExamples = @(
    'Microsoft.WindowsStore',
    'Microsoft.StorePurchaseApp',
    'Microsoft.DesktopAppInstaller',
    'Microsoft.WindowsCalculator',
    'Microsoft.Windows.Photos',
    'Microsoft.Paint',
    'Microsoft.SecHealthUI',
    'Microsoft.ScreenSketch',
    'Microsoft.HEIFImageExtension',
    'Microsoft.VP9VideoExtensions',
    'Microsoft.WebMediaExtensions',
    'Microsoft.WebpImageExtension'
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Remove-InstalledAppxForExistingUsers {
    param(
        [string]$PackageName
    )

    $packages = Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue

    if (-not $packages) {
        Write-Log "Installed Appx not found for existing users: $PackageName"
        return
    }

    foreach ($pkg in $packages) {
        if ($pkg.NonRemovable) {
            Write-Log "Skipping non-removable package: $($pkg.PackageFullName)" 'WARN'
            continue
        }

        Write-Log "Removing installed Appx for existing users: $($pkg.PackageFullName)"

        if ($WhatIfMode) {
            Write-Log "WHATIF: Remove-AppxPackage -AllUsers -Package '$($pkg.PackageFullName)'"
        }
        else {
            try {
                Remove-AppxPackage -AllUsers -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Log "Removed installed Appx: $($pkg.PackageFullName)"
            }
            catch {
                Write-Log "Failed to remove installed Appx $($pkg.PackageFullName): $($_.Exception.Message)" 'ERROR'
            }
        }
    }
}

function Remove-ProvisionedAppxForFutureUsers {
    param(
        [string]$PackageName
    )

    $provisioned = Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -eq $PackageName }

    if (-not $provisioned) {
        Write-Log "Provisioned Appx not found for future users: $PackageName"
        return
    }

    foreach ($pkg in $provisioned) {
        Write-Log "Removing provisioned Appx for future users: $($pkg.PackageName)"

        if ($WhatIfMode) {
            Write-Log "WHATIF: Remove-AppxProvisionedPackage -Online -PackageName '$($pkg.PackageName)'"
        }
        else {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                Write-Log "Removed provisioned Appx: $($pkg.PackageName)"
            }
            catch {
                Write-Log "Failed to remove provisioned Appx $($pkg.PackageName): $($_.Exception.Message)" 'ERROR'
            }
        }

    }
}

function Set-OldRightClickMenuForAllUsers {
    $classicMenuClsid = '{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $keyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\$classicMenuClsid\InprocServer32"

    Write-Log "Configuring classic right-click menu for all existing and new users."

    if ($WhatIfMode) {
        Write-Log "WHATIF: New-Item -Path '$keyPath' -Force"
        Write-Log "WHATIF: Set-ItemProperty -Path '$keyPath' -Name '(default)' -Value ''"
        return
    }

    try {
        New-Item -Path $keyPath -Force | Out-Null
        Set-ItemProperty -Path $keyPath -Name '(default)' -Value ''
        Write-Log "Classic right-click menu configured at machine scope."
    }
    catch {
        Write-Log "Failed to configure classic right-click menu: $($_.Exception.Message)" 'ERROR'
    }
}

function Set-ClassicNotepadShellNew {
    <#
    .SYNOPSIS
        Restores right-click "New Text Document" and sets classic notepad.exe as the
        default .txt opener via HKLM, covering all existing and future users.
    #>

    $notepadPath = "$env:SystemRoot\System32\notepad.exe"

    Write-Log "Restoring right-click 'New Text Document' using classic notepad.exe ($notepadPath)."

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would set HKLM:.txt\ShellNew NullFile and txtfile open command to '$notepadPath'"
        return
    }

    try {
        # Right-click New > Text Document (applies to all users via HKLM)
        $shellNewPath = 'HKLM:\SOFTWARE\Classes\.txt\ShellNew'
        if (-not (Test-Path $shellNewPath)) {
            New-Item -Path $shellNewPath -Force | Out-Null
        }
        New-ItemProperty -Path $shellNewPath -Name 'NullFile' -Value '' -PropertyType String -Force | Out-Null
        Write-Log "Set ShellNew NullFile for .txt (all users)"

        # Ensure .txt default ProgID is txtfile
        $txtPath = 'HKLM:\SOFTWARE\Classes\.txt'
        New-ItemProperty -Path $txtPath -Name '' -Value 'txtfile' -PropertyType String -Force | Out-Null

        # Ensure txtfile opens with classic notepad.exe
        $openCmdPath = 'HKLM:\SOFTWARE\Classes\txtfile\shell\open\command'
        if (-not (Test-Path $openCmdPath)) {
            New-Item -Path $openCmdPath -Force | Out-Null
        }
        New-ItemProperty -Path $openCmdPath -Name '' -Value "`"$notepadPath`" `"%1`"" -PropertyType String -Force | Out-Null
        Write-Log "Set txtfile open command: `"$notepadPath`" `"%1`""
    }
    catch {
        Write-Log "Failed to restore classic Notepad ShellNew: $($_.Exception.Message)" 'ERROR'
    }
}

Write-Log "Starting Windows 11 Appx debloat."
Write-Log "Log file: $LogPath"

if ($WhatIfMode) {
    Write-Log "Running in WhatIfMode. No changes will be made." 'WARN'
}

Write-Log "Target package count: $($Targets.Count)"

foreach ($target in $Targets) {
    Write-Log "Processing target: $target"

    Remove-InstalledAppxForExistingUsers -PackageName $target
    Remove-ProvisionedAppxForFutureUsers -PackageName $target
}

Set-OldRightClickMenuForAllUsers

Write-Log "Finished Windows 11 Appx debloat."

Set-ClassicNotepadShellNew

Write-Host ''
Write-Host 'Verification commands:'
Write-Host '  Get-AppxPackage -AllUsers | Sort-Object Name | Select-Object Name, PackageFullName'
Write-Host '  Get-AppxProvisionedPackage -Online | Sort-Object DisplayName | Select-Object DisplayName, PackageName'
Write-Host '  Get-ItemProperty "HKLM:\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"'
