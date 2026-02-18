# ==========================================================
# AUTOWIPE v4.5.1 (STABLE) - GUI MODULE
# ==========================================================
# Purpose: Presentation layer providing:
#   - WinForms initialization
#   - Grid management (24-row port display)
#   - New "Clean" toggle
#   - Batch counters column
#
# Dependencies: CORE.ps1, HDS_CONTROL.ps1, WATCHER.ps1, AUTOMATION.ps1
# ==========================================================

if(-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) { throw "GUI requires CORE module." }
if(-not (Get-Command 'Evaluate-And-Render' -ErrorAction SilentlyContinue)) { throw "GUI requires WATCHER module." }
if(-not (Get-Command 'Master-TimerTick' -ErrorAction SilentlyContinue)) { throw "GUI requires AUTOMATION module." }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==========================================================
# SECTION 1: GUI STATE
# ==========================================================

$script:Form = $null; $script:Grid = $null; $script:CountLabel = $null
$script:PassLenBox = $null; $script:FailLenBox = $null
$script:CheckBtn = $null; $script:ClosePassBtn = $null; $script:ClearBtn = $null; $script:CloseBtn = $null
$script:AutoPanel = $null

# Automation Controls
$script:AutoRefreshChk = $null; $script:AutoRefreshBox = $null; $script:AutoRefreshNextLbl = $null
$script:AutoCheckChk = $null; $script:IntervalBox = $null; $script:AutoCheckNextLbl = $null
$script:AutoCleanChk = $null; $script:AutoCleanBox = $null; $script:AutoCleanNextLbl = $null

# Batch Rows (Now have separate Batch Labels)
$script:AutoWipeChk = $null; $script:AutoWipeBox = $null; $script:AutoWipeNextLbl = $null; $script:AutoWipeBatchLbl = $null
$script:AutoSaveChk = $null; $script:AutoSaveBox = $null; $script:AutoSaveNextLbl = $null; $script:AutoSaveBatchLbl = $null
$script:AutoSavePassedChk = $null; $script:AutoSavePassedBox = $null; $script:AutoSavePassedNextLbl = $null; $script:AutoSavePassedBatchLbl = $null

$script:AutoShutdownChk = $null; $script:AutoShutdownBox = $null; $script:AutoShutdownNextLbl = $null

$script:MasterTimer = $null
$script:rowHeight = 22; $script:formWidth = 1000; $script:maxPort = 24

$script:colorDefault   = [System.Drawing.Color]::White
$script:colorDoneGreen = [System.Drawing.Color]::FromArgb(234, 255, 234)
$script:colorFailRed   = [System.Drawing.Color]::FromArgb(255, 228, 228)
$script:colorNotStartY = [System.Drawing.Color]::FromArgb(255, 248, 220)
$script:colorCheckAmb  = [System.Drawing.Color]::FromArgb(255, 240, 200)

# ==========================================================
# SECTION 2: GRID HELPERS (Standard)
# ==========================================================
function Set-RowColor { param([int]$row, [System.Drawing.Color]$color) $script:Grid.Rows[$row].DefaultCellStyle.BackColor = $color }
function Refresh-Grid {
    $script:Grid.Rows.Clear(); $script:Sessions.Clear(); $script:BaselineByPort.Clear()
    $script:SerialToPort.Clear(); $script:DiskToPort.Clear(); $script:HandleBind.Clear()
    Ensure-ProgressCsv; Load-ProgressCsv; Load-RefPorts
    $script:maxPort = if($script:refPorts.Values) { ($script:refPorts.Values | Measure-Object -Maximum).Maximum } else { 24 }
    foreach($port in 1..$script:maxPort) {
        [void]$script:Grid.Rows.Add(@("Port $port", '', '', '', '', '', '', '', ''))
        $script:Grid.Rows[$port - 1].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
        $script:Grid.Rows[$port - 1].Cells['Serial'].Value = 'EMPTY or DEAD'
    }
    Evaluate-And-Render
}
function Update-GridFromWatcherState {
    $activeForPort = @{}
    foreach($h in $script:HandleBind.Keys) {
        if(-not $script:LastWinMap.ContainsKey($h)) { continue }
        $p = [int]$script:HandleBind[$h].Port
        if(-not $activeForPort.ContainsKey($p)) { $activeForPort[$p] = $h } 
        else {
            $cur = $activeForPort[$p]; $a = $script:LastWinMap[$h].ProgressVal; $c = $script:LastWinMap[$cur].ProgressVal
            if(($a -as [double]) -gt ($c -as [double])) { $activeForPort[$p] = $h }
        }
    }
    $detected = 0
    foreach($port in 1..$script:maxPort) {
        $rowIndex = $port - 1
        $base = if($script:BaselineByPort.ContainsKey($port)) { $script:BaselineByPort[$port] } else { $null }
        $diskIndex = if($base) { $base.DiskIndex } else { $null }
        $baseSerialNorm = if($base) { $base.SerialNorm } else { '' }
        $baseHP = if($base) { $base.HealthPct } else { $null }
        
        $script:Grid.Rows[$rowIndex].Cells['Port'].Value = "Port $port"
        $script:Grid.Rows[$rowIndex].Cells['Disk'].Value = if($diskIndex -ne $null) { $diskIndex } else { '' }
        $script:Grid.Rows[$rowIndex].Cells['HP'].Value = if($baseHP -ne $null -and $baseHP -gt 1) { "$baseHP%" } else { '' }
        
        $displayHandle = if($activeForPort.ContainsKey($port)) { $activeForPort[$port] } else { $null }
        $displaySerialRaw = if($displayHandle) { $script:HandleBind[$displayHandle].SerialRaw } elseif($base) { $base.SerialRaw } else { '' }
        $displaySerialNorm = if($displayHandle) { $script:HandleBind[$displayHandle].SerialNorm } else { $baseSerialNorm }
        
        if($diskIndex -eq $null -and -not $displaySerialNorm) {
            $script:Grid.Rows[$rowIndex].Cells['Serial'].Value = 'EMPTY or DEAD'
            $script:Grid.Rows[$rowIndex].Cells['Title'].Value = ''
            $script:Grid.Rows[$rowIndex].Cells['Progress'].Value = ''
            $script:Grid.Rows[$rowIndex].Cells['Verdict'].Value = ''
            $script:Grid.Rows[$rowIndex].Cells['Report'].Value = ''
            $script:Grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
            Set-RowColor $rowIndex $script:colorDefault
            continue
        } else {
            if($diskIndex -ne $null) { $detected++ }
            $script:Grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Black
            $script:Grid.Rows[$rowIndex].Cells['Serial'].Value = $displaySerialRaw
        }
        
        $progTxt = ''; $title = ''; $verdict = ''
        if($displayHandle -and $script:LastWinMap.ContainsKey($displayHandle)) {
            $info = $script:LastWinMap[$displayHandle]
            $progTxt = $info.ProgressText; $title = $info.Title
            $sess = Get-Session $port $displaySerialNorm
            if($sess -and $sess.Verdict) {
                if($sess.Verdict -eq 'PASS') { $verdict = 'PASS'; $progTxt = '100.00%' }
                elseif($sess.Verdict -eq 'FAILED') { $verdict = 'FAILED' } 
                elseif($sess.Verdict -eq 'CHECK') { $verdict = '[CHECK]' }
            }
        }
        $rep = if($script:ReportIndex -and $script:ReportIndex.Files -and $displaySerialNorm) { if(Test-ReportPresent $displaySerialNorm) { 'OK' } else { 'MISSING' } } else { '' }
        $script:Grid.Rows[$rowIndex].Cells['Report'].Value = $rep
        $script:Grid.Rows[$rowIndex].Cells['Title'].Value = $title
        $script:Grid.Rows[$rowIndex].Cells['Progress'].Value = $progTxt
        $script:Grid.Rows[$rowIndex].Cells['Verdict'].Value = $verdict
        
        if($verdict -eq 'FAILED' -or $progTxt -eq 'FAILED') { Set-RowColor $rowIndex $script:colorFailRed }
        elseif($verdict -eq 'PASS') { Set-RowColor $rowIndex $script:colorDoneGreen }
        elseif($verdict -eq '[CHECK]') { Set-RowColor $rowIndex $script:colorCheckAmb }
        elseif([string]::IsNullOrWhiteSpace($progTxt)) { Set-RowColor $rowIndex $script:colorNotStartY }
        else { Set-RowColor $rowIndex $script:colorDefault }
    }
    $script:CountLabel.Text = "Drives Detected: $detected"
}

# ==========================================================
# SECTION 3: EVENT HANDLERS
# ==========================================================

function Get-PassLenMax {
    $fallback = [int]$script:DEFAULTS.PassLenMax
    if(-not $script:PassLenBox) { return $fallback }
    $value = 0
    if([int]::TryParse([string]$script:PassLenBox.Text, [ref]$value) -and $value -gt 0) {
        return $value
    }
    $fallback
}

function Get-FailLenMin {
    $fallback = [int]$script:DEFAULTS.FailLenMin
    if(-not $script:FailLenBox) { return $fallback }
    $value = 0
    if([int]::TryParse([string]$script:FailLenBox.Text, [ref]$value) -and $value -gt 0) {
        return $value
    }
    $fallback
}

function Sync-AutomationConfig {
    Set-AutomationConfig -RefreshMin $script:AutoRefreshBox.Text `
                         -CheckSec $script:IntervalBox.Text `
                         -CleanSec $script:AutoCleanBox.Text `
                         -WipeSec $script:AutoWipeBox.Text `
                         -SaveSec $script:AutoSaveBox.Text `
                         -SavePassSec $script:AutoSavePassedBox.Text `
                         -ShutdownHours $script:AutoShutdownBox.Text
}

function OnCheckButtonClick { $script:ForceReportReindexNext = $true; Evaluate-And-Render }
function OnClosePassButtonClick {
    try {
        $wins = Get-CurrentSurfaceWindows
        foreach($h in $script:HandleBind.Keys) {
            if(-not $wins.ContainsKey($h)) { continue }
            $sess = Get-Session $script:HandleBind[$h].Port $script:HandleBind[$h].SerialNorm
            if($sess.Verdict -eq 'PASS' -and $sess.Handle) { [Win32]::PostMessage($sess.Handle, [Win32]::WM_CLOSE, 0, 0) | Out-Null }
        }
    } catch {}
}
function OnClearButtonClick { if(Get-Command 'Clear-Dead-Records' -ErrorAction SilentlyContinue) { Clear-Dead-Records; Evaluate-And-Render } }
function OnCloseButtonClick { $script:Form.Close(); Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue }

# Toggles
function OnAutoRefreshToggle { Sync-AutomationConfig; $script:AutoRefreshEnabled = $script:AutoRefreshChk.Checked; if($script:AutoRefreshEnabled){ $script:NextRefreshAt = (Get-Date).AddMinutes($script:CurrentRefreshMinutes) } }
function OnAutoCheckToggle { Sync-AutomationConfig; $script:AutoCheckEnabled = $script:AutoCheckChk.Checked; if($script:AutoCheckEnabled){ $script:NextCheckAt = (Get-Date).AddSeconds($script:CurrentCheckSeconds) } }
function OnAutoCleanToggle { Sync-AutomationConfig; $script:AutoCleanEnabled = $script:AutoCleanChk.Checked; if($script:AutoCleanEnabled){ $script:NextCleanAt = (Get-Date).AddSeconds($script:CurrentCleanSeconds) } }
function OnAutoWipeToggle { Sync-AutomationConfig; $script:AutoWipeEnabled = $script:AutoWipeChk.Checked }
function OnAutoSaveToggle { Sync-AutomationConfig; $script:AutoSaveEnabled = $script:AutoSaveChk.Checked }
function OnAutoSavePassedToggle { Sync-AutomationConfig; $script:AutoSavePassedEnabled = $script:AutoSavePassedChk.Checked }
function OnAutoShutdownToggle { 
    Sync-AutomationConfig; $script:AutoShutdownEnabled = $script:AutoShutdownChk.Checked
    if($script:AutoShutdownEnabled) { 
        $sec = [int]($script:CurrentShutdownHours * 3600); Start-Process "shutdown" -ArgumentList "/s /t $sec" -NoNewWindow
        $script:NextShutdownAt = (Get-Date).AddHours($script:CurrentShutdownHours)
    } else { Start-Process "shutdown" -ArgumentList "/a" -NoNewWindow; $script:NextShutdownAt = [datetime]::MaxValue }
}

# ==========================================================
# SECTION 4: INITIALIZATION
# ==========================================================

function Initialize-GUI {
    $script:Form = New-Object System.Windows.Forms.Form
    $script:Form.Text = "Autowipe v4.5.1 (Stable) - $env:COMPUTERNAME"; $script:Form.Width = $script:formWidth
    $script:Form.FormBorderStyle = 'FixedSingle'; $script:Form.MaximizeBox = $false
    
    # Grid Setup
    Load-RefPorts
    $script:maxPort = if($script:refPorts.Values) { ($script:refPorts.Values | Measure-Object -Maximum).Maximum } else { 24 }
    $gridHeight = [int](($script:maxPort + 1) * $script:rowHeight)
    $script:Grid = New-Object System.Windows.Forms.DataGridView
    $script:Grid.Width = 980; $script:Grid.Height = $gridHeight; $script:Grid.Location = New-Object System.Drawing.Point(10, 10)
    $script:Grid.ReadOnly = $true; $script:Grid.RowHeadersVisible = $false; $script:Grid.ScrollBars = "None"
    $script:Grid.AutoGenerateColumns = $false; $script:Grid.AutoSizeColumnsMode = 'Fill'
    $script:Form.Controls.Add($script:Grid)
    
    [void]$script:Grid.Columns.Add('Port','Port'); [void]$script:Grid.Columns.Add('Serial','Serial'); [void]$script:Grid.Columns.Add('Disk','Disk')
    [void]$script:Grid.Columns.Add('HP','HP'); [void]$script:Grid.Columns.Add('Title','Title'); [void]$script:Grid.Columns.Add('Progress','Progress')
    [void]$script:Grid.Columns.Add('Verdict','Verdict'); [void]$script:Grid.Columns.Add('Report','Report')
    
    $script:Grid.Columns['Port'].FillWeight=8; $script:Grid.Columns['Serial'].FillWeight=24; $script:Grid.Columns['Disk'].FillWeight=6
    $script:Grid.Columns['HP'].FillWeight=8; $script:Grid.Columns['Title'].FillWeight=30; $script:Grid.Columns['Progress'].FillWeight=12
    $script:Grid.Columns['Verdict'].FillWeight=8; $script:Grid.Columns['Report'].FillWeight=10
    
    $script:CountLabel = New-Object System.Windows.Forms.Label; $script:CountLabel.Text="Drives: 0"; $script:CountLabel.AutoSize=$true; $script:CountLabel.Location=New-Object System.Drawing.Point(10,($script:Grid.Bottom+5)); $script:Form.Controls.Add($script:CountLabel)
    
    # Watcher inputs
    $lblY = $script:Grid.Bottom + 28; $boxY = $script:Grid.Bottom + 24
    $l1=New-Object System.Windows.Forms.Label; $l1.Text="Pass LEN:"; $l1.AutoSize=$true; $l1.Location=New-Object System.Drawing.Point(10,$lblY); $script:Form.Controls.Add($l1)
    $script:PassLenBox=New-Object System.Windows.Forms.TextBox; $script:PassLenBox.Width=60; $script:PassLenBox.Text="$($script:DEFAULTS.PassLenMax)"; $script:PassLenBox.Location=New-Object System.Drawing.Point(70,$boxY); $script:Form.Controls.Add($script:PassLenBox)
    $l2=New-Object System.Windows.Forms.Label; $l2.Text="Fail LEN:"; $l2.AutoSize=$true; $l2.Location=New-Object System.Drawing.Point(140,$lblY); $script:Form.Controls.Add($l2)
    $script:FailLenBox=New-Object System.Windows.Forms.TextBox; $script:FailLenBox.Width=60; $script:FailLenBox.Text="$($script:DEFAULTS.FailLenMin)"; $script:FailLenBox.Location=New-Object System.Drawing.Point(200,$boxY); $script:Form.Controls.Add($script:FailLenBox)
    
    # Buttons
    $btnY = $script:Grid.Bottom + 56
    $script:CheckBtn=New-Object System.Windows.Forms.Button; $script:CheckBtn.Text="Check"; $script:CheckBtn.Location=New-Object System.Drawing.Point(10,$btnY); $script:CheckBtn.Add_Click({OnCheckButtonClick}); $script:Form.Controls.Add($script:CheckBtn)
    $script:ClosePassBtn=New-Object System.Windows.Forms.Button; $script:ClosePassBtn.Text="Close PASS"; $script:ClosePassBtn.Width=90; $script:ClosePassBtn.Location=New-Object System.Drawing.Point(90,$btnY); $script:ClosePassBtn.Add_Click({OnClosePassButtonClick}); $script:Form.Controls.Add($script:ClosePassBtn)
    $script:ClearBtn=New-Object System.Windows.Forms.Button; $script:ClearBtn.Text="Clear"; $script:ClearBtn.Location=New-Object System.Drawing.Point(185,$btnY); $script:ClearBtn.Add_Click({OnClearButtonClick}); $script:Form.Controls.Add($script:ClearBtn)
    $script:CloseBtn=New-Object System.Windows.Forms.Button; $script:CloseBtn.Text="Close"; $script:CloseBtn.Location=New-Object System.Drawing.Point(265,$btnY); $script:CloseBtn.Add_Click({OnCloseButtonClick}); $script:Form.Controls.Add($script:CloseBtn)
    
    # AUTOMATION PANEL
    $autoY = $script:Grid.Bottom + 90
    $script:AutoPanel = New-Object System.Windows.Forms.GroupBox; $script:AutoPanel.Text="Automation"; $script:AutoPanel.Location=New-Object System.Drawing.Point(10,$autoY); $script:AutoPanel.Size=New-Object System.Drawing.Size(980,195); $script:Form.Controls.Add($script:AutoPanel)
    
    # Helper to add rows
    function Add-AutoRow($chk,$box,$lbl,$y,$txt,$def,$unit,$nextObj) {
        $chk.Text=$txt; $chk.AutoSize=$true; $chk.Location=New-Object System.Drawing.Point(10,$y); $script:AutoPanel.Controls.Add($chk)
        $box.Width=50; $box.Text="$def"; $box.Location=New-Object System.Drawing.Point(135,($y-2)); $box.Add_TextChanged({Sync-AutomationConfig}); $script:AutoPanel.Controls.Add($box)
        $u=New-Object System.Windows.Forms.Label; $u.Text=$unit; $u.AutoSize=$true; $u.Location=New-Object System.Drawing.Point(195,$y); $script:AutoPanel.Controls.Add($u)
        
        # Primary Label (Timer) aligned at 280
        $nextObj.AutoSize=$true; $nextObj.Text="Wait: --:--"; $nextObj.Location=New-Object System.Drawing.Point(280,$y); $script:AutoPanel.Controls.Add($nextObj)
    }
    
    # Batch Label Helper (Creates a second label at X=390)
    function Add-BatchLbl($y) {
        $l = New-Object System.Windows.Forms.Label; $l.Text="Batch: 0"; $l.AutoSize=$true
        $l.Location = New-Object System.Drawing.Point(390, $y) # FIXED COLUMN FOR BATCH
        $script:AutoPanel.Controls.Add($l)
        return $l
    }

    $yA=22; $yB=46; $yC=70; $yD=94; $yE=118; $yF=142; $yG=166
    
    $script:AutoRefreshChk=New-Object System.Windows.Forms.CheckBox; $script:AutoRefreshBox=New-Object System.Windows.Forms.TextBox; $script:AutoRefreshNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoRefreshChk $script:AutoRefreshBox $script:AutoRefreshNextLbl $yA "Auto refresh" $script:DEFAULTS.AutoRefreshMin "minutes" $script:AutoRefreshNextLbl
    $script:AutoRefreshChk.Add_CheckedChanged({OnAutoRefreshToggle})

    $script:AutoCheckChk=New-Object System.Windows.Forms.CheckBox; $script:IntervalBox=New-Object System.Windows.Forms.TextBox; $script:AutoCheckNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoCheckChk $script:IntervalBox $script:AutoCheckNextLbl $yB "Auto check" $script:DEFAULTS.IntervalSec "seconds" $script:AutoCheckNextLbl
    $script:AutoCheckChk.Add_CheckedChanged({OnAutoCheckToggle})
    
    $script:AutoCleanChk=New-Object System.Windows.Forms.CheckBox; $script:AutoCleanBox=New-Object System.Windows.Forms.TextBox; $script:AutoCleanNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoCleanChk $script:AutoCleanBox $script:AutoCleanNextLbl $yC "Auto clean" "30" "seconds" $script:AutoCleanNextLbl
    $script:AutoCleanChk.Add_CheckedChanged({OnAutoCleanToggle})

    # WIPE (Has Batch)
    $script:AutoWipeChk=New-Object System.Windows.Forms.CheckBox; $script:AutoWipeBox=New-Object System.Windows.Forms.TextBox; $script:AutoWipeNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoWipeChk $script:AutoWipeBox $script:AutoWipeNextLbl $yD "Auto wipe" $script:DEFAULTS.AutoWipeSec "seconds" $script:AutoWipeNextLbl
    $script:AutoWipeBatchLbl = Add-BatchLbl $yD
    $script:AutoWipeChk.Add_CheckedChanged({OnAutoWipeToggle})

    # SAVE (Has Batch)
    $script:AutoSaveChk=New-Object System.Windows.Forms.CheckBox; $script:AutoSaveBox=New-Object System.Windows.Forms.TextBox; $script:AutoSaveNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoSaveChk $script:AutoSaveBox $script:AutoSaveNextLbl $yE "Auto save" $script:DEFAULTS.AutoSaveSec "seconds" $script:AutoSaveNextLbl
    $script:AutoSaveBatchLbl = Add-BatchLbl $yE
    $script:AutoSaveChk.Add_CheckedChanged({OnAutoSaveToggle})

    # SAVE PASS (Has Batch)
    $script:AutoSavePassedChk=New-Object System.Windows.Forms.CheckBox; $script:AutoSavePassedBox=New-Object System.Windows.Forms.TextBox; $script:AutoSavePassedNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoSavePassedChk $script:AutoSavePassedBox $script:AutoSavePassedNextLbl $yF "Auto save passed" "10" "seconds" $script:AutoSavePassedNextLbl
    $script:AutoSavePassedBatchLbl = Add-BatchLbl $yF
    $script:AutoSavePassedChk.Add_CheckedChanged({OnAutoSavePassedToggle})

    $script:AutoShutdownChk=New-Object System.Windows.Forms.CheckBox; $script:AutoShutdownBox=New-Object System.Windows.Forms.TextBox; $script:AutoShutdownNextLbl=New-Object System.Windows.Forms.Label
    Add-AutoRow $script:AutoShutdownChk $script:AutoShutdownBox $script:AutoShutdownNextLbl $yG "Auto shutdown" "10" "hours" $script:AutoShutdownNextLbl
    $script:AutoShutdownChk.Add_CheckedChanged({OnAutoShutdownToggle})

    # Resize Form
    $script:Form.ClientSize = New-Object System.Drawing.Size(($script:Grid.Right+10), ($script:AutoPanel.Bottom+10))
    $script:Form.Location = New-Object System.Drawing.Point(0,0)

    # Timer Tick
    $script:MasterTimer = New-Object System.Windows.Forms.Timer; $script:MasterTimer.Interval=1000
    $script:MasterTimer.Add_Tick({
        Master-TimerTick
        $script:AutoRefreshNextLbl.Text = if($script:AutoRefreshEnabled){ "Next run: $(Format-Countdown $script:NextRefreshAt)" } else { "Next run: --:--" }
        $script:AutoCheckNextLbl.Text   = if($script:AutoCheckEnabled)  { "Next run: $(Format-Countdown $script:NextCheckAt)" }   else { "Next run: --:--" }
        $script:AutoCleanNextLbl.Text   = if($script:AutoCleanEnabled)  { "Next run: $(Format-Countdown $script:NextCleanAt)" }   else { "Next run: --:--" }
        
        # Split Update Logic
        if($script:AutoWipeEnabled) { 
            $script:AutoWipeNextLbl.Text = "Wait: $(Format-Countdown $script:WipeBatchTimer)"
            $script:AutoWipeBatchLbl.Text = "Batch: $script:WipeBatchCount"
        } else { 
            $script:AutoWipeNextLbl.Text = "Wait: --:--"
            $script:AutoWipeBatchLbl.Text = "Batch: 0"
        }

        if($script:AutoSaveEnabled) { 
            $script:AutoSaveNextLbl.Text = "Wait: $(Format-Countdown $script:SaveBatchTimer)"
            $script:AutoSaveBatchLbl.Text = "Batch: $script:SaveBatchCount"
        } else { 
            $script:AutoSaveNextLbl.Text = "Wait: --:--"
            $script:AutoSaveBatchLbl.Text = "Batch: 0"
        }

        if($script:AutoSavePassedEnabled) { 
            $script:AutoSavePassedNextLbl.Text = "Wait: $(Format-Countdown $script:PassBatchTimer)"
            $script:AutoSavePassedBatchLbl.Text = "Batch: $script:PassBatchCount"
        } else { 
            $script:AutoSavePassedNextLbl.Text = "Wait: --:--"
            $script:AutoSavePassedBatchLbl.Text = "Batch: 0"
        }
        
        $script:AutoShutdownNextLbl.Text = if($script:AutoShutdownEnabled) { "Wait: $(Format-Countdown $script:NextShutdownAt)" } else { "Wait: --:--" }
    })
    $script:Form.Add_FormClosing({ Cleanup-Automation })
}

function Show-AutowipeGUI {
    Initialize-GUI; Refresh-Grid
    $script:__initDone=$false
    $script:AutoRefreshChk.Checked=[bool]$script:DEFAULTS.AutoRefresh
    $script:AutoCheckChk.Checked=[bool]$script:DEFAULTS.AutoCheck
    $script:AutoWipeChk.Checked=[bool]$script:DEFAULTS.AutoWipe
    $script:AutoSaveChk.Checked=[bool]$script:DEFAULTS.AutoSave
    $script:AutoSavePassedChk.Checked=[bool]$script:DEFAULTS.AutoSavePassed
    $script:__initDone=$true
    Sync-AutomationConfig; Initialize-Automation
    Start-AutomationTimers -masterTimer $script:MasterTimer
    [void]$script:Form.ShowDialog()
}
