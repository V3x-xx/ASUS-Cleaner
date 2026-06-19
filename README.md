# ASUS Cleaner

A small Windows PowerShell CLI tool with a simple menu for ASUS laptop maintenance:

1. **Debloat ASUS processes** — lists all running ASUS-related processes and terminates them together with their entire process tree.
2. **Change battery limit** — sets the ASUS battery charge limit via the BIOS/WMI interface (`AsusAtkWmi_WMNB` / `root/WMI`).

## How to run on Windows

1. Open **PowerShell** or **Windows Terminal**.
2. For the battery limit option, right-click PowerShell and choose **Run as administrator** (WMI calls require admin rights).
3. Run the script with the following command:

```powershell
powershell -ExecutionPolicy Bypass -File .\kill-asus.ps1
```

Choose an option from the menu:

- `1` — debloat ASUS processes
- `2` — set battery charge limit
- `3` — exit

## What processes are searched

Option 1 looks for running processes whose name (case-insensitive) contains any of the following patterns. The entire process tree of each match is included.

| Pattern |
| --- |
| ArmouryCrateControlInterface |
| ASUSOptimization |
| AsHidService |
| AsusAppService |
| ASUSSoftwareManager |
| ASUSLiveUpdateAgent |
| ASUSSystemAnalysis |
| ASUSSystemDiagnosis |
| ASUSLinkNear |
| ASUSLinkRemote |
| ASUSSwitch |
| AsusCertService |

## WhatIf mode

To preview destructive operations without applying them:

```powershell
powershell -ExecutionPolicy Bypass -File .\kill-asus.ps1 -WhatIf
```

In WhatIf mode, option 1 will list matching processes without killing them, and option 2 will show the WMI call it would make without executing it.

## Requirements

- Windows
- PowerShell 5.1 or later
- Administrator privileges are recommended, especially for the battery limit WMI call and for terminating protected processes

## Safety

- The script skips the current PowerShell process and critical system processes.
- Always run with `-WhatIf` first to verify the target list.
- Battery limit changes are applied via the official ASUS WMI interface, but use at your own risk.
- Terminating system-related processes can affect hardware controls (RGB, fan curves, etc.).
