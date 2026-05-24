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
    $clsidSubKey      = "SOFTWARE\Classes\CLSID\$classicMenuClsid"
    $fullKeyPath      = "Registry::HKEY_LOCAL_MACHINE\$clsidSubKey\InprocServer32"

    Write-Log "Configuring classic right-click menu for all existing and new users."

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would take ownership of HKLM:\$clsidSubKey and create InprocServer32 subkey with empty default value."
        return
    }

    # The CLSID key is owned by NT SERVICE\TrustedInstaller and is write-protected
    # even for elevated Administrator sessions.  We must:
    #   1. Enable SeTakeOwnershipPrivilege in the current process token.
    #   2. Take ownership of the parent CLSID key (new owner = Administrators).
    #   3. Grant Administrators FullControl so we can create the child subkey.

    if (-not ('RegistryPrivilege' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RegistryPrivilege {
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
        ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    const int SE_PRIVILEGE_ENABLED = 2, TOKEN_QUERY = 8, TOKEN_ADJUST_PRIVILEGES = 32;
    public static void Enable(string privilege) {
        IntPtr htok = IntPtr.Zero;
        OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle,
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
        TokPriv1Luid tp; tp.Count = 1; tp.Luid = 0; tp.Attr = SE_PRIVILEGE_ENABLED;
        LookupPrivilegeValue(null, privilege, ref tp.Luid);
        AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
    }

    $originalAcl = $null

    try {
        # Enable token privileges required for ownership transfer
        [RegistryPrivilege]::Enable('SeTakeOwnershipPrivilege')
        [RegistryPrivilege]::Enable('SeRestorePrivilege')

        $readAclKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $clsidSubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
            [System.Security.AccessControl.RegistryRights]::ReadPermissions
        )
        if (-not $readAclKey) { throw "Could not open CLSID key for reading original ACL." }
        $originalAcl = $readAclKey.GetAccessControl([System.Security.AccessControl.AccessControlSections]::All)
        $readAclKey.Close()

        $admSid = [System.Security.Principal.SecurityIdentifier]::new(
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

        # Step 1: take ownership of the CLSID key
        $ownerKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $clsidSubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership
        )
        if (-not $ownerKey) { throw "Could not open CLSID key for TakeOwnership." }
        $acl = $ownerKey.GetAccessControl([System.Security.AccessControl.AccessControlSections.None])
        $acl.SetOwner($admSid)
        $ownerKey.SetAccessControl($acl)
        $ownerKey.Close()

        # Step 2: grant Administrators FullControl (now that we own the key)
        $aclKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $clsidSubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions
        )
        if (-not $aclKey) { throw "Could not open CLSID key for ChangePermissions." }
        $acl = $aclKey.GetAccessControl()
        $rule = [System.Security.AccessControl.RegistryAccessRule]::new(
            $admSid,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        $aclKey.SetAccessControl($acl)
        $aclKey.Close()

        # Step 3: create InprocServer32 subkey with an empty default value
        New-Item -Path $fullKeyPath -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path $fullKeyPath -Name '(default)' -Value '' -ErrorAction Stop
        Write-Log "Classic right-click menu configured at machine scope."
    }
    catch {
        Write-Log "Failed to configure classic right-click menu: $($_.Exception.Message)" 'ERROR'
    }
    finally {
        if ($originalAcl) {
            try {
                $restoreKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                    $clsidSubKey,
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [System.Security.AccessControl.RegistryRights]::ChangePermissions
                )
                if ($restoreKey) {
                    $restoreKey.SetAccessControl($originalAcl)
                    $restoreKey.Close()
                    Write-Log "Restored original ACL and owner for HKLM:\$clsidSubKey."
                }
                else {
                    Write-Log "Could not reopen HKLM:\$clsidSubKey to restore ACL." 'WARN'
                }
            }
            catch {
                Write-Log "Failed to restore original ACL for HKLM:\${clsidSubKey}: $($_.Exception.Message)" 'WARN'
            }
        }
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
        if (-not (Test-Path $txtPath)) {
            New-Item -Path $txtPath -Force | Out-Null
        }
        Set-ItemProperty -Path $txtPath -Name '(default)' -Value 'txtfile' -Force

        # Ensure txtfile opens with classic notepad.exe
        $openCmdPath = 'HKLM:\SOFTWARE\Classes\txtfile\shell\open\command'
        if (-not (Test-Path $openCmdPath)) {
            New-Item -Path $openCmdPath -Force | Out-Null
        }
        Set-ItemProperty -Path $openCmdPath -Name '(default)' -Value "`"$notepadPath`" `"%1`"" -Force
        Write-Log "Set txtfile open command: `"$notepadPath`" `"%1`""
    }
    catch {
        Write-Log "Failed to restore classic Notepad ShellNew: $($_.Exception.Message)" 'ERROR'
    }
}

function Set-VisualEffectsProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveRoot,
        [Parameter(Mandatory = $true)]
        [string]$ScopeLabel
    )

    $animationEffects = @{
        ControlAnimations   = 0
        MenuAnimation       = 0
        ComboBoxAnimation   = 0
        ListBoxSmoothScrolling = 0
        TooltipAnimation    = 0
        SelectionFade       = 0
        TaskbarAnimations   = 0
        MinAnimate          = 0
    }

    $preservedEffects = @{
        DropShadow          = 1
        CursorShadow        = 1
        FontSmoothing       = 1
        DesktopComposition  = 1
        Themes              = 1
        ListviewShadow      = 1
    }

    $visualEffectsPath = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    $desktopPath = "$HiveRoot\Control Panel\Desktop"
    $windowMetricsPath = "$desktopPath\WindowMetrics"

    Write-Log "Applying visual-effects profile for $ScopeLabel (disable animations, keep shadows/font smoothing/wallpaper)."

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would set animation-related effects to disabled under '$visualEffectsPath'"
        Write-Log "WHATIF: Would set non-animation effects (including font smoothing and shadows) to enabled under '$visualEffectsPath'"
        Write-Log "WHATIF: Would set '$desktopPath\\DragFullWindows' to '1'"
        Write-Log "WHATIF: Would set '$desktopPath\\FontSmoothing' to '2'"
        Write-Log "WHATIF: Would set '$desktopPath\\FontSmoothingType' to 2"
        Write-Log "WHATIF: Would set '$windowMetricsPath\\MinAnimate' to '0'"
        foreach ($name in $animationEffects.Keys) {
            Write-Log "WHATIF: Would set '$visualEffectsPath\\$name\\DefaultApplied' to $($animationEffects[$name])"
        }
        foreach ($name in $preservedEffects.Keys) {
            Write-Log "WHATIF: Would set '$visualEffectsPath\\$name\\DefaultApplied' to $($preservedEffects[$name])"
        }
        return
    }

    try {
        New-Item -Path $visualEffectsPath -Force -ErrorAction Stop | Out-Null

        foreach ($entry in $animationEffects.GetEnumerator()) {
            $effectPath = "$visualEffectsPath\$($entry.Key)"
            New-Item -Path $effectPath -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $effectPath -Name 'DefaultApplied' -Value $entry.Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }

        foreach ($entry in $preservedEffects.GetEnumerator()) {
            $effectPath = "$visualEffectsPath\$($entry.Key)"
            New-Item -Path $effectPath -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $effectPath -Name 'DefaultApplied' -Value $entry.Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }

        New-Item -Path $desktopPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $desktopPath -Name 'DragFullWindows' -Value '1' -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $desktopPath -Name 'FontSmoothing' -Value '2' -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $desktopPath -Name 'FontSmoothingType' -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        New-Item -Path $windowMetricsPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $windowMetricsPath -Name 'MinAnimate' -Value '0' -PropertyType String -Force -ErrorAction Stop | Out-Null

        Write-Log "Visual-effects profile applied for $ScopeLabel."
    }
    catch {
        Write-Log ("Failed to apply visual-effects profile for {0}: {1}" -f $ScopeLabel, $_.Exception.Message) 'ERROR'
    }
}

function Set-VisualEffectsForAllUsers {
    Write-Log "Configuring visual effects for all existing and future users."

    $profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $userSids = Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
        Select-Object -ExpandProperty PSChildName -Unique

    foreach ($sid in $userSids) {
        $profileProps = Get-ItemProperty -Path "$profileListPath\$sid" -ErrorAction SilentlyContinue
        if (-not $profileProps.ProfileImagePath) {
            Write-Log "Skipping SID with no profile path: $sid" 'WARN'
            continue
        }

        $profilePath = [Environment]::ExpandEnvironmentVariables($profileProps.ProfileImagePath)
        $ntUserDatPath = Join-Path $profilePath 'NTUSER.DAT'
        if (-not (Test-Path $ntUserDatPath)) {
            Write-Log "Skipping SID '$sid'; NTUSER.DAT not found at '$ntUserDatPath'" 'WARN'
            continue
        }

        $loadedHivePath = "Registry::HKEY_USERS\$sid"
        if (Test-Path $loadedHivePath) {
            Set-VisualEffectsProfile -HiveRoot $loadedHivePath -ScopeLabel "loaded user SID $sid"
            continue
        }

        $mountName = "TEMP_USER_$($sid -replace '-', '_')"
        $mounted = $false
        try {
            if ($WhatIfMode) {
                Write-Log "WHATIF: reg.exe load HKU\\$mountName '$ntUserDatPath'"
                Set-VisualEffectsProfile -HiveRoot "Registry::HKEY_USERS\$mountName" -ScopeLabel "offline user SID $sid"
                Write-Log "WHATIF: reg.exe unload HKU\\$mountName"
            }
            else {
                & reg.exe load "HKU\$mountName" "$ntUserDatPath" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to load user hive for SID $sid from '$ntUserDatPath'" 'ERROR'
                    continue
                }

                $mounted = $true
                Set-VisualEffectsProfile -HiveRoot "Registry::HKEY_USERS\$mountName" -ScopeLabel "offline user SID $sid"
            }
        }
        finally {
            if ($mounted) {
                & reg.exe unload "HKU\$mountName" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to unload temporary hive HKU\\$mountName" 'WARN'
                }
            }
        }
    }

    $defaultProfileRoot = (Get-ItemProperty -Path $profileListPath -Name 'Default' -ErrorAction SilentlyContinue).Default
    if (-not $defaultProfileRoot) {
        $defaultProfileRoot = Join-Path $env:SystemDrive 'Users\Default'
    }
    else {
        $defaultProfileRoot = [Environment]::ExpandEnvironmentVariables($defaultProfileRoot)
    }

    $defaultProfileDat = Join-Path $defaultProfileRoot 'NTUSER.DAT'
    if (Test-Path $defaultProfileDat) {
        $defaultMountName = 'WDL_DefaultProfile'
        $mountedDefault = $false
        try {
            if ($WhatIfMode) {
                Write-Log "WHATIF: reg.exe load HKU\\$defaultMountName '$defaultProfileDat'"
                Set-VisualEffectsProfile -HiveRoot "Registry::HKEY_USERS\$defaultMountName" -ScopeLabel 'default user profile'
                Write-Log "WHATIF: reg.exe unload HKU\\$defaultMountName"
            }
            else {
                & reg.exe load "HKU\$defaultMountName" "$defaultProfileDat" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to load default user hive from '$defaultProfileDat'" 'ERROR'
                }
                else {
                    $mountedDefault = $true
                    Set-VisualEffectsProfile -HiveRoot "Registry::HKEY_USERS\$defaultMountName" -ScopeLabel 'default user profile'
                }
            }
        }
        finally {
            if ($mountedDefault) {
                & reg.exe unload "HKU\$defaultMountName" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to unload temporary hive HKU\\$defaultMountName" 'WARN'
                }
            }
        }
    }
    else {
        Write-Log "Default profile hive not found: $defaultProfileDat" 'WARN'
    }
}

function Set-EdgePolicyDefaultsForAllUsers {
    <#
    .SYNOPSIS
        Configures Microsoft Edge policies at HKLM for all existing and future users.
    #>

    $edgePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $homepage = 'https://google.com'

    Write-Log "Configuring Microsoft Edge machine-wide policies."

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would set Edge policy TranslateEnabled=0"
        Write-Log "WHATIF: Would set Edge policy HomepageLocation='$homepage'"
        Write-Log "WHATIF: Would set Edge policy HomepageIsNewTabPage=0"
        Write-Log "WHATIF: Would set Edge policy RestoreOnStartup=1 (restore previous session)"
        Write-Log "WHATIF: Would set Edge policy HubsSidebarEnabled=0 (disable Copilot chat/sidebar)"
        return
    }

    try {
        if (-not (Test-Path $edgePolicyPath)) {
            New-Item -Path $edgePolicyPath -Force | Out-Null
        }

        New-ItemProperty -Path $edgePolicyPath -Name 'TranslateEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $edgePolicyPath -Name 'HomepageLocation' -Value $homepage -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $edgePolicyPath -Name 'HomepageIsNewTabPage' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $edgePolicyPath -Name 'RestoreOnStartup' -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $edgePolicyPath -Name 'HubsSidebarEnabled' -Value 0 -PropertyType DWord -Force | Out-Null

        Write-Log "Configured Edge policies: translation disabled, homepage set to $homepage, restore previous session enabled, Copilot chat/sidebar disabled."
    }
    catch {
        Write-Log "Failed to configure Edge policies: $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-NewOutlookTaskbarPinForCurrentUser {
    Write-Log "Removing New Outlook taskbar pin for the current user (if present)."

    $taskbarPinDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would remove New Outlook .lnk files from '$taskbarPinDir' and invoke taskbar unpin verb for OutlookForWindows app IDs."
        return
    }

    try {
        if (Test-Path $taskbarPinDir) {
            $newOutlookPins = Get-ChildItem -Path $taskbarPinDir -Filter '*.lnk' -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.BaseName -match '(?i)outlook\s*\(new\)' -or
                    $_.BaseName -match '(?i)new\s*outlook'
                }

            foreach ($pin in $newOutlookPins) {
                Remove-Item -Path $pin.FullName -Force -ErrorAction Stop
                Write-Log "Removed pinned taskbar shortcut: $($pin.Name)"
            }
        }

        $shell = $null
        try {
            $shell = New-Object -ComObject Shell.Application
            $appsFolder = $shell.Namespace('shell:AppsFolder')
            $outlookAppItems = $appsFolder.Items() |
                Where-Object { $_.Path -like '*Microsoft.OutlookForWindows*' }

            foreach ($item in $outlookAppItems) {
                try {
                    $item.InvokeVerb('taskbarunpin')
                    Write-Log "Invoked taskbar unpin for app item: $($item.Name)"
                }
                catch {
                    Write-Log "Taskbar unpin invoke failed for '$($item.Name)': $($_.Exception.Message)" 'WARN'
                }
            }
        }
        finally {
            if ($shell) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            }
        }
    }
    catch {
        Write-Log "Failed to remove New Outlook taskbar pin: $($_.Exception.Message)" 'ERROR'
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
Set-VisualEffectsForAllUsers
Remove-NewOutlookTaskbarPinForCurrentUser

Set-ClassicNotepadShellNew
Set-EdgePolicyDefaultsForAllUsers

Write-Log "Finished Windows 11 Appx debloat."

Write-Host ''
Write-Host 'Verification commands:'
Write-Host '  Get-AppxPackage -AllUsers | Sort-Object Name | Select-Object Name, PackageFullName'
Write-Host '  Get-AppxProvisionedPackage -Online | Sort-Object DisplayName | Select-Object DisplayName, PackageName'
Write-Host '  Get-ItemProperty "HKLM:\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"'
Write-Host '  Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Edge"'
Write-Host '  Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\MenuAnimation"'
Write-Host '  Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DropShadow"'
Write-Host '  Get-ItemProperty "HKCU:\Control Panel\Desktop" -Name DragFullWindows'
