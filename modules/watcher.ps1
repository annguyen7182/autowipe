# ==========================================================
# AUTOWIPE v4.5.1 (STABLE) - WATCHER MODULE
# ==========================================================
# Purpose: Surface test observer providing:
#   - Baseline building (Port -> Disk -> Serial mapping)
#   - HDS XML parsing
#   - Surface test window tracking
#   - Handle binding (window -> drive mapping)
#   - Verdict logic (PASS/FAILED/CHECK via LEN)
#   - Report indexing
#   - Main evaluation loop (Evaluate-And-Render)
#   - Timestamp tracking for Batch Automation
#
# Dependencies: CORE.ps1 (for Log, CSV, normalization)
# Used by: AUTOMATION.ps1, GUI.ps1
# ==========================================================

# Verify core is loaded
if(-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    throw "WATCHER requires CORE module. Load core.ps1 first."
}

# ==========================================================
# SECTION 1: WATCHER STATE
# ==========================================================

# Baseline data (port -> disk mapping)
$script:refPorts        = @{}   # PortID -> Port# (from CSV)
$script:BaselineByPort  = @{}   # Port -> @{DiskIndex; SerialRaw; SerialNorm; HealthPct}
$script:SerialToPort    = @{}   # SerialNorm -> Port
$script:DiskToPort      = @{}   # DiskIndex -> Port
$script:HdsDiskMap      = @{}   # DiskIndex -> @{DiskIndex; SerialRaw; SerialNorm; HealthPct}
$script:LastSerialByPort = @{}  # Port -> last seen SerialNorm (for swap detection)

# Surface test tracking
$script:HandleBind      = @{}   # HandleHex -> @{SerialNorm; SerialRaw; Port; DiskIndex; BoundAt; Source}
$script:Sessions        = @{}   # "port|serialNorm" -> Session state

# Report indexing
$script:ReportIndex = @{
    Files         = @()       # Array of: @{Name; Full; LastWrite; NormName}
    NextRefreshAt = (Get-Date)
    Path          = ''
    Recurse       = $false
    Patterns      = @()
}
$script:ForceReportReindexNext = $false

# Saved serials tracking (for Auto-Save-Passed)
$script:AutoPassedSaved = @{}   # SerialNorm -> [DateTime] last saved

# Shared state for GUI/Automation
$script:LastWinMap = @{}
$script:LastActiveForPort = @{}

# ==========================================================
# SECTION 2: PORT REFERENCE
# ==========================================================

function Load-RefPorts {
    $script:refPorts.Clear()
    if(Test-Path $script:ReferenceFile) {
        Import-Csv $script:ReferenceFile -Header PortNumber,PortID | ForEach-Object {
            if($_.PortNumber -match '(\d+)') { 
                $script:refPorts[$_.PortID] = [int]$matches[1] 
            }
        }
    }
    Log 'REFPORTS_LOAD' @{ count = $script:refPorts.Count }
}

# ==========================================================
# SECTION 3: HDS XML PARSING
# ==========================================================

function Get-HdsXmlMap {
    param([string]$Path = $script:HdsXmlPath)
    
    $map = @{}
    if(-not (Test-Path -LiteralPath $Path)) {
        Log 'HDSXML_MISSING' @{ path = $Path }
        return $map
    }
    
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -ErrorAction Stop
    } catch {
        Log 'HDSXML_ERR' @{ path = $Path; err = $_.Exception.Message }
        return $map
    }
    
    $root = $xml.Hard_Disk_Sentinel
    if(-not $root) {
        Log 'HDSXML_BADROOT' @{ path = $Path }
        return $map
    }
    
    foreach($node in $root.ChildNodes) {
        if($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        if(-not $node.Name.StartsWith('Physical_Disk_Information_Disk_')) { continue }
        
        $sum = $node.Hard_Disk_Summary
        if(-not $sum) { continue }
        
        $diskStr = [string]$sum.Hard_Disk_Number
        $diskIdx = 0
        if(-not [int]::TryParse($diskStr, [ref]$diskIdx)) { continue }
        
        $serialRaw = [string]$sum.Hard_Disk_Serial_Number
        if($serialRaw -eq '(pending XML)') { $serialRaw = '' }
        $serialNorm = Normalize-Serial $serialRaw
        
        $hp = $null
        $healthRaw = [string]$sum.Health
        if($healthRaw -match '(\d+)\s*%') { $hp = [int]$matches[1] }
        
        $map[$diskIdx] = @{
            DiskIndex  = $diskIdx
            SerialRaw  = $serialRaw
            SerialNorm = $serialNorm
            HealthPct  = $hp
        }
    }
    
    Log 'HDSXML_OK' @{ path = $Path; count = $map.Count }
    return $map
}

# ==========================================================
# SECTION 4: BASELINE BUILDING
# ==========================================================

function Build-Baseline {
    $script:BaselineByPort.Clear()
    $script:SerialToPort.Clear()
    $script:DiskToPort.Clear()
    
    $drives = Get-CimInstance Win32_DiskDrive
    foreach($kv in $script:refPorts.GetEnumerator()) {
        $portID = $kv.Key
        $portNo = [int]$kv.Value
        $diskIndex = $null
        
        $drive = $drives | Where-Object { 
            $_.PNPDeviceID -like ("*" + $portID + "*") 
        } | Select-Object -First 1
        
        if($drive) { $diskIndex = [int]$drive.Index }
        
        $script:BaselineByPort[$portNo] = @{
            DiskIndex  = $diskIndex
            SerialRaw  = ''
            SerialNorm = ''
            HealthPct  = $null
        }
        
        if($diskIndex -ne $null) { 
            $script:DiskToPort[$diskIndex] = $portNo 
        }
    }
    
    Log 'BASELINE_MAP' @{ ports = $script:BaselineByPort.Count }
}

function Update-BaselineFromHds {
    $script:SerialToPort.Clear()
    foreach($port in $script:BaselineByPort.Keys) {
        $base = $script:BaselineByPort[$port]
        $idx  = $base.DiskIndex
        $serialRaw = ''
        $serialNorm = ''
        $hp = $null
        
        if($idx -ne $null -and $script:HdsDiskMap.ContainsKey($idx)) {
            $entry = $script:HdsDiskMap[$idx]
            $serialRaw  = ($entry.SerialRaw -as [string])
            if($serialRaw -eq '(pending XML)') { $serialRaw = '' }
            $serialNorm = Normalize-Serial $serialRaw
            $hp         = $entry.HealthPct
        }
        
        $base.SerialRaw  = $serialRaw
        $base.SerialNorm = $serialNorm
        $base.HealthPct  = $hp
        
        if($serialNorm) { $script:SerialToPort[$serialNorm] = $port }
    }
}

# ==========================================================
# SECTION 5: SESSION MANAGEMENT (UPDATED FOR v4.1)
# ==========================================================

function Get-Session {
    param(
        [int]$port,
        [string]$snNorm
    )
    
    if(-not $snNorm) { return $null }
    $key = Key-PortSerial $port $snNorm
    
    if(-not $script:Sessions.ContainsKey($key)) {
        $script:Sessions[$key] = @{
            Verdict           = ''
            Handle            = [IntPtr]::Zero
            Committed         = $false
            RichChild         = [IntPtr]::Zero
            OwnerHandleHex    = ''
            PreFailStreak     = 0
            FirstSeen         = (Get-Date)
            LastSeen          = (Get-Date)
            AutoWipeStarted   = $false
            AutoWipeCompleted = $false
            AutoWipeFailed    = $false
            AutoWipeFailedAt  = $null
            AutoSaved         = $false
            
            # v4.1: New Timestamp Tracking Fields
            BecameIdleAt      = $null    # When drive got disk + serial + HP
            GotReportAt       = $null    # When report first appeared
            GotPassVerdictAt  = $null    # When verdict became PASS
            PassReportSaved   = $false   # Already saved final PASS report?
        }
    } else {
        $script:Sessions[$key].LastSeen = (Get-Date)
    }
    
    $script:Sessions[$key]
}

# ==========================================================
# SECTION 6: SURFACE TEST WINDOW DISCOVERY
# ==========================================================

function Get-VisibleWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [Win32+EnumWindowsProc]{ 
        param([IntPtr]$h, [IntPtr]$l)
        if([Win32]::IsWindowVisible($h)) {
            $title = [Win32]::GetWindowText($h)
            if(![string]::IsNullOrWhiteSpace($title)) {
                $class = [Win32]::GetClassName($h)
                $list.Add([pscustomobject]@{ 
                    Handle = $h
                    Title  = $title
                    Class  = $class 
                })
            }
        }
        $true
    }
    [Win32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $list
}

function Get-SurfaceTestWindows {
    Get-VisibleWindows | Where-Object { 
        $t = $_.Title.ToLower()
        $t.Contains('surface') -and $t.Contains('test') 
    }
}

function Parse-Title {
    param([string]$Title)
    
    $progressText = ''
    $progressVal = $null
    $disk = $null
    
    # Extract progress percentage
    $m = [regex]::Match($Title, '^\s*(\d{1,3}(?:\.\d+)?)\s*%\s*-\s*')
    if($m.Success) { 
        $progressVal = [double]$m.Groups[1].Value
        if($progressVal -gt 100) { $progressVal = 100 }
        $progressText = ('{0:N2}%' -f $progressVal)
    }
    
    # Extract disk index
    $md = [regex]::Match($Title, '(?i)\bDisk:\s*(\d+)')
    if($md.Success) { 
        $disk = [int]$md.Groups[1].Value 
    }
    
    [pscustomobject]@{ 
        ProgressText = $progressText
        ProgressVal  = $progressVal
        Disk         = $disk 
    }
}

function Resolve-RealForm {
    param([IntPtr]$hApp)
    
    if($hApp -eq [IntPtr]::Zero) { return $hApp }
    
    $cls = [Win32]::GetClassName($hApp)
    $r = New-Object Win32+RECT
    [void][Win32]::GetWindowRect($hApp, [ref]$r)
    
    $w = [Math]::Max(0, $r.Right - $r.Left)
    $h = [Math]::Max(0, $r.Bottom - $r.Top)
    $needHop = ($cls -eq 'TApplication') -or ($w -eq 0 -and $h -eq 0)
    
    if(-not $needHop) { return $hApp }
    
    $cands = New-Object System.Collections.Generic.List[object]
    $cb = [Win32+EnumWindowsProc]{ 
        param([IntPtr]$h, [IntPtr]$owner)
        try {
            if([Win32]::IsWindowVisible($h)) {
                $own = [Win32]::GetWindow($h, [Win32]::GW_OWNER)
                if($own -eq $owner) {
                    $rr = New-Object Win32+RECT
                    if([Win32]::GetWindowRect($h, [ref]$rr)) {
                        $ww = [Math]::Max(0, $rr.Right - $rr.Left)
                        $hh = [Math]::Max(0, $rr.Bottom - $rr.Top)
                        $cands.Add([pscustomobject]@{ 
                            Handle = $h
                            Area   = ($ww * $hh) 
                        })
                    }
                }
            }
        } catch {}
        $true
    }
    [Win32]::EnumWindows($cb, $hApp) | Out-Null
    
    if($cands.Count -gt 0) { 
        return ($cands | Sort-Object Area -Descending | Select-Object -First 1).Handle 
    }
    $hApp
}

function Get-CurrentSurfaceWindows {
    $wins = Get-SurfaceTestWindows
    $map = @{}
    
    foreach($w in $wins) {
        $p = Parse-Title $w.Title
        $resolved = Resolve-RealForm $w.Handle
        $handleHex = ('0x{0:X}' -f $w.Handle.ToInt64())
        
        $map[$handleHex] = @{
            TitleHandle  = $w.Handle
            HandlePtr    = $resolved
            Title        = $w.Title
            ProgressText = $p.ProgressText
            ProgressVal  = $p.ProgressVal
            Disk         = $p.Disk
        }
    }
    $map
}

# ==========================================================
# SECTION 7: RICH TEXT LENGTH (for verdict logic)
# ==========================================================

function Find-BestTextChild {
    param([IntPtr]$parent)
    
    $script:__best = @{ H = [IntPtr]::Zero; Len = -1 }
    $preferred = '(?i)\b(TRICHEDIT|RICHEDIT50W|RICHEDIT20W|RICHEDIT20A|RICHEDIT|TMEMO|TRICHVIEW|TCUSTOMRICHEDIT|EDIT|TLISTBOX|TLISTVIEW)\b'
    
    $cb = [Win32+EnumWindowsProc]{ 
        param([IntPtr]$h, [IntPtr]$l)
        try {
            $cls = [Win32]::GetClassName($h)
            if($cls -match $preferred) {
                $len = [Win32]::SendMessageW($h, [Win32]::WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
                if($len -gt $script:__best.Len) { 
                    $script:__best.H = $h
                    $script:__best.Len = $len 
                }
            }
        } catch {}
        $true
    }
    [Win32]::EnumChildWindows($parent, $cb, [IntPtr]::Zero) | Out-Null
    
    if($script:__best.Len -lt 0) {
        $script:__best = @{ H = [IntPtr]::Zero; Len = -1 }
        $cb2 = [Win32+EnumWindowsProc]{ 
            param([IntPtr]$h, [IntPtr]$l)
            try {
                $len = [Win32]::SendMessageW($h, [Win32]::WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
                if($len -gt $script:__best.Len) { 
                    $script:__best.H = $h
                    $script:__best.Len = $len 
                }
            } catch {}
            $true
        }
        [Win32]::EnumChildWindows($parent, $cb2, [IntPtr]::Zero) | Out-Null
    }
    
    [pscustomobject]@{ 
        Handle = $script:__best.H
        Len    = $script:__best.Len 
    }
}

function Get-RichTextLength {
    param(
        [IntPtr]$parent,
        [ref]$richChildHandle
    )
    
    if($richChildHandle.Value -eq [IntPtr]::Zero) {
        $best = Find-BestTextChild $parent
        $richChildHandle.Value = $best.Handle
        return $best.Len
    }
    
    $len = [Win32]::SendMessageW($richChildHandle.Value, [Win32]::WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
    if($len -lt 0) { 
        $best = Find-BestTextChild $parent
        $richChildHandle.Value = $best.Handle
        $len = $best.Len 
    }
    $len
}

# ==========================================================
# SECTION 8: REPORT INDEXING
# ==========================================================

function Build-ReportIndex {
    param([bool]$force)
    
    try {
        $path = $script:DEFAULTS.ReportFolder
        if([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            $script:ReportIndex.Files = @()
            $script:ReportIndex.NextRefreshAt = (Get-Date).AddSeconds([double][Math]::Max(5, $script:DEFAULTS.ReportReindexSec))
            if([string]::IsNullOrWhiteSpace($path)) { 
                Log 'REPORT_SKIP' @{ reason = 'path_empty' } 
            } else { 
                Log 'REPORT_SKIP' @{ reason = 'path_missing'; path = $path } 
            }
            return
        }
        
        $now = Get-Date
        if(-not $force) {
            $ttl = [double]$script:DEFAULTS.ReportReindexSec
            if($ttl -gt 0 -and $now -lt $script:ReportIndex.NextRefreshAt) { return }
        }
        
        $files = @()
        $recurse = [bool]$script:DEFAULTS.ReportRecurse
        foreach($pat in $script:DEFAULTS.ReportPatterns) {
            try {
                $files += Get-ChildItem -LiteralPath $path -File -Recurse:$recurse -Filter $pat -ErrorAction SilentlyContinue
            } catch {}
        }
        
        if($files) { 
            $files = $files | Sort-Object FullName -Unique 
        } else { 
            $files = @() 
        }
        
        $list = New-Object System.Collections.Generic.List[object]
        foreach($f in $files) {
            $list.Add([pscustomobject]@{
                Name      = $f.Name
                Full      = $f.FullName
                LastWrite = $f.LastWriteTime
                NormName  = Normalize-Name $f.Name
            })
        }
        
        $script:ReportIndex.Files = $list
        $script:ReportIndex.Path = $path
        $script:ReportIndex.Recurse = $recurse
        $script:ReportIndex.Patterns = $script:DEFAULTS.ReportPatterns
        $script:ReportIndex.NextRefreshAt = $now.AddSeconds([double][Math]::Max(0, $script:DEFAULTS.ReportReindexSec))
        
        Log 'REPORT_INDEX_OK' @{ 
            path    = $path
            files   = $list.Count
            recurse = ([int]$recurse)
            ttl     = $script:DEFAULTS.ReportReindexSec
        }
    } catch {
        Log 'REPORT_INDEX_FAIL' @{ err = $_.Exception.Message }
    }
}

function Test-ReportPresent {
    param([string]$serialNorm)
    
    if([string]::IsNullOrWhiteSpace($serialNorm)) { return $false }
    foreach($r in $script:ReportIndex.Files) {
        if($r.NormName.Contains($serialNorm)) { return $true }
    }
    $false
}

# ==========================================================
# SECTION 9: DRIVE SWAP DETECTION
# ==========================================================

function Close-Window-Force {
    param([IntPtr]$Handle)
    if($Handle -eq [IntPtr]::Zero) { return }
    try {
        $procId = 0
        [HDSNative.U32]::GetWindowThreadProcessId($Handle, [ref]$procId)
        if($procId -gt 0) {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            Log 'FORCE_KILL_WINDOW' @{ handle=('0x{0:X}' -f $Handle.ToInt64()); pid=$procId }
        }
    } catch {
        Log 'FORCE_KILL_FAIL' @{ err=$_.Exception.Message }
    }
}

function Reset-PortForNewSerial {
    param(
        [int]$Port,
        [string]$OldSerialNorm,
        [string]$NewSerialNorm
    )
    
    $oldNorm = Normalize-Serial $OldSerialNorm
    $newNorm = Normalize-Serial $NewSerialNorm
    
    Log 'PORT_SERIAL_SWAP_DETECTED' @{ 
        port = $Port
        old  = $oldNorm
        new  = $newNorm
    }
    
    # Close windows using FORCE kill
    $liveWindows = Get-CurrentSurfaceWindows
    $closedCount = 0
    
    foreach($hk in @($script:HandleBind.Keys)) {
        $b = $script:HandleBind[$hk]
        if($b.Port -eq $Port) {
            if($liveWindows.ContainsKey($hk)) {
                $hw = $liveWindows[$hk].HandlePtr
                if($hw -eq [IntPtr]::Zero) { $hw = $liveWindows[$hk].TitleHandle }
                if($hw -ne [IntPtr]::Zero) {
                    Close-Window-Force -Handle $hw
                    $closedCount++
                    Log 'SWAP_CLOSE_WINDOW_KILL' @{ port=$Port; handle=$hk; serial=$b.SerialNorm }
                }
            }
        }
    }
    
    # Remove bindings/sessions/CSV
    foreach($hk in @($script:HandleBind.Keys)) {
        $b = $script:HandleBind[$hk]
        if($b.Port -eq $Port) { $script:HandleBind.Remove($hk) | Out-Null }
    }
    foreach($sk in @($script:Sessions.Keys)) {
        if($sk -match "^$Port\|") { $script:Sessions.Remove($sk) | Out-Null }
    }
    foreach($pk in @($script:ProgressTable.Keys)) {
        $v = $script:ProgressTable[$pk]
        if($v.Port -eq $Port) { $script:ProgressTable.Remove($pk) | Out-Null }
    }
    
    $script:ForceReportReindexNext = $true
    Log 'PORT_SERIAL_SWAP_COMPLETE' @{ port=$Port; old=$oldNorm; new=$newNorm; windowsClosed=$closedCount }
}

# ==========================================================
# SECTION 10: MAIN EVALUATION (Evaluate-And-Render)
# ==========================================================

function Evaluate-And-Render {
    if($script:IsBusy) { 
        Log 'BUSY_SKIP' @{ where = 'Evaluate-And-Render' }
        return 
    }
    
    Ensure-ProgressCsv
    Load-ProgressCsv
    
    # Refresh baseline
    Build-Baseline
    $script:HdsDiskMap = Get-HdsXmlMap
    Update-BaselineFromHds
    
    # Clean up empty ports (Automation & Timestamps)
    foreach($port in $script:BaselineByPort.Keys){
        $base = $script:BaselineByPort[$port]
        # If port is empty (no disk or no serial), clear session flags and timestamps
        if($base.DiskIndex -eq $null -or [string]::IsNullOrWhiteSpace($base.SerialNorm)){
            foreach($sk in @($script:Sessions.Keys)){
                if($sk -match "^$port\|"){
                    $sess = $script:Sessions[$sk]
                    
                    # Reset automation flags if they were set
                    if($sess.AutoWipeStarted -or $sess.AutoWipeCompleted -or $sess.AutoSaved){
                        $sess.AutoWipeStarted = $false
                        $sess.AutoWipeCompleted = $false
                        $sess.AutoSaved = $false
                    }
                    
                    # Reset timestamps if drive is gone
                    $sess.BecameIdleAt = $null
                    $sess.GotReportAt = $null
                    $sess.GotPassVerdictAt = $null
                    $sess.PassReportSaved = $false
                }
            }
        }
        else {
            # Drive is present - Check for IDLE state and set timestamp
            # Idle = has DiskIndex + Serial + Health
            if($base.DiskIndex -ne $null -and $base.SerialNorm -and $base.HealthPct -ne $null) {
                $sess = Get-Session $port $base.SerialNorm
                if(-not $sess.BecameIdleAt) {
                    $sess.BecameIdleAt = Get-Date
                    Log 'DRIVE_IDLE_DETECTED' @{ port=$port; serial=$base.SerialNorm }
                }
                
                # Check for REPORT and set timestamp
                if(Test-ReportPresent $base.SerialNorm) {
                    if(-not $sess.GotReportAt) {
                        $sess.GotReportAt = Get-Date
                        Log 'DRIVE_REPORT_DETECTED' @{ port=$port; serial=$base.SerialNorm }
                    }
                }
            }
        }
    }

    # Build report index if needed
    if($script:ForceReportReindexNext) {
        Build-ReportIndex -force:$true
        $script:ForceReportReindexNext = $false
    } else {
        Build-ReportIndex -force:$false
    }
    
    $winMap = Get-CurrentSurfaceWindows
    $liveHandles = @($winMap.Keys)
    
    # Detect drive swaps
    foreach($port in $script:BaselineByPort.Keys) {
        $base = $script:BaselineByPort[$port]
        $newNorm = $base.SerialNorm
        $oldNorm = if($script:LastSerialByPort.ContainsKey($port)) { $script:LastSerialByPort[$port] } else { '' }
        
        if($oldNorm -and $newNorm -and $newNorm -ne $oldNorm) {
            Reset-PortForNewSerial -Port $port -OldSerialNorm $oldNorm -NewSerialNorm $newNorm
        } elseif(-not $oldNorm -and $newNorm) {
            Reset-PortForNewSerial -Port $port -OldSerialNorm '' -NewSerialNorm $newNorm
        }
        $script:LastSerialByPort[$port] = $newNorm
    }
    
    # Garbage collect dead handles
    foreach($h in @($script:HandleBind.Keys)) {
        if($liveHandles -notcontains $h) {
            $null = $script:HandleBind.Remove($h)
            Log 'BIND_GC' @{ handle = $h }
        }
    }
    
    # Bind new surface windows
    foreach($h in $liveHandles) {
        if($script:HandleBind.ContainsKey($h)) { continue }
        $info = $winMap[$h]
        if($info.Disk -eq $null) { continue }
        
        $idx = [int]$info.Disk
        $port = $null
        if($script:DiskToPort.ContainsKey($idx)) { $port = [int]$script:DiskToPort[$idx] }
        if(-not $port) { continue }
        
        $base = if($script:BaselineByPort.ContainsKey($port)) { $script:BaselineByPort[$port] } else { $null }
        $serialRaw = if($base) { $base.SerialRaw } else { '' }
        $serialNorm = if($base) { $base.SerialNorm } else { '' }
        
        # Fallback to XML map if baseline empty
        if([string]::IsNullOrWhiteSpace($serialNorm) -and $script:HdsDiskMap.ContainsKey($idx)) {
            $serialRaw = ($script:HdsDiskMap[$idx].SerialRaw -as [string])
            if($serialRaw -eq '(pending XML)') { $serialRaw = '' }
            $serialNorm = Normalize-Serial $serialRaw
        }
        
        if([string]::IsNullOrWhiteSpace($serialNorm)) { continue }
        
        Purge-SerialOnOtherPorts -currentPort $port -serialNorm $serialNorm
        $script:HandleBind[$h] = @{
            SerialNorm = $serialNorm; SerialRaw = $serialRaw; Port = [int]$port
            DiskIndex = $idx; BoundAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Source = 'HDSXML'
        }
        Log 'BIND_OK' @{ handle = $h; port = $port; serial = $serialNorm; disk = $idx }
    }
    
    # Verdict Logic
    $passLenMax = [int]$script:DEFAULTS.PassLenMax
    if(Get-Command 'Get-PassLenMax' -ErrorAction SilentlyContinue) { $passLenMax = Get-PassLenMax }
    $failLenMin = [int]$script:DEFAULTS.FailLenMin
    if(Get-Command 'Get-FailLenMin' -ErrorAction SilentlyContinue) { $failLenMin = Get-FailLenMin }
    if($failLenMin -lt ($passLenMax + 50)) { $failLenMin = $passLenMax + 50 }
    
    foreach($h in $script:HandleBind.Keys) {
        if(-not $winMap.ContainsKey($h)) { continue }
        $bind = $script:HandleBind[$h]
        $info = $winMap[$h]
        $port = [int]$bind.Port
        $sn = $bind.SerialNorm
        $sr = $bind.SerialRaw
        
        $sess = Get-Session $port $sn
        if(-not $sess) { continue }
        $sess.Handle = $winMap[$h].HandlePtr
        
        if($sess.OwnerHandleHex -ne $h) {
            $sess.OwnerHandleHex = $h
            $sess.Committed = $false
            $sess.RichChild = [IntPtr]::Zero
            $sess.PreFailStreak = 0
            Clear-Record -Port $port -SerialNorm $sn
        }
        
        if($sess.Committed) { continue }
        
        $lenNow = Get-RichTextLength -parent $sess.Handle -richChildHandle ([ref]$sess.RichChild)
        if($script:DEFAULTS.DebugLenLog) {
            Log 'LEN' @{ port = $port; serial = $sn; len = $lenNow; pct = $info.ProgressText; handle = $h }
        }
        
        if(($info.ProgressVal -ne $null) -and ($info.ProgressVal -lt 100)) {
            if($lenNow -gt $failLenMin) {
                $sess.PreFailStreak++
                if($sess.PreFailStreak -ge 2) {
                    Set-Record -Port $port -SerialRaw $sr -SerialNorm $sn -Verdict 'FAILED' -ProgressText $info.ProgressText
                    $sess.Verdict = 'FAILED'; $sess.Committed = $true
                } else {
                    Set-Record -Port $port -SerialRaw $sr -SerialNorm $sn -Verdict 'CHECK' -ProgressText $info.ProgressText
                    $sess.Verdict = 'CHECK'
                }
            } elseif($lenNow -ge $passLenMax) {
                $sess.PreFailStreak = 0
                Set-Record -Port $port -SerialRaw $sr -SerialNorm $sn -Verdict 'CHECK' -ProgressText $info.ProgressText
                $sess.Verdict = 'CHECK'
            } else {
                $sess.PreFailStreak = 0
                Set-Record -Port $port -SerialRaw $sr -SerialNorm $sn -Verdict $sess.Verdict -ProgressText $info.ProgressText
            }
        }
        elseif(($info.ProgressVal -ne $null) -and ($info.ProgressVal -ge 100)) {
            $sess.PreFailStreak = 0
            if($lenNow -lt $passLenMax) {
                Set-Record -Port $port -SerialRaw $sr -SerialNorm $sn -Verdict 'PASS' -ProgressText '100.00%'
                $sess.Verdict = 'PASS'
                $sess.Committed = $true
                
                # Timestamp PASS verdict
                if(-not $sess.GotPassVerdictAt) {
                    $sess.GotPassVerdictAt = Get-Date
                    Log 'DRIVE_PASS_DETECTED' @{ port=$port; serial=$sn }
                }
                
            } else {
                Set-Record -Port $port -SerialRaw $sr -SerialNorm $sn -Verdict 'CHECK' -ProgressText '100.00%'
                $sess.Verdict = 'CHECK'
            }
        }
    }
    
    # Update shared state
    $activeForPort = @{}
    foreach($h in $script:HandleBind.Keys) {
        if(-not $winMap.ContainsKey($h)) { continue }
        $p = [int]$script:HandleBind[$h].Port
        if(-not $activeForPort.ContainsKey($p)) { 
            $activeForPort[$p] = $h 
        } else {
            $cur = $activeForPort[$p]
            $a = $winMap[$h].ProgressVal
            $c = $winMap[$cur].ProgressVal
            if(($a -as [double]) -gt ($c -as [double])) { $activeForPort[$p] = $h }
        }
    }
    $script:LastWinMap = $winMap
    $script:LastActiveForPort = $activeForPort

    # Mark auto-wiped sessions as completed
    foreach($sk in $script:Sessions.Keys) {
      $sess = $script:Sessions[$sk]
      if($sess.Verdict -eq 'PASS' -and $sess.AutoWipeStarted -and -not $sess.AutoWipeCompleted) {
        $sess.AutoWipeCompleted = $true
        Log 'AUTO_WIPE_COMPLETED' @{ key = $sk; verdict = 'PASS' }
      }
    }

    Write-ProgressCsv
    
    if(Get-Command 'Update-GridFromWatcherState' -ErrorAction SilentlyContinue) {
        Update-GridFromWatcherState
    }
}

# ==========================================================
# SECTION 11: MISC FEATURES
# ==========================================================

function Clear-Dead-Records {
    Log 'CLEAR_START' @{}
    $deadKeys = New-Object System.Collections.Generic.List[string]
    foreach($key in $script:ProgressTable.Keys) {
        $entry = $script:ProgressTable[$key]
        $port  = [int]$entry.Port
        $isLive = $false
        if($script:BaselineByPort.ContainsKey($port)) {
            $base = $script:BaselineByPort[$port]
            if($base.DiskIndex -ne $null) { $isLive = $true }
        }
        if(-not $isLive) { $deadKeys.Add($key) }
    }
    foreach($k in $deadKeys) { $script:ProgressTable.Remove($k) }
    Write-ProgressCsv
    Log 'CLEAR_DONE' @{ removed = $deadKeys.Count }
}

function Initialize-Watcher {
    Write-Host "[WATCHER] Initializing..." -ForegroundColor Yellow
    
    Load-RefPorts
    Build-Baseline
    $script:HdsDiskMap = Get-HdsXmlMap
    Update-BaselineFromHds
    Build-ReportIndex -force:$true
    
    Log 'WATCHER_INIT' @{ ports = $script:BaselineByPort.Count }
}

Write-Host "[WATCHER] Module loaded." -ForegroundColor DarkGray
