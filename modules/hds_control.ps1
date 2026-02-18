# ==========================================================
# AUTOWIPE v4.5.1 (STABLE) - HDS CONTROL MODULE
# ==========================================================
# Purpose: HDS automation layer providing:
#   - Window finding/filtering
#   - Button clicking (standard + center-click)
#   - Toolbar interaction
#   - Popup handling (smart dismissal)
#   - "Safe List" logic to protect main dashboard
#
# Dependencies: CORE.ps1
# Used by: AUTOMATION.ps1
# ==========================================================
# Purpose: Hard Disk Sentinel automation API providing:
#   - HDS process/window management
#   - Status checking
#   - Automation commands (Refresh, Save, Wipe)
#   - HDS_SmartCleanup (Safe logic with #32770 filter)
#
# Dependencies: CORE.ps1 (for Log, constants)
# ==========================================================

if(-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    throw "HDS_CONTROL requires CORE module. Load core.ps1 first."
}

# Load UIA
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
} catch {
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName("UIAutomationClient")
        [void][System.Reflection.Assembly]::LoadWithPartialName("UIAutomationTypes")
    } catch {}
}

# ==========================================================
# SECTION 1: HDS CONFIGURATION
# ==========================================================

$script:HDSExePath  = 'C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.exe'
$script:ProcessName = 'HDSentinel'

# Toolbar coordinates
$script:HDS_RefreshX = 18
$script:HDS_RefreshY = 20
$script:HDS_SurfaceX = 185
$script:HDS_SurfaceY = 13

# Timing constants
$script:HDS_PostDelayMs         = 40
$script:HDS_WaitAuthenticSec    = 12
$script:HDS_PopupSweepTimeoutMs = 10000
$script:HDS_ChildPollTimeoutMs  = 2000
$script:HDS_ChildPollEveryMs    = 70
$script:HDS_QuietPeriodMs       = 350

# Constants
$script:HDS_SW_RESTORE     = 9
$script:HDS_WM_MOUSEMOVE   = 0x0200
$script:HDS_WM_LBUTTONDOWN = 0x0201
$script:HDS_WM_LBUTTONUP   = 0x0202
$script:HDS_MK_LBUTTON     = 0x0001
$script:HDS_GW_OWNER       = 4
$script:HDS_IDOK           = 1
$script:HDS_IDYES          = 6

$script:IsBusy = $false

# ==========================================================
# SECTION 2: WIN32 HELPERS
# ==========================================================

function HDS_Strip { param([string]$s) if(-not $s) { return "" } ($s -replace '[&$]','').Trim() }
function HDS_MakeLParam { param([int]$x, [int]$y) [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF)) }

function HDS_GetClass {
    param([IntPtr]$h)
    $sb = New-Object System.Text.StringBuilder 256
    [void][HDSNative.U32]::GetClassNameW($h, $sb, $sb.Capacity)
    $sb.ToString()
}

function HDS_GetText {
    param([IntPtr]$h)
    $sb = New-Object System.Text.StringBuilder 512
    [void][HDSNative.U32]::GetWindowTextW($h, $sb, $sb.Capacity)
    $sb.ToString()
}

function HDS_GetWindowRect {
    param([IntPtr]$h)
    $r = New-Object HDSNative.RECT
    [void][HDSNative.U32]::GetWindowRect($h, [ref]$r)
    $r
}

function HDS_FocusWindow {
    param([IntPtr]$h)
    if($h -eq [IntPtr]::Zero) { return }
    [HDSNative.U32]::ShowWindow($h, $script:HDS_SW_RESTORE)   | Out-Null
    [HDSNative.U32]::BringWindowToTop($h)                      | Out-Null
    [HDSNative.U32]::SetForegroundWindow($h)                   | Out-Null
}

function HDS_WaitDialogClosed {
    param([IntPtr]$dlg, [int]$timeoutMs = 1500)
    $t0 = Get-Date
    while((Get-Date) - $t0 -lt [TimeSpan]::FromMilliseconds($timeoutMs)) {
        if(-not [HDSNative.U32]::IsWindow($dlg)) { return $true }
        Start-Sleep -Milliseconds 60
    }
    $false
}

# ==========================================================
# SECTION 3: WINDOW DISCOVERY
# ==========================================================

function HDS_GetTopLevelVisible {
    $list = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    $cb = [HDSNative.U32+EnumProc]{ 
        param([IntPtr]$h, [IntPtr]$l)
        if([HDSNative.U32]::IsWindowVisible($h)) { $list.Add($h) | Out-Null }
        $true
    }
    [HDSNative.U32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    ,$list.ToArray()
}

function HDS_SnapshotTopLevel {
    $hs = @{}
    foreach($h in (HDS_GetTopLevelVisible)) { $hs["$h"] = 1 }
    $hs
}

function HDS_GetProcess { Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1 }

function HDS_GetTopWindowsOfProcess {
    param([int]$targetPid)
    $tops = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    $cb = [HDSNative.U32+EnumProc]{ 
        param([IntPtr]$h, [IntPtr]$l)
        $pp = 0
        [void][HDSNative.U32]::GetWindowThreadProcessId($h, [ref]$pp)
        if($pp -eq $l.ToInt32()) { $tops.Add($h) | Out-Null }
        $true
    }
    [HDSNative.U32]::EnumWindows($cb, [IntPtr]$targetPid) | Out-Null
    $tops
}

function HDS_GetMainWindowHandle {
    param([System.Diagnostics.Process]$Proc)
    if(-not $Proc) { return [IntPtr]::Zero }
    $h = $Proc.MainWindowHandle
    if($h -and $h -ne [IntPtr]::Zero) { return $h }
    $wins = HDS_GetTopWindowsOfProcess $Proc.Id
    foreach($w in $wins) { if([HDSNative.U32]::IsWindow($w)) { return $w } }
    [IntPtr]::Zero
}

function HDS_TestWindowResponsive {
    param([IntPtr]$Handle, [int]$TimeoutMs = 800)
    if(-not $Handle -or $Handle -eq [IntPtr]::Zero) { return $false }
    $res = [UIntPtr]::Zero
    $ptr = [HDSNative.U32]::SendMessageTimeout($Handle, [HDSNative.U32]::WM_NULL, [UIntPtr]::Zero, [IntPtr]::Zero, [HDSNative.U32]::SMTO_ABORTIFHUNG, [uint32]$TimeoutMs, [ref]$res)
    ($ptr -ne [IntPtr]::Zero)
}

function HDS_TestOwnedBy {
    param([IntPtr]$child, [IntPtr]$owner)
    if($child -eq [IntPtr]::Zero -or $owner -eq [IntPtr]::Zero) { return $false }
    $cur = $child
    for($i = 0; $i -lt 8; $i++) {
        $cur = [HDSNative.U32]::GetWindow($cur, [uint32]$script:HDS_GW_OWNER)
        if($cur -eq [IntPtr]::Zero) { return $false }
        if($cur -eq $owner) { return $true }
    }
    $false
}

function HDS_FindTForm3Window {
    $hdsProcess = Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue
    if(-not $hdsProcess) { return [IntPtr]::Zero }
    $hdsPid = $hdsProcess.Id
    $script:foundTForm3 = [IntPtr]::Zero
    $callback = [HDSNative.U32+EnumProc] {
        param($hwnd, $lParam)
        try {
            $windowPid = 0
            [HDSNative.U32]::GetWindowThreadProcessId($hwnd, [ref]$windowPid) | Out-Null
            if($windowPid -eq $hdsPid) {
                $className = New-Object System.Text.StringBuilder 256
                [HDSNative.U32]::GetClassNameW($hwnd, $className, 256) | Out-Null
                if($className.ToString() -eq "TForm3") {
                    $script:foundTForm3 = $hwnd
                    return $false
                }
            }
        } catch {}
        $true
    }
    [HDSNative.U32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    $script:foundTForm3
}

function HDS_GetAllDescendants {
    param([IntPtr]$parent)
    $list = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l); $list.Add($h) | Out-Null; $true }
    [HDSNative.U32]::EnumChildWindows($parent, $cb, [IntPtr]::Zero) | Out-Null
    $list
}

function HDS_FindToolbarByTitle {
    foreach($tw in (HDS_GetTopLevelVisible)) {
        $title = HDS_GetText $tw
        if(-not $title) { continue }
        if($title -notlike '*Hard Disk Sentinel*') { continue }
        if($title -like '*Surface Test*') { continue }
        $kids = HDS_GetAllDescendants $tw
        foreach($h in $kids) {
            $cls = HDS_GetClass $h
            if($cls -match '^(ToolbarWindow32|ToolBarWindow32|TToolBar.*)$') { return $h }
        }
    }
    [IntPtr]::Zero
}

# ==========================================================
# SECTION 4: HDS STATUS API
# ==========================================================

function Get-HDSStatus {
    $p = HDS_GetProcess
    if(-not $p) { return 'NotRunning' }
    $hMain = HDS_GetMainWindowHandle $p
    if($hMain -eq [IntPtr]::Zero) { return 'Starting' }
    $isIconic = [HDSNative.U32]::IsIconic($hMain)
    $responsive = HDS_TestWindowResponsive $hMain 800
    if(-not $responsive) { return 'Hung' }
    if($isIconic) { return 'Minimized' }
    if(-not [HDSNative.U32]::IsWindowEnabled($hMain)) { return 'Modal' }
    $tops = HDS_GetTopWindowsOfProcess $p.Id
    foreach($w in $tops) {
        if(-not [HDSNative.U32]::IsWindowVisible($w)) { continue }
        if((HDS_GetClass $w) -ne '#32770') { continue }
        if(HDS_TestOwnedBy $w $hMain) { return 'Modal' }
    }
    'Ready'
}

function HDS_EnsureReady {
    $p = HDS_GetProcess
    if(-not $p) {
        if(-not (Test-Path $script:HDSExePath)) { Log 'HDS_EXE_NOT_FOUND' @{ path = $script:HDSExePath }; return $null }
        Log 'HDS_LAUNCHING' @{ path = $script:HDSExePath }
        Start-Process -FilePath $script:HDSExePath | Out-Null
        Start-Sleep -Milliseconds 800
        $p = HDS_GetProcess
        if(-not $p) { Log 'HDS_LAUNCH_FAILED' @{}; return $null }
    }
    $h = HDS_GetMainWindowHandle $p
    if($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 600; $h = HDS_GetMainWindowHandle $p }
    if($h -ne [IntPtr]::Zero) {
        if([HDSNative.U32]::IsIconic($h)) { [HDSNative.U32]::ShowWindow($h, $script:HDS_SW_RESTORE) | Out-Null; Start-Sleep -Milliseconds 120 }
        HDS_FocusWindow $h
        if(-not (HDS_TestWindowResponsive $h 1200)) { Log 'HDS_NOT_RESPONSIVE' @{}; return $null }
        return [pscustomobject]@{ Proc = $p; Hwnd = $h }
    }
    Log 'HDS_NO_WINDOW' @{}; $null
}

function HDS_CanProceedAuto {
    param([string]$operationTag)
    $st = Get-HDSStatus
    if($st -in @('NotRunning','Starting','Modal','Hung')) { Log 'HDS_AUTO_SKIP' @{ tag = $operationTag; status = $st }; return $false }
    if($st -eq 'Minimized') {
        $r = HDS_EnsureReady
        if(-not $r) { Log 'HDS_AUTO_SKIP' @{ tag = $operationTag; status = 'MinimizedEnsureFail' }; return $false }
    }
    $true
}

# ==========================================================
# SECTION 5: BUTTON/CONTROL HELPERS
# ==========================================================

function HDS_FindButton {
    param([IntPtr]$dlg, [string[]]$preferCaptions, [int[]]$preferIds)
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l)
        $cls = HDS_GetClass $h
        if($cls -notmatch 'Button') { return $true }
        $id = [HDSNative.U32]::GetDlgCtrlID($h)
        $cap = HDS_Strip (HDS_GetText $h)
        foreach($prefId in $script:__ids) { if($id -eq $prefId) { $script:__btn = $h; return $false } }
        foreach($pc in $script:__caps) { if($cap -ieq $pc) { $script:__btn = $h; return $false } }
        $true
    }
    $script:__caps = $preferCaptions; $script:__ids = $preferIds; $script:__btn = [IntPtr]::Zero
    [HDSNative.U32]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero) | Out-Null
    $script:__btn
}

function HDS_FindChildByCaption {
    param([IntPtr]$dlg, [string]$caption)
    $script:__wanted = HDS_Strip $caption; $script:__found = [IntPtr]::Zero
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l)
        $txt = HDS_Strip (HDS_GetText $h)
        if($txt -and $txt -ieq $script:__wanted) { $script:__found = $h; return $false }
        $true
    }
    [HDSNative.U32]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero) | Out-Null
    $script:__found
}

function HDS_FindChildCaptionLike {
    param([IntPtr]$dlg, [string]$contains)
    $script:__found = [IntPtr]::Zero; $script:__needle = $contains.ToLower()
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l)
        $txt = HDS_Strip (HDS_GetText $h)
        if($txt -and $txt.ToLower().Contains($script:__needle)) { $script:__found = $h; return $false }
        $true
    }
    [HDSNative.U32]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero) | Out-Null
    $script:__found
}

function HDS_ClickCenter {
    param([IntPtr]$btn, [IntPtr]$owner, [string]$label = 'Click')
    if($btn -eq [IntPtr]::Zero) { return $false }
    if($owner -ne [IntPtr]::Zero) { HDS_FocusWindow $owner }
    $rc = HDS_GetWindowRect $btn
    $cx = [int]([Math]::Max(1, ($rc.Right - $rc.Left) / 2))
    $cy = [int]([Math]::Max(1, ($rc.Bottom - $rc.Top) / 2))
    $lp = HDS_MakeLParam $cx $cy
    [HDSNative.U32]::PostMessageW($btn, [uint32]$script:HDS_WM_MOUSEMOVE, [IntPtr]0, $lp) | Out-Null
    Start-Sleep -Milliseconds 10
    [HDSNative.U32]::PostMessageW($btn, [uint32]$script:HDS_WM_LBUTTONDOWN, [IntPtr]$script:HDS_MK_LBUTTON, $lp) | Out-Null
    Start-Sleep -Milliseconds $script:HDS_PostDelayMs
    [HDSNative.U32]::PostMessageW($btn, [uint32]$script:HDS_WM_LBUTTONUP, [IntPtr]0, $lp) | Out-Null
    Log 'HDS_CLICK' @{ label = $label; btn = ('0x{0:X}' -f $btn.ToInt64()) }
    $true
}

function HDS_ClickToolbarClient {
    param([IntPtr]$hToolbar, [int]$x, [int]$y, [string]$tag = 'Toolbar')
    $lp = HDS_MakeLParam $x $y
    [HDSNative.U32]::PostMessageW($hToolbar, [uint32]$script:HDS_WM_MOUSEMOVE, [IntPtr]0, $lp) | Out-Null
    Start-Sleep -Milliseconds 10
    [HDSNative.U32]::PostMessageW($hToolbar, [uint32]$script:HDS_WM_LBUTTONDOWN, [IntPtr]$script:HDS_MK_LBUTTON, $lp) | Out-Null
    Start-Sleep -Milliseconds $script:HDS_PostDelayMs
    [HDSNative.U32]::PostMessageW($hToolbar, [uint32]$script:HDS_WM_LBUTTONUP, [IntPtr]0, $lp) | Out-Null
    Log 'HDS_TOOLBAR_CLICK' @{ tag = $tag; toolbar = ('0x{0:X}' -f $hToolbar.ToInt64()) }
}

# ==========================================================
# SECTION 6: POPUP HANDLING (SNAPSHOT + CLASS SAFE)
# ==========================================================

function HDS_DismissPopupsSince {
    param(
        [hashtable]$Snapshot,
        [int]$TimeoutMs = $script:HDS_PopupSweepTimeoutMs,
        [string[]]$PreferredCaptions = @('Yes','OK','Save','Close','No'),
        [int[]]$PreferredIds = @($script:HDS_IDYES, $script:HDS_IDOK)
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $quietUntil = (Get-Date).AddMilliseconds($script:HDS_QuietPeriodMs)
    
    while((Get-Date) -lt $deadline) {
        $newFound = $false
        foreach($hw in (HDS_GetTopLevelVisible)) {
            $k = "$hw"
            
            # 1. SNAPSHOT CHECK: If window was in snapshot (Safe List), skip it
            if($Snapshot.ContainsKey($k)) { continue }
            
            # 2. CLASS CHECK (SAFETY): Only target Standard Dialogs (#32770)
            # This prevents killing Notepad, Explorer, etc.
            $cls = HDS_GetClass $hw
            if($cls -ne '#32770') { continue }

            # 3. SAFETY CHECK: Skip Main Window or Surface Test just in case
            $title = HDS_GetText $hw
            if($title -like '*Surface Test*' -or ($title -like '*Hard Disk Sentinel*' -and $title -notlike '*Error*')) { 
                $Snapshot[$k] = 1
                continue 
            }

            # If we got here, it's a NEW DIALOG (Popup)
            $Snapshot[$k] = 1 # Mark as seen
            $newFound = $true
            
            Log 'HDS_POPUP_DETECTED' @{ hwnd = ('0x{0:X}' -f $hw.ToInt64()); title = $title; class = $cls }
            
            $btn = [IntPtr]::Zero
            $t1 = Get-Date
            do {
                $btn = HDS_FindButton -dlg $hw -preferCaptions $PreferredCaptions -preferIds $PreferredIds
                if($btn -ne [IntPtr]::Zero) { break }
                Start-Sleep -Milliseconds 50
            } while((Get-Date) - $t1 -lt [TimeSpan]::FromMilliseconds(500))
            
            if($btn -ne [IntPtr]::Zero) {
                [void](HDS_ClickCenter $btn $hw 'Dismiss')
                [void](HDS_WaitDialogClosed $hw 1000)
                Log 'HDS_POPUP_DISMISSED' @{ title = $title }
            }
        }
        if($newFound) { $quietUntil = (Get-Date).AddMilliseconds($script:HDS_QuietPeriodMs) }
        elseif((Get-Date) -ge $quietUntil) { return }
        Start-Sleep -Milliseconds 80
    }
}

function HDS_SmartCleanup {
    param([int]$TimeoutMs = 1500)
    
    # Create "Safe List" (Snapshot) of windows we DO NOT want to close
    $safeSnap = @{}
    
    # 1. Add Main Window
    $p = HDS_GetProcess
    if($p) {
        $main = HDS_GetMainWindowHandle $p
        if($main) { $safeSnap["$main"] = 1 }
    }
    
    # 2. Add Surface Test Window
    foreach($hw in (HDS_GetTopLevelVisible)){
        $t = HDS_GetText $hw
        if($t -like '*Surface Test*') { $safeSnap["$hw"] = 1 }
    }
    
    # 3. Kill new dialogs that appear
    HDS_DismissPopupsSince -Snapshot $safeSnap -TimeoutMs $TimeoutMs
}

function HDS_EnsureReadyAndClearModals {
    $ready = HDS_EnsureReady
    if(-not $ready) { return $null }
    
    # Build a snapshot of the current state so we don't kill the main window
    $snap = @{}
    $snap["$($ready.Hwnd)"] = 1
    
    HDS_DismissPopupsSince -Snapshot $snap -TimeoutMs 1500
    $ready
}

# ==========================================================
# SECTION 7: UIAUTOMATION HELPERS
# ==========================================================

function HDS_WaitWindowByNameLike {
    param([string]$contains, [int]$timeoutMs = 8000)
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    do {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        for($i = 0; $i -lt $all.Count; $i++) {
            $w = $all.Item($i)
            try {
                if($w.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window -or $w.Current.IsOffscreen) { continue }
                if($w.Current.Name -and $w.Current.Name.ToLower().Contains($contains.ToLower())) { return $w }
            } catch {}
        }
        Start-Sleep -Milliseconds 120
    } until((Get-Date) -gt $deadline)
    $null
}

function HDS_WaitAuthenticList {
    param([int]$ProcId, [int]$TimeoutSec = $script:HDS_WaitAuthenticSec)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $pidCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, ([int]$ProcId))
    $end = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Milliseconds 150
        $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
        for($i = 0; $i -lt $wins.Count; $i++) {
            $w = $wins.Item($i)
            if($w.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window -or $w.Current.IsOffscreen) { continue }
            $h = [IntPtr]$w.Current.NativeWindowHandle
            if($h -eq [IntPtr]::Zero) { continue }
            $title = $w.Current.Name
            $cls = HDS_GetClass $h
            if($title -like '*Authentic Disk Report*' -or $cls -like 'TFormDriveSelect*') { return $h }
        }
    } while((Get-Date) -lt $end)
    [IntPtr]::Zero
}

function HDS_ToggleCheckbox {
    param($el, [string]$state)
    try {
        $p = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if($state -eq 'On' -and $p.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $p.Toggle() }
        if($state -eq 'Off' -and $p.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { $p.Toggle() }
        $true
    } catch { $false }
}

function HDS_UncheckAllCheckboxes {
    param([System.Windows.Automation.AutomationElement]$root)
    $checks = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)))
    for($i = 0; $i -lt $checks.Count; $i++) { [void](HDS_ToggleCheckbox $checks.Item($i) 'Off') }
}

function HDS_FindElementNameContainsNorm {
    param([System.Windows.Automation.AutomationElement]$root, [string]$needleNorm)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    for($i = 0; $i -lt $all.Count; $i++) {
        $el = $all.Item($i)
        try { if($el.Current.Name -and (Normalize-Serial $el.Current.Name).Contains($needleNorm)) { return $el } } catch {}
    }
    $null
}

function HDS_GetOSDiskSerial {
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $part = Get-CimAssociatedInstance -InputObject $c -ResultClassName Win32_DiskPartition | Select-Object -First 1
        $disk = Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_DiskDrive | Select-Object -First 1
        $norm = Normalize-Serial $disk.SerialNumber
        Log 'HDS_OS_DISK' @{ serial = $norm }
        $norm
    } catch { Log 'HDS_OS_DISK_FAIL' @{ err = $_.Exception.Message }; $null }
}

function HDS_GetOSDiskIndex {
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $part = Get-CimAssociatedInstance -InputObject $c -ResultClassName Win32_DiskPartition | Select-Object -First 1
        $disk = Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_DiskDrive | Select-Object -First 1
        $idx = ($disk.Index -as [int])
        if($idx -ge 0) {
            Log 'HDS_OS_DISK_INDEX' @{ disk = $idx }
            return $idx
        }
        $null
    } catch { Log 'HDS_OS_DISK_INDEX_FAIL' @{ err = $_.Exception.Message }; $null }
}

function HDS_WaitSurfaceConfigWindow([int]$timeoutMs=8000){
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  do{
    foreach($hw in (HDS_GetTopLevelVisible)){
      $title = HDS_GetText $hw
      if(-not $title){ continue }
      if($title -notlike '*Surface Test*'){ continue }
      
      $btnMulti = HDS_FindChildByCaption $hw 'Multiple disk drives'
      if($btnMulti -eq [IntPtr]::Zero){ $btnMulti = HDS_FindChildByCaption $hw 'Multiple' }
      if($btnMulti -ne [IntPtr]::Zero){ return [pscustomobject]@{ Hwnd = $hw } }
    }
    Start-Sleep -Milliseconds 150
  } until((Get-Date) -gt $deadline)
  $null
}

function HDS_WaitDriveSelectorWindow {
  param([int]$timeoutMs=8000, [IntPtr]$ownerHwnd=[IntPtr]::Zero)
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  do{
    $p = HDS_GetProcess
    if($p){
      foreach($hw in (HDS_GetTopWindowsOfProcess $p.Id)){
        try{
          if($hw -eq [IntPtr]::Zero -or -not [HDSNative.U32]::IsWindowVisible($hw)){ continue }
          if($ownerHwnd -ne [IntPtr]::Zero -and -not (HDS_TestOwnedBy $hw $ownerHwnd)){ continue }

          $title = HDS_GetText $hw
          $cls = HDS_GetClass $hw
          $isSelector = ($title -like 'Surface Test*' -and $title -notlike '*Hard Disk Sentinel*') -or ($cls -like 'TFormDriveSelect*')
          if(-not $isSelector){ continue }

          HDS_FocusWindow $hw
          try{
            $ae = [System.Windows.Automation.AutomationElement]::FromHandle($hw)
            if($ae){ return $ae }
          }catch{}
        }catch{}
      }
    }

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    for($i = 0; $i -lt $wins.Count; $i++){
      $w = $wins.Item($i)
      try{
        if($w.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window){ continue }
        if($w.Current.IsOffscreen){ continue }
        $name = $w.Current.Name
        if(-not $name){ continue }

        if($name -like 'Surface Test*' -and $name -notlike '*Hard Disk Sentinel*'){
          return $w
        }
      }catch{}
    }
    Start-Sleep -Milliseconds 150
  } until((Get-Date) -gt $deadline)
  $null
}

function HDS_FindRowByDiskIndex {
  param([System.Windows.Automation.AutomationElement]$dlgAE, [int]$DiskIndex)
  $all = $dlgAE.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  for($i = 0; $i -lt $all.Count; $i++){
    $el = $all.Item($i)
    try{
      $name = $el.Current.Name
      if(-not $name){ continue }
      if($name -match "^\s*$DiskIndex\s*$"){
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $parent = $el
        for($j = 0; $j -lt 5; $j++){
          $parent = $walker.GetParent($parent)
          if(-not $parent){ break }
          if($parent.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataItem){
            return $parent
          }
        }
      }
    }catch{}
  }
  $null
}

function HDS_GetTestTypeComboSurf([IntPtr]$surfHwnd){
  if($surfHwnd -eq [IntPtr]::Zero){ return [IntPtr]::Zero }
  $script:__combo=[IntPtr]::Zero
  $cb=[HDSNative.U32+EnumProc]{ param([IntPtr]$h,[IntPtr]$l)
    $cls = HDS_GetClass $h
    if($cls -ne 'TComboBox'){ return $true }
    $txt = HDS_Strip (HDS_GetText $h)
    if(-not $txt -or $txt -like 'Read test*' -or $txt -like '*test*'){
      $script:__combo = $h
      return $false
    }
    $true
  }
  [HDSNative.U32]::EnumChildWindows($surfHwnd,$cb,[IntPtr]::Zero)|Out-Null
  $script:__combo
}

# ==========================================================
# SECTION 8: AUTOMATION COMMANDS
# ==========================================================

function Run-Refresh {
    if($script:IsBusy) { return }
    $script:IsBusy = $true
    try {
        $ready = HDS_EnsureReadyAndClearModals; if(-not $ready) { return }
        $tw = $ready.Hwnd
        $toolbar = HDS_FindToolbarByTitle; if($toolbar -eq [IntPtr]::Zero) { Log 'HDS_TOOLBAR_NOT_FOUND' @{}; return }
        HDS_FocusWindow $tw; Start-Sleep -Milliseconds 120
        $snap = HDS_SnapshotTopLevel
        HDS_ClickToolbarClient -hToolbar $toolbar -x $script:HDS_RefreshX -y $script:HDS_RefreshY -tag 'Refresh'
        HDS_DismissPopupsSince -Snapshot $snap -TimeoutMs $script:HDS_PopupSweepTimeoutMs -PreferredCaptions @('Yes','OK','Save') -PreferredIds @($script:HDS_IDYES, $script:HDS_IDOK)
        Log 'HDS_REFRESH_DONE' @{}
    } finally { $script:IsBusy = $false }
}

function Run-SaveAuthentic-BySerials {
    param([string[]]$SerialsNorm)
    if(-not $SerialsNorm -or $SerialsNorm.Count -eq 0) { Log 'HDS_SAVE_NO_SERIALS' @{}; return @() }
    Log 'HDS_SAVE_START' @{ count = $SerialsNorm.Count; serials = ($SerialsNorm -join ',') }
    $ready = HDS_EnsureReadyAndClearModals; if(-not $ready) { return @() }
    $hdsPid = $ready.Proc.Id; $hdsHwnd = $ready.Hwnd
    HDS_FocusWindow $hdsHwnd; Start-Sleep -Milliseconds 200
    $tform3 = HDS_FindTForm3Window; if($tform3 -eq [IntPtr]::Zero) { Log 'HDS_TFORM3_NOT_FOUND' @{}; return @() }
    [HDSNative.U32]::PostMessageW($tform3, [HDSNative.U32]::WM_COMMAND, [IntPtr]50, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 220
    $dlg = HDS_WaitAuthenticList -ProcId $hdsPid -TimeoutSec $script:HDS_WaitAuthenticSec; if($dlg -eq [IntPtr]::Zero) { Log 'HDS_AUTHENTIC_DLG_NOT_FOUND' @{}; return @() }
    $dlgAE = [System.Windows.Automation.AutomationElement]::FromHandle($dlg)
    HDS_UncheckAllCheckboxes $dlgAE
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $condCheckbox = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach($sn in $SerialsNorm) {
        $cell = HDS_FindElementNameContainsNorm $dlgAE $sn; if(-not $cell) { Log 'HDS_SAVE_SERIAL_NOT_FOUND' @{ serial = $sn }; continue }
        $row = $cell
        for($j=0; $j -lt 6; $j++) { $p = $walker.GetParent($row); if(-not $p){break}; if($p.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataItem){ $row=$p; break } $row=$p }
        $rowCheck = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condCheckbox)
        if($rowCheck) { if(HDS_ToggleCheckbox $rowCheck 'On') { $hits.Add($sn)|Out-Null; Log 'HDS_SAVE_CHECKED' @{ serial = $sn } } }
    }
    if($hits.Count -eq 0) { Log 'HDS_SAVE_NO_MATCHES' @{}; return @() }
    $ok = HDS_FindChildByCaption $dlg 'OK'; if($ok -eq [IntPtr]::Zero) { Log 'HDS_SAVE_OK_NOT_FOUND' @{}; return @() }
    $snap = HDS_SnapshotTopLevel
    [void](HDS_ClickCenter $ok $dlg 'OK'); [void](HDS_WaitDialogClosed $dlg 1500)
    
    # Use Snapshot logic for cleanup
    HDS_DismissPopupsSince -Snapshot $snap -TimeoutMs 2000 -PreferredCaptions @('Save','Yes','OK') -PreferredIds @($script:HDS_IDOK, $script:HDS_IDYES)
    
    Log 'HDS_SAVE_DONE' @{ requested = $SerialsNorm.Count; saved = $hits.Count }
    return ,($hits | ForEach-Object { Normalize-Serial $_ } | Where-Object { $_ })
}

function Run-WipeByDiskIndices {
    param([int[]]$DiskIndices, [hashtable]$RetryAttempts, [hashtable]$GiveUpDisks)
    if($script:IsBusy) { return @() }
    $script:IsBusy = $true
    try {
        if(-not $DiskIndices -or $DiskIndices.Count -eq 0) { Log 'HDS_WIPE_NO_INDICES' @{}; return @() }
        $osSerialNorm = HDS_GetOSDiskSerial
        $osDiskIndex = HDS_GetOSDiskIndex

        $diskSerialByIndex = @{}
        try {
            $disks = Get-CimInstance Win32_DiskDrive -ErrorAction Stop
            foreach($d in $disks) {
                $idx = ($d.Index -as [int])
                if($idx -lt 0) { continue }
                $diskSerialByIndex[$idx] = Normalize-Serial ([string]$d.SerialNumber)
            }
        } catch {
            Log 'HDS_WIPE_DISK_SERIAL_LOOKUP_FAIL' @{ err = $_.Exception.Message }
        }

        if(Get-Command 'Get-HdsXmlMap' -ErrorAction SilentlyContinue) {
            try {
                $xmlMap = Get-HdsXmlMap
                foreach($xmlKey in $xmlMap.Keys) {
                    $idx = ($xmlKey -as [int])
                    if($idx -lt 0) { continue }
                    if($diskSerialByIndex.ContainsKey($idx) -and $diskSerialByIndex[$idx]) { continue }
                    $entry = $xmlMap[$xmlKey]
                    $serialNorm = Normalize-Serial ([string]$entry.SerialNorm)
                    if(-not $serialNorm) { $serialNorm = Normalize-Serial ([string]$entry.SerialRaw) }
                    if($serialNorm) { $diskSerialByIndex[$idx] = $serialNorm }
                }
            } catch {
                Log 'HDS_WIPE_XML_SERIAL_LOOKUP_FAIL' @{ err = $_.Exception.Message }
            }
        }

        $safeDiskIndices = New-Object System.Collections.Generic.List[int]
        foreach($diskIdx in $DiskIndices) {
            $idx = [int]$diskIdx
            $serialNorm = ''
            if($diskSerialByIndex.ContainsKey($idx)) { $serialNorm = [string]$diskSerialByIndex[$idx] }
            $isOsDisk = ($osDiskIndex -ne $null -and $idx -eq [int]$osDiskIndex)
            if(-not $isOsDisk -and $osSerialNorm -and $serialNorm -and $serialNorm -eq $osSerialNorm) {
                $isOsDisk = $true
            }
            if($isOsDisk) {
                Log 'HDS_WIPE_SKIP_OS_DISK' @{ disk = $idx; serial = $serialNorm }
                continue
            }
            if(-not $safeDiskIndices.Contains($idx)) { $safeDiskIndices.Add($idx) | Out-Null }
        }

        if($safeDiskIndices.Count -eq 0) {
            Log 'HDS_WIPE_ALL_SKIPPED' @{ reason = 'os_disk_guard'; requested = $DiskIndices.Count }
            return @()
        }

        $ready = HDS_EnsureReadyAndClearModals; if(-not $ready) { return @() }
        $tw = $ready.Hwnd
        $toolbar = HDS_FindToolbarByTitle; if($toolbar -eq [IntPtr]::Zero) { Log 'HDS_TOOLBAR_NOT_FOUND' @{}; return @() }

        HDS_FocusWindow $tw; Start-Sleep -Milliseconds 120
        Log 'HDS_WIPE_STARTING' @{ count = $safeDiskIndices.Count; requested = $DiskIndices.Count }
        
        $snapBefore = HDS_SnapshotTopLevel
        HDS_ClickToolbarClient -hToolbar $toolbar -x $script:HDS_SurfaceX -y $script:HDS_SurfaceY -tag 'Surface Test'
        
        $initDlg = HDS_WaitWindowByNameLike 'initializing' 4000
        if($initDlg) { $hInit = [IntPtr]$initDlg.Current.NativeWindowHandle; if($hInit -ne [IntPtr]::Zero) { [void](HDS_WaitDialogClosed $hInit 15000) } }
        
        $surf = HDS_WaitSurfaceConfigWindow 8000; if(-not $surf) { Log 'HDS_SURFACE_CONFIG_NOT_FOUND' @{}; return @() }
        $surfHwnd = $surf.Hwnd; HDS_FocusWindow $surfHwnd
        
        # CLICK MULTIPLE BUTTON
        $btnMultiHwnd = HDS_FindChildByCaption $surfHwnd 'Multiple disk drives'
        if($btnMultiHwnd -eq [IntPtr]::Zero) { $btnMultiHwnd = HDS_FindChildByCaption $surfHwnd 'Multiple' }
        if($btnMultiHwnd -eq [IntPtr]::Zero) { Log 'HDS_WIPE_MULTIPLE_BTN_NOT_FOUND' @{}; return @() }
        [void](HDS_ClickCenter $btnMultiHwnd $surfHwnd 'Multiple')
        
        # HANDLE SELECTOR
        $selectAE = $null
        for($attempt = 1; $attempt -le 3; $attempt++) {
            $selectAE = HDS_WaitDriveSelectorWindow -timeoutMs 2500 -ownerHwnd $surfHwnd
            if($selectAE) { break }
            Log 'HDS_WIPE_SELECTOR_RETRY' @{ attempt = $attempt }
            HDS_FocusWindow $surfHwnd
            Start-Sleep -Milliseconds 120
            $btnRetry = HDS_FindChildByCaption $surfHwnd 'Multiple disk drives'
            if($btnRetry -eq [IntPtr]::Zero) { $btnRetry = HDS_FindChildByCaption $surfHwnd 'Multiple' }
            if($btnRetry -ne [IntPtr]::Zero) {
                [void](HDS_ClickCenter $btnRetry $surfHwnd 'Multiple retry')
            }
        }
        if(-not $selectAE) { Log 'HDS_WIPE_SELECTOR_NOT_FOUND' @{}; return @() }
        $selectHwnd = [IntPtr]$selectAE.Current.NativeWindowHandle; HDS_FocusWindow $selectHwnd
        HDS_UncheckAllCheckboxes $selectAE
        
        $hits = New-Object System.Collections.Generic.List[int]
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $condCheckbox = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)
        
        foreach($diskIdx in $safeDiskIndices) {
            $row = HDS_FindRowByDiskIndex -dlgAE $selectAE -DiskIndex $diskIdx; if(-not $row) { Log 'HDS_WIPE_DISK_NOT_FOUND_IN_LIST' @{ disk = $diskIdx }; continue }
            $rowCheck = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condCheckbox)
            if($rowCheck) { if(HDS_ToggleCheckbox $rowCheck 'On') { $hits.Add($diskIdx)|Out-Null; Log 'HDS_WIPE_CHECKED' @{ disk = $diskIdx } } }
        }
        
        if($hits.Count -eq 0) { Log 'HDS_WIPE_NO_MATCHES' @{}; return @() }
        
        $okSel = HDS_FindChildByCaption $selectHwnd 'OK'; if($okSel -eq [IntPtr]::Zero) { return @() }
        $snapSel = HDS_SnapshotTopLevel
        [void](HDS_ClickCenter $okSel $selectHwnd 'OK'); [void](HDS_WaitDialogClosed $selectHwnd 2000)
        
        # Clean Popups
        HDS_DismissPopupsSince -Snapshot $snapSel -TimeoutMs 2000 -PreferredCaptions @('Yes','OK') -PreferredIds @($script:HDS_IDYES, $script:HDS_IDOK)
        
        $surf = HDS_WaitSurfaceConfigWindow 4000; if(-not $surf) { return @() }
        $surfHwnd = $surf.Hwnd; HDS_FocusWindow $surfHwnd
        
        # SET WRITE TEST
        $comboHwnd = HDS_GetTestTypeComboSurf $surfHwnd
        if($comboHwnd -ne [IntPtr]::Zero) {
            [void](HDS_ClickCenter $comboHwnd $surfHwnd 'Test type combo')
            Start-Sleep -Milliseconds 120
            [System.Windows.Forms.SendKeys]::SendWait('w')
            Start-Sleep -Milliseconds 150
        }
        
        $btnStartHwnd = HDS_FindChildCaptionLike $surfHwnd 'start'; if($btnStartHwnd -eq [IntPtr]::Zero) { return @() }
        $snapStart = HDS_SnapshotTopLevel
        [void](HDS_ClickCenter $btnStartHwnd $surfHwnd 'Start test')
        
        # Final cleanup using Snapshot
        HDS_DismissPopupsSince -Snapshot $snapStart -TimeoutMs 8000 -PreferredCaptions @('Yes','OK') -PreferredIds @($script:HDS_IDYES, $script:HDS_IDOK)
        
        Log 'HDS_WIPE_LAUNCHED' @{ count = $hits.Count }
        return ,($hits.ToArray())
    } finally { $script:IsBusy = $false }
}

# ==========================================================
# SECTION 9: INITIALIZATION
# ==========================================================

function Initialize-HdsControl {
    Write-Host "[HDS_CONTROL] Initializing..." -ForegroundColor Yellow
    if(-not (Test-Path $script:HDSExePath)) {
        Write-Host "[HDS_CONTROL] WARNING: HDS exe not found at: $script:HDSExePath" -ForegroundColor Red
    } else { Write-Host "[HDS_CONTROL] HDS exe found." -ForegroundColor Green }
    $status = Get-HDSStatus
    Write-Host "[HDS_CONTROL] Current status: $status" -ForegroundColor $(if($status -eq 'Ready'){'Green'}else{'Yellow'})
    Write-Host "[HDS_CONTROL] Initialization complete." -ForegroundColor Green
    Log 'HDS_CONTROL_INIT' @{ status = $status; path = $script:HDSExePath }
}

Write-Host "[HDS_CONTROL] Module loaded." -ForegroundColor DarkGray
