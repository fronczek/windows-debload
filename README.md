# windows-debload

A PowerShell script that removes unwanted Windows 11 Appx (Store) packages and restores classic behaviour for `.txt` files.

## What it does

### Appx removal

Removes selected consumer / promotional packages for **all existing users** and from the **provisioned image** so future users don't receive them either.

Packages removed by default:

| Category | Packages |
|---|---|
| Consumer / promotional | BingNews, BingWeather, GetHelp, Getstarted, OfficeHub, SolitaireCollection, People, PowerAutomateDesktop, Todos, FeedbackHub, WindowsMaps, ZuneMusic, ZuneVideo |
| Outlook / Mail | OutlookForWindows, windowscommunicationsapps |
| Teams | MicrosoftTeams, MSTeams |
| Xbox / Gaming | GamingApp, Xbox.TCUI, XboxApp, XboxGameOverlay, XboxGamingOverlay, XboxIdentityProvider, XboxSpeechToTextOverlay |
| Other | Microsoft3DViewer, MixedReality.Portal, SkypeApp, Cortana (549981C3F5F10), MicrosoftFamily |
| Notepad (Store) | **Microsoft.WindowsNotepad** – the modern Store version is removed; classic `notepad.exe` is kept and restored (see below) |

Packages intentionally **not** removed (see `$ProtectedExamples` in the script):

`WindowsStore`, `StorePurchaseApp`, `DesktopAppInstaller`, `WindowsCalculator`, `Windows.Photos`, `Paint`, `SecHealthUI`, `ScreenSketch`, codec extensions.

### Classic Notepad and right-click "New Text Document"

After removing the Windows 11 Store Notepad, the script:

1. Ensures `HKLM\SOFTWARE\Classes\.txt\ShellNew` contains a `NullFile` entry so **right-click → New → Text Document** works for all users (existing and future).
2. Sets the `txtfile` open command in HKLM to `"C:\Windows\System32\notepad.exe" "%1"` so `.txt` files open with the classic Notepad.

Because these settings live under `HKLM` they apply machine-wide and are inherited by all new user profiles automatically.

### New Outlook taskbar pin cleanup

The script also removes **New Outlook** taskbar pins for the user running it, preventing stale taskbar buttons from triggering a reinstall attempt after the app package is removed.

## Usage

```powershell
# Preview changes without modifying anything
.\debloat-win11.ps1 -WhatIfMode

# Apply changes (must run as Administrator)
.\debloat-win11.ps1
```

A log file is written to `%SystemDrive%\Windows\Temp\Debloat-Windows11-Appx.log` by default.  Override with `-LogPath`:

```powershell
.\debloat-win11.ps1 -LogPath C:\Logs\debloat.log
```

## Requirements

* Windows 11
* PowerShell run **as Administrator** (`#Requires -RunAsAdministrator`)

## Verification

After running, confirm packages are gone:

```powershell
Get-AppxPackage -AllUsers | Sort-Object Name | Select-Object Name, PackageFullName
Get-AppxProvisionedPackage -Online | Sort-Object DisplayName | Select-Object DisplayName, PackageName
```

Confirm the ShellNew and open-command registry entries:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Classes\.txt\ShellNew'
Get-ItemProperty 'HKLM:\SOFTWARE\Classes\txtfile\shell\open\command'
```
