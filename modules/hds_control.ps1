# ==========================================================
# AUTOWIPE v4.5 - HDS_CONTROL MODULE (Fix: Surface Test Click)
# ==========================================================
# Purpose: Hard Disk Sentinel automation API
# ==========================================================

# Verify core is loaded
if(-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    throw "HDS_CONTROL requires CORE module. Load core.ps1 first."
}

# Load UIAutomation
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

# === SAFE WINDOW LIST ===
# Windows that HDS_SmartCleanup will NEVER close
$script:SafeWindowClasses = @(
    'TForm3',       # Main Dashboard
    'TForm1',       # Surface Test Window
    'TApplication', # Taskbar Helper
    'TPanel'        # Some status panels
)

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
# SECTION 2: STRING & WIN32 HELPERS
# ==========================================================

function HDS_Strip { param([string]$s) if(-not $s){return ""} ($s -replace '[&$]','').Trim() }
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

function HDS_GetProcess {
    Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
}

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

function HDS_FindToolbarByTitle {
    foreach($tw in (HDS_GetTopLevelVisible)) {
        $title = HDS_GetText $tw
        if(-not $title -or $title -notlike '*Hard Disk Sentinel*') { continue }
        if($title -like '*Surface Test*') { continue }
        
        $kids = HDS_GetAllDescendants $tw
        foreach($h in $kids) {
            $cls = HDS_GetClass $h
            if($cls -match '^(ToolbarWindow32|ToolBarWindow32|TToolBar.*)$') { return $h }
        }
    }
    [IntPtr]::Zero
}

function HDS_GetAllDescendants {
    param([IntPtr]$parent)
    $list = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l) $list.Add($h)|Out-Null; $true }
    [HDSNative.U32]::EnumChildWindows($parent, $cb, [IntPtr]::Zero) | Out-Null
    $list
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
    if(-not (HDS_TestWindowResponsive $hMain 800)) { return 'Hung' }
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
        Start-Process -FilePath $script:HDSExePath | Out-Null
        Start-Sleep -Milliseconds 800
        $p = HDS_GetProcess
        if(-not $p) { return $null }
    }
    $h = HDS_GetMainWindowHandle $p
    if($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 600; $h = HDS_GetMainWindowHandle $p }
    
    if($h -ne [IntPtr]::Zero) {
        if([HDSNative.U32]::IsIconic($h)) { [HDSNative.U32]::ShowWindow($h, $script:HDS_SW_RESTORE) | Out-Null; Start-Sleep -Milliseconds 120 }
        HDS_FocusWindow $h
        if(-not (HDS_TestWindowResponsive $h 1200)) { return $null }
        return [pscustomobject]@{ Proc = $p; Hwnd = $h }
    }
    $null
}

function HDS_CanProceedAuto {
    param([string]$operationTag)
    $st = Get-HDSStatus
    if($st -in @('NotRunning','Starting','Modal','Hung')) { return $false }
    if($st -eq 'Minimized') { if(-not (HDS_EnsureReady)) { return $false } }
    $true
}

# ==========================================================
# SECTION 5: BUTTON/CONTROL HELPERS
# ==========================================================

function HDS_FindButton {
    param([IntPtr]$dlg, [string[]]$preferCaptions, [int[]]$preferIds)
    $cb = [HDSNative.U32+EnumProc]{ 
        param([IntPtr]$h, [IntPtr]$l)
        $cls = HDS_GetClass $h; if($cls -notmatch 'Button') { return $true }
        $id = [HDSNative.U32]::GetDlgCtrlID($h); $cap = HDS_Strip (HDS_GetText $h)
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
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l) $txt = HDS_Strip (HDS_GetText $h); if($txt -eq $script:__wanted){$script:__found=$h; return $false} $true }
    [HDSNative.U32]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero) | Out-Null
    $script:__found
}

function HDS_FindChildCaptionLike {
    param([IntPtr]$dlg, [string]$contains)
    $script:__found=[IntPtr]::Zero; $script:__needle=$contains.ToLower()
    $cb = [HDSNative.U32+EnumProc]{ param([IntPtr]$h, [IntPtr]$l) $txt=HDS_Strip (HDS_GetText $h); if($txt -and $txt.ToLower().Contains($script:__needle)){$script:__found=$h; return $false} $true }
    [HDSNative.U32]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero) | Out-Null
    $script:__found
}

function HDS_ClickCenter {
    param([IntPtr]$btn, [IntPtr]$owner, [string]$label='Click')
    if($btn -eq [IntPtr]::Zero) { return $false }
    if($owner -ne [IntPtr]::Zero) { HDS_FocusWindow $owner }
    $rc = HDS_GetWindowRect $btn
    $cx = [int]([Math]::Max(1, ($rc.Right - $rc.Left) / 2)); $cy = [int]([Math]::Max(1, ($rc.Bottom - $rc.Top) / 2))
    $lp = HDS_MakeLParam $cx $cy
    [HDSNative.U32]::PostMessageW($btn, [uint32]$script:HDS_WM_MOUSEMOVE, [IntPtr]0, $lp) | Out-Null; Start-Sleep -Milliseconds 10
    [HDSNative.U32]::PostMessageW($btn, [uint32]$script:HDS_WM_LBUTTONDOWN, [IntPtr]$script:HDS_MK_LBUTTON, $lp) | Out-Null; Start-Sleep -Milliseconds $script:HDS_PostDelayMs
    [HDSNative.U32]::PostMessageW($btn, [uint32]$script:HDS_WM_LBUTTONUP, [IntPtr]0, $lp) | Out-Null
    Log 'HDS_CLICK' @{ label=$label }
    $true
}

function HDS_ClickToolbarClient {
    param([IntPtr]$hToolbar, [int]$x, [int]$y, [string]$tag='Toolbar')
    $lp = HDS_MakeLParam $x $y
    [HDSNative.U32]::PostMessageW($hToolbar, [uint32]$script:HDS_WM_MOUSEMOVE, [IntPtr]0, $lp) | Out-Null; Start-Sleep -Milliseconds 10
    [HDSNative.U32]::PostMessageW($hToolbar, [uint32]$script:HDS_WM_LBUTTONDOWN, [IntPtr]$script:HDS_MK_LBUTTON, $lp) | Out-Null; Start-Sleep -Milliseconds $script:HDS_PostDelayMs
    [HDSNative.U32]::PostMessageW($hToolbar, [uint32]$script:HDS_WM_LBUTTONUP, [IntPtr]0, $lp) | Out-Null
    Log 'HDS_TOOLBAR_CLICK' @{ tag=$tag }
}

# ==========================================================
# SECTION 6: POPUP HANDLING
# ==========================================================

function HDS_DismissPopupsSince {
    param(
        [hashtable]$Snapshot,
        [int]$TimeoutMs = $script:HDS_PopupSweepTimeoutMs,
        [string[]]$PreferredCaptions = @('Yes','OK','Save'),
        [int[]]$PreferredIds = @($script:HDS_IDYES, $script:HDS_IDOK)
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $quietUntil = (Get-Date).AddMilliseconds($script:HDS_QuietPeriodMs)
    
    while((Get-Date) -lt $deadline) {
        $newFound = $false
        foreach($hw in (HDS_GetTopLevelVisible)) {
            $k = "$hw"
            if($Snapshot.ContainsKey($k)) { continue }
            $Snapshot[$k] = 1; $newFound = $true
            $cls = HDS_GetClass $hw; $title = HDS_GetText $hw
            if($cls -ne '#32770' -and $cls -notmatch 'Dialog|#32770') { continue }
            
            $btn = [IntPtr]::Zero; $t1 = Get-Date
            do {
                $btn = HDS_FindButton -dlg $hw -preferCaptions $PreferredCaptions -preferIds $PreferredIds
                if($btn -ne [IntPtr]::Zero) { break }
                Start-Sleep -Milliseconds $script:HDS_ChildPollEveryMs
            } while((Get-Date) - $t1 -lt [TimeSpan]::FromMilliseconds($script:HDS_ChildPollTimeoutMs))
            
            if($btn -ne [IntPtr]::Zero) {
                [void](HDS_ClickCenter $btn $hw 'Dismiss')
                if($title -match 'Save As') { [void](HDS_WaitDialogClosed $hw 600) } else { [void](HDS_WaitDialogClosed $hw 1500) }
                Log 'HDS_POPUP_DISMISSED' @{ title=$title }
            }
        }
        if($newFound) { $quietUntil = (Get-Date).AddMilliseconds($script:HDS_QuietPeriodMs) }
        elseif((Get-Date) -ge $quietUntil) { return }
        Start-Sleep -Milliseconds 80
    }
}

# === SMART CLEANUP FUNCTION ===
function HDS_SmartCleanup {
    param([int]$TimeoutMs = 1500)
    
    $proc = HDS_GetProcess
    if(-not $proc) { return }
    $wins = HDS_GetTopWindowsOfProcess $proc.Id

    foreach ($hwnd in $wins) {
        if (-not [HDSNative.U32]::IsWindowVisible($hwnd)) { continue }

        $cls = HDS_GetClass $hwnd
        
        # SKIP if Safe (TForm3, TForm1, TApplication)
        if ($cls -in $script:SafeWindowClasses) { continue }
        
        # Otherwise, it's a target!
        $title = HDS_GetText $hwnd
        
        Log 'HDS_SMART_CLEAN_HIT' @{ title = $title; class = $cls }

        $btn = HDS_FindButton -dlg $hwnd `
            -preferCaptions @('Save','Yes','OK','Close','No') `
            -preferIds @($script:HDS_IDYES, $script:HDS_IDOK)

        if ($btn -ne [IntPtr]::Zero) {
            HDS_ClickCenter $btn $hwnd "SmartCleanup"
            Start-Sleep -Milliseconds 200
        }
    }
}

function HDS_EnsureReadyAndClearModals {
    $ready = HDS_EnsureReady
    if(-not $ready) { return $null }
    $snap = HDS_SnapshotTopLevel
    HDS_DismissPopupsSince -Snapshot $snap -TimeoutMs 1500
    $ready
}

# ==========================================================
# SECTION 7: UIAUTOMATION HELPERS
# ==========================================================

function HDS_WaitWindowByNameLike {
    param([string]$contains, [int]$timeoutMs=8000)
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    do {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach($w in $all) {
            try { if($w.Current.Name -and $w.Current.Name.ToLower().Contains($contains.ToLower())) { return $w } } catch {}
        }
        Start-Sleep -Milliseconds 120
    } until((Get-Date) -gt $deadline)
    $null
}

function HDS_WaitAuthenticList {
    param([int]$ProcId, [int]$TimeoutSec)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $pidCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcId)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Milliseconds 150
        $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
        foreach($w in $wins) {
            try { 
                $h = [IntPtr]$w.Current.NativeWindowHandle
                if($h -eq [IntPtr]::Zero) { continue }
                if($w.Current.Name -like '*Authentic Disk Report*') { return $h }
            } catch {}
        }
    } while((Get-Date) -lt $end)
    [IntPtr]::Zero
}

function HDS_ToggleCheckbox {
    param($el, [string]$state)
    try {
        $p = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if($state -eq 'On' -and $p.Current.ToggleState -ne 'On') { $p.Toggle() }
        if($state -eq 'Off' -and $p.Current.ToggleState -ne 'Off') { $p.Toggle() }
        $true
    } catch { $false }
}

function HDS_UncheckAllCheckboxes {
    param($root)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)
    $checks = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    foreach($c in $checks) { [void](HDS_ToggleCheckbox $c 'Off') }
}

function HDS_FindElementNameContainsNorm {
    param($root, $needleNorm)
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all) {
        try { 
            $nm = $el.Current.Name; if(-not $nm){continue}
            if((Normalize-Serial $nm).Contains($needleNorm)) { return $el }
        } catch {}
    }
    $null
}

function HDS_GetOSDiskSerial {
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $part = Get-CimAssociatedInstance -InputObject $c -ResultClassName Win32_DiskPartition | Select-Object -First 1
        $disk = Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_DiskDrive | Select-Object -First 1
        $sn = [string]$disk.SerialNumber
        Normalize-Serial $sn
    } catch { $null }
}

# === CRITICAL FIX: REVERTED TO ROBUST VERSION ===
function HDS_WaitSurfaceConfigWindow {
  param([int]$timeoutMs=8000)
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  do{
    foreach($hw in (HDS_GetTopLevelVisible)){
      $title = HDS_GetText $hw
      if(-not $title){ continue }
      if($title -notlike '*Surface Test*'){ continue }
      
      $btnMulti = HDS_FindChildByCaption $hw 'Multiple disk drives'
      if($btnMulti -eq [IntPtr]::Zero){
        $btnMulti = HDS_FindChildByCaption $hw 'Multiple'
      }
      if($btnMulti -ne [IntPtr]::Zero){
        return [pscustomobject]@{ Hwnd = $hw }
      }
    }
    Start-Sleep -Milliseconds 150
  } until((Get-Date) -gt $deadline)
  $null
}

function HDS_WaitDriveSelectorWindow { param([int]$t=8000)
    HDS_WaitWindowByNameLike 'Surface Test' $t 
}

function HDS_FindRowByDiskIndex {
    param($dlgAE, $DiskIndex)
    $all = $dlgAE.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all) {
        try {
            if($el.Current.Name -match "^\s*$DiskIndex\s*$") {
                $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
                $parent = $el
                for($j=0; $j -lt 5; $j++) {
                    $parent = $walker.GetParent($parent); if(-not $parent){break}
                    if($parent.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataItem) { return $parent }
                }
            }
        } catch {}
    }
    $null
}

function HDS_GetTestTypeComboSurf {
    param([IntPtr]$surfHwnd)
    $script:__combo=[IntPtr]::Zero
    $cb=[HDSNative.U32+EnumProc]{ param($h,$l) $c=HDS_GetClass $h; if($c -eq 'TComboBox'){$script:__combo=$h; return $false} $true }
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
        $tw = $ready.Hwnd; $toolbar = HDS_FindToolbarByTitle; if($toolbar -eq [IntPtr]::Zero) { return }
        HDS_FocusWindow $tw
        $snap = HDS_SnapshotTopLevel
        HDS_ClickToolbarClient -hToolbar $toolbar -x $script:HDS_RefreshX -y $script:HDS_RefreshY -tag 'Refresh'
        HDS_DismissPopupsSince -Snapshot $snap -TimeoutMs $script:HDS_PopupSweepTimeoutMs
    } finally { $script:IsBusy = $false }
}

function Run-SaveAuthentic-BySerials {
    param([string[]]$SerialsNorm)
    $ready = HDS_EnsureReadyAndClearModals; if(-not $ready) { return }
    $hdsPid = $ready.Proc.Id
    HDS_FocusWindow $ready.Hwnd
    
    $tform3 = HDS_FindTForm3Window
    if($tform3 -ne [IntPtr]::Zero) { [HDSNative.U32]::PostMessageW($tform3, [HDSNative.U32]::WM_COMMAND, [IntPtr]50, [IntPtr]::Zero) | Out-Null }
    
    $dlg = HDS_WaitAuthenticList -ProcId $hdsPid -TimeoutSec $script:HDS_WaitAuthenticSec
    if($dlg -eq [IntPtr]::Zero) { return }
    
    $dlgAE = [System.Windows.Automation.AutomationElement]::FromHandle($dlg)
    HDS_UncheckAllCheckboxes $dlgAE
    $hits = 0
    
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $condCheckbox = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox)
    
    foreach($sn in $SerialsNorm) {
        $cell = HDS_FindElementNameContainsNorm $dlgAE $sn; if(-not $cell) { continue }
        $row = $cell
        for($j=0; $j -lt 6; $j++) {
            $p = $walker.GetParent($row); if(-not $p){break}
            if($p.Current.ControlType -eq [System.Windows.Automation.ControlType]::DataItem) { $row=$p; break }
            $row=$p
        }
        $rowCheck = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condCheckbox)
        if($rowCheck) { if(HDS_ToggleCheckbox $rowCheck 'On') { $hits++ } }
    }
    
    if($hits -gt 0) {
        $ok = HDS_FindChildByCaption $dlg 'OK'
        $snap = HDS_SnapshotTopLevel
        [void](HDS_ClickCenter $ok $dlg 'OK')
        [void](HDS_WaitDialogClosed $dlg 1500)
        HDS_DismissPopupsSince -Snapshot $snap -TimeoutMs 10000
    }
}

function Run-WipeByDiskIndices {
    param(
        [int[]]$DiskIndices,
        [hashtable]$RetryAttempts,
        [hashtable]$GiveUpDisks
    )
    
    if($script:IsBusy) { return @() }
    $script:IsBusy = $true
    
    try {
        if(-not $DiskIndices -or $DiskIndices.Count -eq 0) { 
            Log 'HDS_WIPE_NO_INDICES' @{}
            return @() 
        }

        # Check for OS disk conflict (Safety)
        $osSerialNorm = HDS_GetOSDiskSerial
        
        $ready = HDS_EnsureReadyAndClearModals
        if(-not $ready) { return @() }
        $tw = $ready.Hwnd
        
        $toolbar = HDS_FindToolbarByTitle
        if($toolbar -eq [IntPtr]::Zero) {
            Log 'HDS_TOOLBAR_NOT_FOUND' @{}
            return @()
        }
        
        HDS_FocusWindow $tw
        Start-Sleep -Milliseconds 120
        Log 'HDS_WIPE_STARTING' @{ count = $DiskIndices.Count }
        
        $snapBefore = HDS_SnapshotTopLevel
        HDS_ClickToolbarClient -hToolbar $toolbar -x $script:HDS_SurfaceX -y $script:HDS_SurfaceY -tag 'Surface Test'
        
        # === CRITICAL FIX: Using the Robust Window Finder here ===
        $surf = HDS_WaitSurfaceConfigWindow 8000
        if(-not $surf) {
            Log 'HDS_SURFACE_CONFIG_NOT_FOUND' @{}
            return @()
        }
        $surfHwnd = $surf.Hwnd
        HDS_FocusWindow $surfHwnd
        
        $btnMultiHwnd = HDS_FindChildByCaption $surfHwnd 'Multiple disk drives'
        if($btnMultiHwnd -eq [IntPtr]::Zero) {
            $btnMultiHwnd = HDS_FindChildByCaption $surfHwnd 'Multiple'
        }
        if($btnMultiHwnd -eq [IntPtr]::Zero) {
            Log 'HDS_WIPE_MULTIPLE_BTN_NOT_FOUND' @{}
            return @()
        }
        
        [void](HDS_ClickCenter $btnMultiHwnd $surfHwnd 'Multiple')
        
        $selectAE = HDS_WaitDriveSelectorWindow 8000
        if(-not $selectAE) {
            Log 'HDS_WIPE_SELECTOR_NOT_FOUND' @{}
            return @()
        }
        $selectHwnd = [IntPtr]$selectAE.Current.NativeWindowHandle
        HDS_FocusWindow $selectHwnd
        
        HDS_UncheckAllCheckboxes $selectAE
        
        $hits = New-Object System.Collections.Generic.List[int]
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $condCheckbox = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox
        )
        
        foreach($diskIdx in $DiskIndices) {
            $row = HDS_FindRowByDiskIndex -dlgAE $selectAE -DiskIndex $diskIdx
            if(-not $row) { 
                Log 'HDS_WIPE_DISK_NOT_FOUND_IN_LIST' @{ disk = $diskIdx }
                continue 
            }
            
            $rowCheck = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condCheckbox)
            if($rowCheck) {
                if(HDS_ToggleCheckbox $rowCheck 'On') {
                    $hits.Add($diskIdx) | Out-Null
                    Log 'HDS_WIPE_CHECKED' @{ disk = $diskIdx }
                }
            }
        }
        
        if($hits.Count -eq 0) {
            Log 'HDS_WIPE_NO_MATCHES' @{}
            return @()
        }
        
        $okSel = HDS_FindChildByCaption $selectHwnd 'OK'
        if($okSel -eq [IntPtr]::Zero) { return @() }
        
        $snapSel = HDS_SnapshotTopLevel
        [void](HDS_ClickCenter $okSel $selectHwnd 'OK')
        [void](HDS_WaitDialogClosed $selectHwnd 2000)
        HDS_DismissPopupsSince -Snapshot $snapSel -TimeoutMs 2000 -PreferredCaptions @('Yes','OK') -PreferredIds @($script:HDS_IDYES, $script:HDS_IDOK)
        
        $surf = HDS_WaitSurfaceConfigWindow 4000
        if(-not $surf) { return @() }
        $surfHwnd = $surf.Hwnd
        HDS_FocusWindow $surfHwnd
        
        # Set Write test
        $comboHwnd = HDS_GetTestTypeComboSurf $surfHwnd
        if($comboHwnd -ne [IntPtr]::Zero) {
            [void](HDS_ClickCenter $comboHwnd $surfHwnd 'Test type combo')
            Start-Sleep -Milliseconds 120
            [System.Windows.Forms.SendKeys]::SendWait('w')
            Start-Sleep -Milliseconds 150
        }
        
        $btnStartHwnd = HDS_FindChildCaptionLike $surfHwnd 'start'
        if($btnStartHwnd -eq [IntPtr]::Zero) { return @() }
        
        $snapStart = HDS_SnapshotTopLevel
        [void](HDS_ClickCenter $btnStartHwnd $surfHwnd 'Start test')
        
        HDS_DismissPopupsSince -Snapshot $snapStart -TimeoutMs 8000 -PreferredCaptions @('Yes','OK') -PreferredIds @($script:HDS_IDYES, $script:HDS_IDOK)
        
        Log 'HDS_WIPE_LAUNCHED' @{ count = $hits.Count }
        
        return ,($hits.ToArray())
    } finally {
        $script:IsBusy = $false
    }
}

# ==========================================================
# SECTION 9: INITIALIZATION
# ==========================================================

function Initialize-HdsControl {
    Write-Host "[HDS_CONTROL] Initializing..." -ForegroundColor Yellow
    $status = Get-HDSStatus
    Write-Host "[HDS_CONTROL] Status: $status"
    Log 'HDS_CONTROL_INIT' @{ status = $status }
}

Write-Host "[HDS_CONTROL] Module loaded." -ForegroundColor DarkGray