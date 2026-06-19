<#PSScriptInfo
.SYNOPSIS
    ASUS cleaner menu with process debloat and battery limit controls.

.DESCRIPTION
    Provides a simple terminal menu to:
    1. List and terminate ASUS-related processes and their entire process tree.
    2. Set the ASUS laptop battery charge limit via the BIOS/WMI interface.

.PARAMETER WhatIf
    When specified, destructive operations are only previewed and not executed.

.EXAMPLE
    .\kill-asus.ps1
    Shows the menu and waits for an option.

.EXAMPLE
    .\kill-asus.ps1 -WhatIf
    Same as above, but option 1 will list processes without terminating them.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

# Ensure this is running on Windows.
if ($PSVersionTable.PSVersion.Major -ge 6 -and $env:OS -ne 'Windows_NT') {
    Write-Error 'This script is intended for Windows only.'
    exit 1
}

# Patterns that identify ASUS-related processes.
$asusPatterns = @(
   "ArmouryCrateControlInterface",
    "ASUSOptimization",
    "AsHidService",
    "AsusAppService",
    "ASUSSoftwareManager",
    "ASUSLiveUpdateAgent",
    "ASUSSystemAnalysis",
    "ASUSSystemDiagnosis",
    "ASUSLinkNear",
    "ASUSLinkRemote",
    "ASUSSwitch",
    "AsusCertService"
)

function Test-AdminRights {
    $currentPrincipal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Menu {
    Write-Host ''
    Write-Host '===============================' -ForegroundColor Cyan
    Write-Host '        ASUS CLEANER' -ForegroundColor Cyan
    Write-Host '===============================' -ForegroundColor Cyan
    Write-Host '1. Debloat ASUS processes'
    Write-Host '2. Change battery limit (WMI)'
    Write-Host '3. Exit'
    Write-Host '===============================' -ForegroundColor Cyan
}

function Start-AsusDebloat {
    # Gather all running processes via WMI/CIM.
    $allProcesses = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
        Select-Object -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine

    # Build a child lookup table for fast tree traversal.
    $children = @{}
    foreach ($proc in $allProcesses) {
        $procId = $proc.ProcessId
        $parent = $proc.ParentProcessId
        if (-not $children.ContainsKey($procId)) {
            $children[$procId] = [System.Collections.Generic.List[object]]::new()
        }
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = [System.Collections.Generic.List[object]]::new()
        }
        $children[$parent].Add($proc)
    }

    function Test-AsusMatch {
        param([string]$Name)
        foreach ($pattern in $asusPatterns) {
            if ($Name -like "*$pattern*") {
                return $true
            }
        }
        return $false
    }

    function Get-Descendants {
        param(
            [int]$ProcessId,
            [System.Collections.Generic.HashSet[int]]$Visited
        )
        $result = [System.Collections.Generic.List[object]]::new()
        if (-not $Visited.Add($ProcessId)) {
            return @($result)
        }
        if ($children.ContainsKey($ProcessId)) {
            foreach ($child in $children[$ProcessId]) {
                $result.Add($child)
                $childDescendants = Get-Descendants -ProcessId $child.ProcessId -Visited $Visited
                if ($null -ne $childDescendants) {
                    $result.AddRange($childDescendants)
                }
            }
        }
        return @($result)
    }

    # Find the top-level matches and expand them to include their entire process trees.
    $matchedTopLevel = $allProcesses | Where-Object { Test-AsusMatch -Name $_.Name }
    $allTargets = [System.Collections.Generic.List[object]]::new()
    $seenPids = [System.Collections.Generic.HashSet[int]]::new()

    foreach ($match in $matchedTopLevel) {
        $tree = [System.Collections.Generic.List[object]]::new()
        $tree.Add($match)
        $descendants = Get-Descendants -ProcessId $match.ProcessId -Visited ([System.Collections.Generic.HashSet[int]]::new())
        if ($null -ne $descendants) {
            $tree.AddRange($descendants)
        }
        foreach ($proc in $tree) {
            if ($seenPids.Add($proc.ProcessId)) {
                $allTargets.Add($proc)
            }
        }
    }

    if ($allTargets.Count -eq 0) {
        Write-Host 'No ASUS-related processes found.' -ForegroundColor Green
        return
    }

    # Sort targets so children are listed before parents in the output.
    $sortedTargets = $allTargets | Sort-Object -Property ProcessId

    # Display what was found.
    Write-Host ''
    Write-Host "Found $($matchedTopLevel.Count) matching top-level process(es) and $($allTargets.Count - $matchedTopLevel.Count) additional child/descendant process(es)." -ForegroundColor Yellow
    Write-Host ''

    $table = $sortedTargets | ForEach-Object {
        [PSCustomObject]@{
            PID        = $_.ProcessId
            ParentPID  = $_.ParentProcessId
            Name       = $_.Name
            Path       = $_.ExecutablePath
        }
    }
    $table | Format-Table -AutoSize | Out-String | Write-Host

    # If we are in WhatIf mode, just stop here.
    if ($WhatIf) {
        Write-Host 'WhatIf: No processes were terminated.' -ForegroundColor Cyan
        return
    }

    # Ask the user for confirmation.
    $choice = Read-Host -Prompt 'Proceed to terminate these processes and their children? (Y/n)'
    if ($choice -notmatch '^\s*[Yy]\s*$' -and $choice -ne '') {
        Write-Host 'Operation cancelled by user.' -ForegroundColor Yellow
        return
    }

    # Compute depth for each target so children are terminated before parents.
    $depthMap = @{}
    function Get-Depth {
        param([int]$ProcessId)
        if ($depthMap.ContainsKey($ProcessId)) {
            return $depthMap[$ProcessId]
        }
        $proc = $allProcesses | Where-Object { $_.ProcessId -eq $ProcessId } | Select-Object -First 1
        if ($null -eq $proc -or $proc.ParentProcessId -eq $ProcessId -or $proc.ParentProcessId -eq 0) {
            $depthMap[$ProcessId] = 0
            return 0
        }
        $parentDepth = Get-Depth -ProcessId $proc.ParentProcessId
        $depthMap[$ProcessId] = $parentDepth + 1
        return $parentDepth + 1
    }

    foreach ($target in $allTargets) {
        $null = Get-Depth -ProcessId $target.ProcessId
    }

    # Terminate deepest descendants first to avoid creating orphaned processes.
    $sortedByDepth = $allTargets | Sort-Object -Property { $depthMap[$_.ProcessId] } -Descending
    $success = 0
    $failed = 0
    $skipped = 0

    foreach ($proc in $sortedByDepth) {
        # Never try to kill the current PowerShell process or critical system processes.
        if ($proc.ProcessId -eq $PID -or $proc.ProcessId -eq 0 -or $proc.ProcessId -eq 4) {
            $skipped++
            continue
        }

        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Host "Terminated: $($proc.Name) (PID $($proc.ProcessId))" -ForegroundColor Green
            $success++
        }
        catch {
            Write-Warning "Failed to terminate $($proc.Name) (PID $($proc.ProcessId)): $_"
            $failed++
        }
    }

    Write-Host ''
    Write-Host "Done. Success: $success, Failed: $failed, Skipped: $skipped" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
}

function Set-AsusBatteryLimit {
    if (-not (Test-AdminRights)) {
        Write-Warning 'Battery limit WMI calls usually require administrator privileges. Please run this script as Administrator.'
    }

    $className = 'AsusAtkWmi_WMNB'
    $namespace = 'root/WMI'

    try {
        $wmiObject = Get-CimInstance -Namespace $namespace -ClassName $className -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        Write-Error "Unable to find ASUS WMI class '$className' in namespace '$namespace'. This tool only works on supported ASUS laptops. Error: $_"
        return
    }

    if (-not $wmiObject) {
        Write-Error "ASUS WMI object is present but returned no instance."
        return
    }

    Write-Host ''
    Write-Host 'Battery limit: enter a value between 60 and 100 (e.g. 80 for 80% charge limit).'
    Write-Host 'Common values: 60 (Balanced), 80 (Battery Health Charging), 100 (Full capacity).'
    $limitInput = Read-Host -Prompt 'Battery limit percentage'

    if (-not [int]::TryParse($limitInput, [ref]$null)) {
        Write-Error 'Invalid input. Please enter a number between 60 and 100.'
        return
    }

    $limit = [int]$limitInput
    if ($limit -lt 60 -or $limit -gt 100) {
        Write-Error 'Value out of range. Allowed range is 60 to 100.'
        return
    }

    $deviceId = 0x00120057

    if ($WhatIf) {
        Write-Host "WhatIf: Would call DEVS on '$className' with Device_ID=$deviceId and Control_status=$limit" -ForegroundColor Cyan
        return
    }

    try {
        $result = Invoke-CimMethod -InputObject $wmiObject -MethodName 'DEVS' -Arguments @{ Device_ID = $deviceId; Control_status = $limit } -ErrorAction Stop
        Write-Host "Battery limit set to $limit%." -ForegroundColor Green
        Write-Host "WMI return value: $($result.ReturnValue)" -ForegroundColor Gray
    }
    catch {
        Write-Error "Failed to set battery limit via WMI: $_"
    }
}

# Main menu loop.
while ($true) {
    Show-Menu
    $menuChoice = Read-Host -Prompt 'Select an option (1-3)'

    switch ($menuChoice.Trim()) {
        '1' { Start-AsusDebloat }
        '2' { Set-AsusBatteryLimit }
        '3' { Write-Host 'Exiting.' -ForegroundColor Green; exit 0 }
        default { Write-Host 'Invalid option. Please choose 1, 2, or 3.' -ForegroundColor Red }
    }

    Write-Host ''
    Write-Host 'Press Enter to return to the menu...' -ForegroundColor Gray
    $null = Read-Host
}
