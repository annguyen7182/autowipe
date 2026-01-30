# ==========================================================
# AUTOWIPE v4.5 (STABLE) - AUTOMATION MODULE
# ==========================================================
# Purpose: The "Brain" of the system:
#   - Master Timer (1000ms tick)
#   - Batch Logic (Wait for X seconds of idle before action)
#   - State Management (WipeBatchTimer, SaveBatchTimer)
#   - Triggers HDS actions via HDS_CONTROL
#
# Dependencies: CORE, HDS_CONTROL, WATCHER
# Used by: GUI (for timer tick)
# ==========================================================
# Purpose: Automation engine providing:
#   - Batch Window Logic (Newest drive resets timer)
#   - Auto Shutdown Logic
#   - Auto Cleanup Logic (New!)
#   - Timer management (master tick)
#   - Automation actions (Refresh, Check, Save, Wipe, Clean)
#
# Dependencies: CORE.ps1, HDS_CONTROL.ps1, WATCHER.ps1
# Used by: GUI.ps1
# ==========================================================

# Verify dependencies
if(-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    throw "AUTOMATION requires CORE module. Load core.ps1 first."
}
if(-not (Get-Command 'Get-HDSStatus' -ErrorAction SilentlyContinue)) {
    throw "AUTOMATION requires HDS_CONTROL module. Load hds_control.ps1 first."
}
if(-not (Get-Command 'Evaluate-And-Render' -ErrorAction SilentlyContinue)) {
    throw "AUTOMATION requires WATCHER module. Load watcher.ps1 first."
}

# ==========================================================
# SECTION 1: AUTOMATION STATE
# ==========================================================

# Next-run timestamps
$script:NextRefreshAt = [datetime]::MaxValue
$script:NextCheckAt   = [datetime]::MaxValue
$script:NextCleanAt   = [datetime]::MaxValue # NEW
$script:NextShutdownAt = [datetime]::MaxValue

# Batch Timers
$script:SaveBatchTimer = [datetime]::MaxValue
$script:WipeBatchTimer = [datetime]::MaxValue
$script:PassBatchTimer = [datetime]::MaxValue

# Batch Counts
$script:SaveBatchCount = 0
$script:WipeBatchCount = 0
$script:PassBatchCount = 0

# Active Configuration
$script:CurrentRefreshMinutes = 60.0
$script:CurrentCheckSeconds   = 5.0
$script:CurrentCleanSeconds   = 30.0 # NEW
$script:CurrentWipeSeconds    = 60.0
$script:CurrentSaveSeconds    = 45.0
$script:CurrentSavePassSeconds = 10.0
$script:CurrentShutdownHours  = 10.0

# Feature enable flags
$script:AutoRefreshEnabled    = $false
$script:AutoCheckEnabled      = $false
$script:AutoCleanEnabled      = $false # NEW
$script:AutoWipeEnabled       = $false
$script:AutoSaveEnabled       = $false
$script:AutoSavePassedEnabled = $false
$script:AutoShutdownEnabled   = $false

# Master timer reference
$script:MasterTimer = $null
$script:MasterTickRunning = $false

# ==========================================================
# SECTION 2: SCHEDULING HELPERS
# ==========================================================

function Set-AutomationConfig {
    param(
        [string]$RefreshMin,
        [string]$CheckSec,
        [string]$CleanSec, # NEW
        [string]$WipeSec,
        [string]$SaveSec,
        [string]$SavePassSec,
        [string]$ShutdownHours
    )
    
    # Parse Refresh
    if($RefreshMin) {
        $m = 60.0
        if([double]::TryParse($RefreshMin, [ref]$m)) { if($m -lt 1) { $m = 1 }; $script:CurrentRefreshMinutes = $m }
    }
    # Parse Check
    if($CheckSec) {
        $s = 5.0
        if([double]::TryParse($CheckSec, [ref]$s)) { if($s -lt 0.2) { $s = 0.2 }; $script:CurrentCheckSeconds = $s }
    }
    # Parse Clean (NEW)
    if($CleanSec) {
        $c = 30.0
        if([double]::TryParse($CleanSec, [ref]$c)) { if($c -lt 5) { $c = 5 }; $script:CurrentCleanSeconds = $c }
    }
    # Parse Wipe
    if($WipeSec) {
        $w = 60.0
        if([double]::TryParse($WipeSec, [ref]$w)) { if($w -lt 5) { $w = 5 }; $script:CurrentWipeSeconds = $w }
    }
    # Parse Save
    if($SaveSec) {
        $sv = 45.0
        if([double]::TryParse($SaveSec, [ref]$sv)) { if($sv -lt 5) { $sv = 5 }; $script:CurrentSaveSeconds = $sv }
    }
    # Parse Save PASS
    if($SavePassSec) {
        $sp = 10.0
        if([double]::TryParse($SavePassSec, [ref]$sp)) { if($sp -lt 5) { $sp = 5 }; $script:CurrentSavePassSeconds = $sp }
    }
    # Parse Shutdown
    if($ShutdownHours) {
        $h = 10.0
        if([double]::TryParse($ShutdownHours, [ref]$h)) { if($h -lt 0.1) { $h = 0.1 }; $script:CurrentShutdownHours = $h }
    }
}

function Format-Countdown {
    param([datetime]$nextAt)
    if($nextAt -eq [datetime]::MaxValue) { return "--:--" }
    $now = Get-Date
    if($nextAt -lt $now) { return "00:00" }
    
    $remain = [int]($nextAt - $now).TotalSeconds
    $hh = [int][Math]::Floor($remain / 3600)
    $mm = [int][Math]::Floor(($remain % 3600) / 60)
    $ss = $remain % 60
    
    if($hh -gt 0) { "{0}:{1:00}:{2:00}" -f $hh, $mm, $ss } else { "{0:00}:{1:00}" -f $mm, $ss }
}

# ==========================================================
# SECTION 3: AUTOMATION ACTIONS (PERIODIC)
# ==========================================================

function Auto-RefreshDue {
    if(-not $script:AutoRefreshEnabled) { return $false }
    if((Get-Date) -lt $script:NextRefreshAt) { return $false }
    if(-not (HDS_CanProceedAuto 'AUTO_REFRESH')) {
        $script:NextRefreshAt = (Get-Date).AddSeconds(30)
        return $false
    }
    
    Log 'AUTO_REFRESH_START' @{ minutes=$script:CurrentRefreshMinutes }
    if($script:MasterTimer) { $script:MasterTimer.Stop() }
    try {
        Run-Refresh
        $script:NextRefreshAt = (Get-Date).AddMinutes($script:CurrentRefreshMinutes)
    } finally { if($script:MasterTimer) { $script:MasterTimer.Start() } }
    return $true
}

function Auto-CheckDue {
    if(-not $script:AutoCheckEnabled) { return $false }
    if((Get-Date) -lt $script:NextCheckAt) { return $false }
    
    if($script:IsBusy) {
        $half = [int][Math]::Max(2, $script:CurrentCheckSeconds / 2)
        $script:NextCheckAt = (Get-Date).AddSeconds($half)
        return $false
    }
    
    Evaluate-And-Render
    Auto-SavePassedBatch
    $script:NextCheckAt = (Get-Date).AddSeconds($script:CurrentCheckSeconds)
    return $true
}

# === NEW CLEANUP FUNCTION ===
function Auto-CleanDue {
    if(-not $script:AutoCleanEnabled) { return $false }
    if((Get-Date) -lt $script:NextCleanAt) { return $false }
    
    if($script:IsBusy) {
        # If busy doing something else, wait 5 seconds and try again
        $script:NextCleanAt = (Get-Date).AddSeconds(5)
        return $false
    }
    
    # Run the Smart Cleanup (Safe List based)
    # We call it with a short timeout so it doesn't block the UI for long
    if(Get-Command 'HDS_SmartCleanup' -ErrorAction SilentlyContinue) {
        HDS_SmartCleanup -TimeoutMs 1500
    }
    
    # Schedule next run
    $script:NextCleanAt = (Get-Date).AddSeconds($script:CurrentCleanSeconds)
    return $true
}

# ==========================================================
# SECTION 4: BATCH WINDOW LOGIC
# ==========================================================

function Auto-SaveDue {
    if(-not $script:AutoSaveEnabled) { $script:SaveBatchTimer = [datetime]::MaxValue; $script:SaveBatchCount = 0; return $false }
    if($script:IsBusy) { return $false }

    $candidates = @()
    $newestTimestamp = [datetime]::MinValue
    
    foreach($port in $script:BaselineByPort.Keys) {
        $base = $script:BaselineByPort[$port]
        if($base.DiskIndex -eq $null -or -not $base.SerialNorm -or $base.HealthPct -eq $null) { continue }
        if(Test-ReportPresent $base.SerialNorm) { continue }
        $sess = Get-Session $port $base.SerialNorm
        if(-not $sess.BecameIdleAt) { continue }
        if($sess.BecameIdleAt -gt $newestTimestamp) { $newestTimestamp = $sess.BecameIdleAt }
        $candidates += @{ Port=$port; Serial=$base.SerialNorm }
    }
    
    $script:SaveBatchCount = $candidates.Count
    if($candidates.Count -eq 0) { $script:SaveBatchTimer = [datetime]::MaxValue; return $false }
    
    $script:SaveBatchTimer = $newestTimestamp.AddSeconds($script:CurrentSaveSeconds)
    if((Get-Date) -lt $script:SaveBatchTimer) { return $false }
    if(-not (HDS_CanProceedAuto 'AUTO_SAVE')) { return $false }
    
    Log 'AUTO_SAVE_BATCH_EXEC' @{ count=$candidates.Count }
    if($script:MasterTimer) { $script:MasterTimer.Stop() }
    try {
        $serials = $candidates | ForEach-Object { $_.Serial }
        Run-SaveAuthentic-BySerials -SerialsNorm $serials
        $script:ForceReportReindexNext = $true
        Build-ReportIndex -force:$true
    } finally { if($script:MasterTimer) { $script:MasterTimer.Start() } }
    return $true
}

function Auto-WipeDue {
    if(-not $script:AutoWipeEnabled) { $script:WipeBatchTimer = [datetime]::MaxValue; $script:WipeBatchCount = 0; return $false }
    if($script:IsBusy) { return $false }
    
    $candidates = @()
    $diskIndices = New-Object System.Collections.Generic.List[int]
    $newestTimestamp = [datetime]::MinValue
    
    foreach($port in $script:BaselineByPort.Keys) {
        $base = $script:BaselineByPort[$port]
        if($base.DiskIndex -eq $null -or -not $base.SerialNorm -or $base.HealthPct -le 1) { continue }
        if(-not (Test-ReportPresent $base.SerialNorm)) { continue }
        if($script:LastActiveForPort.ContainsKey($port)) { continue }
        $sess = Get-Session $port $base.SerialNorm
        if($sess.AutoWipeStarted -or $sess.AutoWipeCompleted -or $sess.AutoWipeFailed) { continue }
        if(-not $sess.GotReportAt) { continue }
        if($sess.GotReportAt -gt $newestTimestamp) { $newestTimestamp = $sess.GotReportAt }
        
        $candidates += @{ Port=$port; Disk=$base.DiskIndex }
        $diskIndices.Add([int]$base.DiskIndex)
    }
    
    $script:WipeBatchCount = $candidates.Count
    if($candidates.Count -eq 0) { $script:WipeBatchTimer = [datetime]::MaxValue; return $false }
    
    $script:WipeBatchTimer = $newestTimestamp.AddSeconds($script:CurrentWipeSeconds)
    if((Get-Date) -lt $script:WipeBatchTimer) { return $false }
    if(-not (HDS_CanProceedAuto 'AUTO_WIPE')) { return $false }
    
    Log 'AUTO_WIPE_BATCH_EXEC' @{ count=$candidates.Count }
    if($script:MasterTimer) { $script:MasterTimer.Stop() }
    try {
        $started = Run-WipeByDiskIndices -DiskIndices $diskIndices -RetryAttempts $null -GiveUpDisks $null
        foreach($diskIdx in $started) {
            if($script:DiskToPort.ContainsKey($diskIdx)) {
                $port = $script:DiskToPort[$diskIdx]
                $sn = $script:BaselineByPort[$port].SerialNorm
                $sess = Get-Session $port $sn
                if($sess) { $sess.AutoWipeStarted = $true }
            }
        }
    } finally { if($script:MasterTimer) { $script:MasterTimer.Start() } }
    return $true
}

function Auto-SavePassedBatch {
    if(-not $script:AutoSavePassedEnabled) { $script:PassBatchTimer = [datetime]::MaxValue; $script:PassBatchCount = 0; return }
    if($script:IsBusy) { return }
    
    $candidates = @()
    $newestTimestamp = [datetime]::MinValue
    
    foreach($port in $script:BaselineByPort.Keys) {
        $base = $script:BaselineByPort[$port]
        if($base.DiskIndex -eq $null -or -not $base.SerialNorm) { continue }
        $sess = Get-Session $port $base.SerialNorm
        if(-not $sess -or $sess.Verdict -ne 'PASS') { continue }
        if($sess.PassReportSaved) { continue }
        if(-not $sess.GotPassVerdictAt) { continue }
        if($sess.GotPassVerdictAt -gt $newestTimestamp) { $newestTimestamp = $sess.GotPassVerdictAt }
        $candidates += $base.SerialNorm
    }
    
    $script:PassBatchCount = $candidates.Count
    if($candidates.Count -eq 0) { $script:PassBatchTimer = [datetime]::MaxValue; return }
    
    $script:PassBatchTimer = $newestTimestamp.AddSeconds($script:CurrentSavePassSeconds)
    if((Get-Date) -lt $script:PassBatchTimer) { return }
    if(-not (HDS_CanProceedAuto 'AUTO_SAVE_PASSED')) { return }
    
    Log 'AUTO_PASS_BATCH_EXEC' @{ count=$candidates.Count }
    if($script:MasterTimer) { $script:MasterTimer.Stop() }
    try {
        Run-SaveAuthentic-BySerials -SerialsNorm $candidates
        foreach($sn in $candidates) {
            $port = $script:SerialToPort[$sn]
            $sess = Get-Session $port $sn
            if($sess) { $sess.PassReportSaved = $true }
        }
    } finally { if($script:MasterTimer) { $script:MasterTimer.Start() } }
}

# ==========================================================
# SECTION 5: MASTER TICK
# ==========================================================

function Master-TimerTick {
    if($script:MasterTickRunning) { return }
    $script:MasterTickRunning = $true
    
    try {
        if($script:AutoShutdownEnabled -and $script:NextShutdownAt -ne [datetime]::MaxValue) {
            if((Get-Date) -ge $script:NextShutdownAt) {
                $script:NextShutdownAt = [datetime]::MaxValue
                Log 'AUTO_SHUTDOWN_TRIGGERED' @{}
            }
        }
        
        # Priority 1: Refresh
        if(Auto-RefreshDue) { return }
        
        # Priority 2: Cleanup (NEW - Before check so UI is clean)
        if(Auto-CleanDue)   { return }

        # Priority 3: Check
        if(Auto-CheckDue)   { return }
        
        # Priority 4: Save
        if(Auto-SaveDue)    { return }
        
        # Priority 5: Wipe
        if(Auto-WipeDue)    { return }
        
    } finally {
        $script:MasterTickRunning = $false
    }
}

# ==========================================================
# SECTION 6: INITIALIZATION
# ==========================================================

function Start-AutomationTimers {
    param([System.Windows.Forms.Timer]$masterTimer)
    $script:MasterTimer = $masterTimer
    $script:MasterTimer.Start()
    Log 'MASTER_TIMER_ON' @{}
}

function Cleanup-Automation {
    if($script:MasterTimer) {
        $script:MasterTimer.Stop()
        $script:MasterTimer.Dispose()
    }
}

function Initialize-Automation {
    Write-Host "[AUTOMATION] Initializing..." -ForegroundColor Yellow
    
    $script:CurrentRefreshMinutes = [double]$script:DEFAULTS.AutoRefreshMin
    $script:CurrentCheckSeconds   = [double]$script:DEFAULTS.IntervalSec
    $script:CurrentCleanSeconds   = 30.0 # Default clean interval
    $script:CurrentWipeSeconds    = [double]$script:DEFAULTS.AutoWipeSec
    $script:CurrentSaveSeconds    = [double]$script:DEFAULTS.AutoSaveSec
    $script:CurrentSavePassSeconds = 10.0
    $script:CurrentShutdownHours  = 10.0
    
    $script:AutoRefreshEnabled    = [bool]$script:DEFAULTS.AutoRefresh
    $script:AutoCheckEnabled      = [bool]$script:DEFAULTS.AutoCheck
    $script:AutoCleanEnabled      = $false # Default OFF
    $script:AutoWipeEnabled       = [bool]$script:DEFAULTS.AutoWipe
    $script:AutoSaveEnabled       = [bool]$script:DEFAULTS.AutoSave
    $script:AutoSavePassedEnabled = [bool]$script:DEFAULTS.AutoSavePassed
    
    Log 'AUTOMATION_INIT' @{}
}

Write-Host "[AUTOMATION] Module loaded." -ForegroundColor DarkGray