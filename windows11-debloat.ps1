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

# Packages that must never be removed. Any overlap with $Targets is stripped
# at runtime before processing begins.
$ProtectedTargets = @(
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

    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Remove-AppxTarget {
    param([string]$PackageName)

    Write-Log "Processing: $PackageName"

    # Installed packages (existing users)
    $packages = Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue
    if (-not $packages) { Write-Log "  Installed Appx not found for existing users." }
    foreach ($pkg in $packages) {
        if ($pkg.NonRemovable -eq $true) {
            Write-Log "  Skipping non-removable: $($pkg.PackageFullName)" 'WARN'
            continue
        }
        if ($WhatIfMode) {
            Write-Log "  WHATIF: Remove-AppxPackage -AllUsers '$($pkg.PackageFullName)'"
        }
        else {
            try {
                Remove-AppxPackage -AllUsers -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Log "  Removed installed Appx: $($pkg.PackageFullName)"
            }
            catch {
                Write-Log "  Failed to remove installed Appx $($pkg.PackageFullName): $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    # Provisioned packages (future users)
    $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $PackageName }
    if (-not $provisioned) { Write-Log "  Provisioned Appx not found for future users." }
    foreach ($pkg in $provisioned) {
        if ($WhatIfMode) {
            Write-Log "  WHATIF: Remove-AppxProvisionedPackage -Online '$($pkg.PackageName)'"
        }
        else {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                Write-Log "  Removed provisioned Appx: $($pkg.PackageName)"
            }
            catch {
                Write-Log "  Failed to remove provisioned Appx $($pkg.PackageName): $($_.Exception.Message)" 'ERROR'
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
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    const int SE_PRIVILEGE_ENABLED = 2, TOKEN_QUERY = 8, TOKEN_ADJUST_PRIVILEGES = 32;
    public static void Enable(string privilege) {
        IntPtr htok = IntPtr.Zero;
        OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle,
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
        try {
            TokPriv1Luid tp; tp.Count = 1; tp.Luid = 0; tp.Attr = SE_PRIVILEGE_ENABLED;
            LookupPrivilegeValue(null, privilege, ref tp.Luid);
            AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        } finally {
            if (htok != IntPtr.Zero) CloseHandle(htok);
        }
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
        if (-not $readAclKey) { throw "Could not open CLSID key '$clsidSubKey' for reading original ACL." }
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
    $notepadPath = "$env:SystemRoot\System32\notepad.exe"

    Write-Log "Restoring right-click 'New Text Document' using classic notepad.exe ($notepadPath)."

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would set HKLM:.txt\ShellNew NullFile and txtfile open command to '$notepadPath'"
        return
    }

    try {
        # Right-click New > Text Document (all users via HKLM)
        New-Item -Path 'HKLM:\SOFTWARE\Classes\.txt\ShellNew' -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Classes\.txt\ShellNew' -Name 'NullFile' -Value '' -PropertyType String -Force | Out-Null

        # Ensure .txt -> txtfile -> classic notepad.exe
        New-Item -Path 'HKLM:\SOFTWARE\Classes\.txt' -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Classes\.txt' -Name '(default)' -Value 'txtfile' -Force
        New-Item -Path 'HKLM:\SOFTWARE\Classes\txtfile\shell\open\command' -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Classes\txtfile\shell\open\command' -Name '(default)' -Value "`"$notepadPath`" `"%1`"" -Force
        Write-Log "Set .txt default to txtfile; open command: `"$notepadPath`" `"%1`""
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

    # per-effect values: 0 = disable, 1 = keep
    $effectValues = @{
        ControlAnimations      = 0
        MenuAnimation          = 0
        ComboBoxAnimation      = 0
        ListBoxSmoothScrolling = 0
        TooltipAnimation       = 0
        SelectionFade          = 0
        TaskbarAnimations      = 0
        DropShadow             = 1
        CursorShadow           = 1
        FontSmoothing          = 1
        DesktopComposition     = 1
        Themes                 = 1
        ListviewShadow         = 1
    }

    $visualEffectsPath = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    $desktopPath = "$HiveRoot\Control Panel\Desktop"
    $windowMetricsPath = "$desktopPath\WindowMetrics"

    Write-Log "Applying visual-effects profile for $ScopeLabel (disable animations, keep shadows/font smoothing/desktop composition/themes)."

    # Bitmask for UserPreferencesMask: keep shadows, font smoothing, thumbnail previews;
    # disable slide animations, fade effects, animate windows, etc.
    # Bytes (little-endian): 90 12 03 80 10 00 00 00
    $userPrefMask = [byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)

    if ($WhatIfMode) {
        Write-Log "WHATIF: Would apply visual-effects profile under '$HiveRoot' (disable animations, keep shadows/font-smoothing)."
        return
    }

    try {
        New-Item -Path $visualEffectsPath -Force -ErrorAction Stop | Out-Null
        # VisualFXSetting=3 tells Windows to use custom (per-effect) settings
        New-ItemProperty -Path $visualEffectsPath -Name 'VisualFXSetting' -Value 3 -PropertyType DWord -Force -ErrorAction Stop | Out-Null

        foreach ($entry in $effectValues.GetEnumerator()) {
            $effectPath = "$visualEffectsPath\$($entry.Key)"
            New-Item -Path $effectPath -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $effectPath -Name 'DefaultApplied' -Value $entry.Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }

        New-Item -Path $desktopPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $desktopPath -Name 'DragFullWindows' -Value '1' -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $desktopPath -Name 'FontSmoothing' -Value '2' -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $desktopPath -Name 'FontSmoothingType' -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        # UserPreferencesMask is the live bitmask Windows reads; without it the
        # DefaultApplied keys above only affect the Performance Options dialog UI
        New-ItemProperty -Path $desktopPath -Name 'UserPreferencesMask' -Value $userPrefMask -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        New-Item -Path $windowMetricsPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $windowMetricsPath -Name 'MinAnimate' -Value '0' -PropertyType String -Force -ErrorAction Stop | Out-Null

        Write-Log "Visual-effects profile applied for $ScopeLabel."
    }
    catch {
        Write-Log ("Failed to apply visual-effects profile for {0}: {1}" -f $ScopeLabel, $_.Exception.Message) 'ERROR'
    }
}

function Invoke-WithMountedHive {
    param(
        [string]$HivePath,
        [string]$MountName,
        [string]$ScopeLabel
    )
    $mounted = $false
    try {
        if ($WhatIfMode) {
            Write-Log "WHATIF: reg.exe load HKU\\$MountName '$HivePath'"
            Set-VisualEffectsProfile -HiveRoot "Registry::HKEY_USERS\$MountName" -ScopeLabel $ScopeLabel
            Write-Log "WHATIF: reg.exe unload HKU\\$MountName"
        }
        else {
            & reg.exe load "HKU\$MountName" "$HivePath" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Failed to load hive for $ScopeLabel from '$HivePath'" 'ERROR'
                return
            }
            $mounted = $true
            Set-VisualEffectsProfile -HiveRoot "Registry::HKEY_USERS\$MountName" -ScopeLabel $ScopeLabel
        }
    }
    finally {
        if ($mounted) {
            & reg.exe unload "HKU\$MountName" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Failed to unload temporary hive HKU\\$MountName" 'WARN'
            }
        }
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

        Invoke-WithMountedHive -HivePath $ntUserDatPath `
            -MountName "TEMP_USER_$($sid -replace '-', '_')" `
            -ScopeLabel "offline user SID $sid"
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
        Invoke-WithMountedHive -HivePath $defaultProfileDat -MountName 'WDL_DefaultProfile' -ScopeLabel 'default user profile'
    }
    else {
        Write-Log "Default profile hive not found: $defaultProfileDat" 'WARN'
    }
}

function Set-EdgePolicyDefaultsForAllUsers {
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
        New-Item -Path $edgePolicyPath -Force | Out-Null

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
                Where-Object { $_.BaseName -match '(?i)(outlook\s*\(new\)|new\s*outlook)' }

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

# Strip any protected packages that were accidentally added to $Targets
$blocked = $Targets | Where-Object { $ProtectedTargets -contains $_ }
foreach ($pkg in $blocked) {
    Write-Log "Removing '$pkg' from targets — it is in the protected list." 'WARN'
}
$Targets = $Targets | Where-Object { $ProtectedTargets -notcontains $_ }

foreach ($target in $Targets) {
    Remove-AppxTarget -PackageName $target
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
