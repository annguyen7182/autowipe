# ==========================================================
# AUTOWIPE v4.5 (STABLE) - CORE MODULE
# ==========================================================
# Purpose: Foundation layer providing:
#   - Win32 P/Invoke declarations
#   - Configuration ($DEFAULTS)
#   - Logging (console + file)
#   - String normalization
#   - CSV operations
#   - Shared utilities
#
# Dependencies: NONE (this is the foundation)
# Used by: ALL other modules
# ==========================================================

# ==========================================================
# SECTION 1: CONFIGURATION
# ==========================================================

$script:DEFAULTS = @{
    # Watcher thresholds
    PassLenMax       = 500      # at/after 100%: len < PassLenMax => PASS
    FailLenMin       = 1000     # pre-100%: len > FailLenMin => FAILED (after 2 ticks)
    DebugLenLog      = 1        # 1 = log LEN per tick; 0 = silent

    # Auto-check (watcher timing)
    AutoCheck        = 1        # 1 = enabled, 0 = disabled
    IntervalSec      = 5       # auto-check interval (seconds)

    # Auto-refresh (HDS refresh timing)
    AutoRefresh      = 0        # 1 = enabled, 0 = disabled
    AutoRefreshMin   = 60       # minutes

    # Auto-wipe (idle drive detection)
    AutoWipe         = 0        # 1 = enabled, 0 = disabled
    AutoWipeSec      = 60       # seconds

    # Auto-save (report generation)
    AutoSave         = 0        # 1 = enabled, 0 = disabled
    AutoSaveSec      = 30      # seconds (5 minutes)
    AutoSavePassed   = 0        # 1 = save PASS drives immediately, 0 = disabled

    # Report indexing
    ReportFolder     = 'C:\Users\HT Wiping RIG\Desktop\HDS Smart Logs'
    ReportRecurse    = 0        # 1 = include subfolders; 0 = this folder only
    ReportPatterns   = @('*.html','*.htm','*.pdf')
    ReportReindexSec = 60       # TTL for reindex on auto-ticks. 0 = rescan every tick.
}

# File paths (configurable per rig)
$script:ReferenceFile   = 'C:\HDMapping\Port_Reference.csv'          # Port,PortID
$script:ProgressCsvPath = 'C:\HDMapping\Port_Serial_Progress.csv'    # Port,SerialRaw,SerialNorm,Verdict,Progress
$script:LogPath         = 'C:\HDMapping\WipeWatcher.log'
$script:HdsXmlPath      = 'C:\HDMapping\HDSentinel.xml'

# UI layout constants
$script:RowHeight       = 22
$script:FormWidth       = 1000

# Global CSV state (managed by this module)
$script:ProgressTable = @{}   # Key: "port|serialNorm" -> PSCustomObject

# ==========================================================
# SECTION 2: WIN32 P/INVOKE DECLARATIONS
# ==========================================================

# ---- Basic Win32 (for watcher module) ----
if(-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Win32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int  GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int  GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int  GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    public const uint GW_OWNER = 4;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public const uint WM_GETTEXT        = 0x000D;
    public const uint WM_GETTEXTLENGTH  = 0x000E;
    public const uint WM_CLOSE          = 0x0010;

    public static string GetWindowText(IntPtr h){
        int n = GetWindowTextLengthW(h);
        if(n <= 0) return string.Empty;
        var sb = new StringBuilder(n+1);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string GetClassName(IntPtr h){
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string GetControlText(IntPtr h){
        int len = SendMessageW(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero).ToInt32();
        if(len <= 0) return string.Empty;
        var sb = new StringBuilder(len+1);
        SendMessageW(h, WM_GETTEXT, (IntPtr)sb.Capacity, sb);
        return sb.ToString();
    }
}
"@ -ErrorAction SilentlyContinue
}

# ---- HDS-specific Win32 (for HDS control module) ----
if(-not ([System.Management.Automation.PSTypeName]'HDSNative.U32').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace HDSNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public static class U32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll", SetLastError=true)] public static extern bool   EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool   EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] public static extern int    GetWindowThreadProcessId(IntPtr h, out int pid);

    [DllImport("user32.dll")] public static extern bool   IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   IsIconic(IntPtr h);

    [DllImport("user32.dll")] public static extern bool   SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   ShowWindow(IntPtr h, int nCmdShow);

    [DllImport("user32.dll")] public static extern bool   PostMessageW(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW (IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool   GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int    GetDlgCtrlID(IntPtr h);

    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(
       IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam,
       uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    public const uint WM_NULL = 0x0000;
    public const uint WM_COMMAND = 0x0111;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    public const int SW_RESTORE = 9;
    public const uint WM_MOUSEMOVE   = 0x0200;
    public const uint WM_LBUTTONDOWN = 0x0201;
    public const uint WM_LBUTTONUP   = 0x0202;
    public const uint MK_LBUTTON     = 0x0001;
  }
}
"@ -Language CSharp -ErrorAction SilentlyContinue
}

# ==========================================================
# SECTION 3: LOGGING API
# ==========================================================

function Ensure-Dir {
    param([string]$path)
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-LogLine {
    param(
        [string]$type,
        [hashtable]$kv
    )
    try {
        Ensure-Dir $script:LogPath
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $pairs = if($kv) { 
            ($kv.Keys | ForEach-Object { "$_=$($kv[$_])" }) -join " | " 
        } else { 
            "" 
        }
        $line = if($pairs) { "$ts | $type | $pairs" } else { "$ts | $type" }
        
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        
        # Auto-rotation: keep last 8000 lines if > 5MB
        $fi = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if($fi -and $fi.Length -gt 5MB) {
            $last = Get-Content -LiteralPath $script:LogPath -Tail 8000
            Set-Content -LiteralPath $script:LogPath -Value $last -Encoding UTF8
        }
    } catch {
        # Silent fail (don't crash if logging fails)
    }
}

function Log {
    param(
        [string]$type,
        [hashtable]$kv
    )
    # Console output
    $ts = (Get-Date).ToString('HH:mm:ss')
    $pairs = if($kv) { 
        ($kv.Keys | ForEach-Object { "$_=$($kv[$_])" }) -join " " 
    } else { 
        "" 
    }
    if($pairs) { 
        Write-Host "[$ts] $type $pairs" 
    } else { 
        Write-Host "[$ts] $type" 
    }
    
    # File output
    Write-LogLine $type $kv
}

# ==========================================================
# SECTION 4: STRING NORMALIZATION API
# ==========================================================

function Normalize-Serial {
    param([string]$s)
    if([string]::IsNullOrWhiteSpace($s)) { return '' }
    ($s -replace '\s','' -replace '[^0-9A-Za-z]','').ToUpper()
}

function Normalize-Name {
    param([string]$name)
    if([string]::IsNullOrWhiteSpace($name)) { return '' }
    ($name -replace '[^0-9A-Za-z]','').ToUpper()
}

function Key-PortSerial {
    param(
        [int]$Port,
        [string]$SerialNorm
    )
    "$Port|$SerialNorm"
}

# ==========================================================
# SECTION 5: CSV API
# ==========================================================

function Ensure-ProgressCsv {
    if(-not (Test-Path -LiteralPath $script:ProgressCsvPath)) {
        Ensure-Dir $script:ProgressCsvPath
        "Port,SerialRaw,SerialNorm,Verdict,Progress" | Set-Content -LiteralPath $script:ProgressCsvPath -Encoding UTF8
    }
}

function Load-ProgressCsv {
    Ensure-ProgressCsv
    $script:ProgressTable.Clear()
    
    if(Test-Path $script:ProgressCsvPath) {
        $rows = Import-Csv -LiteralPath $script:ProgressCsvPath
        foreach($row in $rows) {
            $port = ($row.Port -as [int])
            $snNorm = Normalize-Serial $row.SerialNorm
            if(-not $port) { continue }
            if(-not $snNorm) { continue }
            
            $key = Key-PortSerial $port $snNorm
            $script:ProgressTable[$key] = [pscustomobject]@{
                Port       = $port
                SerialRaw  = [string]$row.SerialRaw
                SerialNorm = $snNorm
                Verdict    = [string]$row.Verdict
                Progress   = [string]$row.Progress
            }
        }
    }
    
    Log 'CSV_LOAD' @{ Count=$script:ProgressTable.Count }
}

function Write-ProgressCsv {
    Ensure-ProgressCsv
    
    $lines = @('Port,SerialRaw,SerialNorm,Verdict,Progress')
    foreach($k in ($script:ProgressTable.Keys | Sort-Object)) {
        $v = $script:ProgressTable[$k]
        $line = "{0},{1},{2},{3},{4}" -f `
            $v.Port, `
            ($v.SerialRaw   -replace ',',' '), `
            $v.SerialNorm, `
            ($v.Verdict     -replace ',',' '), `
            ($v.Progress    -replace ',',' ')
        $lines += $line
    }
    
    # Safe write with retries
    $tmp = "$script:ProgressCsvPath.tmp"
    $attempts = 0
    do {
        try {
            $lines | Set-Content -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $script:ProgressCsvPath -Force
            return
        } catch { 
            Start-Sleep -Milliseconds 150 
        }
        $attempts++
    } while($attempts -lt 5)
    
    # Fallback: direct write
    try { 
        $lines | Set-Content -LiteralPath $script:ProgressCsvPath -Encoding UTF8 
    } catch {}
}

function Set-Record {
    param(
        [int]$Port,
        [string]$SerialRaw,
        [string]$SerialNorm,
        [string]$Verdict,
        [string]$ProgressText
    )
    
    if(-not $SerialNorm) { return }
    
    $key = Key-PortSerial $Port $SerialNorm
    
    if(-not $script:ProgressTable.ContainsKey($key)) {
        $script:ProgressTable[$key] = [pscustomobject]@{
            Port       = $Port
            SerialRaw  = $SerialRaw
            SerialNorm = $SerialNorm
            Verdict    = ''
            Progress   = ''
        }
    } else {
        $script:ProgressTable[$key].SerialRaw = $SerialRaw
    }
    
    if($Verdict      -ne $null) { $script:ProgressTable[$key].Verdict  = $Verdict }
    if($ProgressText -ne $null) { $script:ProgressTable[$key].Progress = $ProgressText }
}

function Clear-Record {
    param(
        [int]$Port,
        [string]$SerialNorm
    )
    
    if(-not $SerialNorm) { return }
    
    $key = Key-PortSerial $Port $SerialNorm
    if($script:ProgressTable.ContainsKey($key)) {
        $script:ProgressTable[$key].Verdict  = ''
        $script:ProgressTable[$key].Progress = ''
    }
}

function Purge-SerialOnOtherPorts {
    param(
        [int]$currentPort,
        [string]$serialNorm
    )
    
    foreach($k in @($script:ProgressTable.Keys)) {
        $v = $script:ProgressTable[$k]
        if($v.SerialNorm -eq $serialNorm -and $v.Port -ne $currentPort) {
            $null = $script:ProgressTable.Remove($k)
            Log 'SERIAL_MOVED' @{ 
                serial  = $serialNorm
                oldPort = $v.Port
                newPort = $currentPort
            }
        }
    }
}

# ==========================================================
# SECTION 6: INITIALIZATION
# ==========================================================

function Initialize-Core {
    Write-Host ""
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  AUTOWIPE v4.5 (STABLE) - CORE MODULE INITIALIZATION" -ForegroundColor Cyan
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Verify paths
    Write-Host "[CORE] Checking configuration..." -ForegroundColor Yellow
    Write-Host "  Log path:      $script:LogPath"
    Write-Host "  CSV path:      $script:ProgressCsvPath"
    Write-Host "  HDS XML path:  $script:HdsXmlPath"
    Write-Host "  Reference CSV: $script:ReferenceFile"
    Write-Host ""
    
    # Create directories if needed
    Ensure-Dir $script:LogPath
    Ensure-Dir $script:ProgressCsvPath
    
    # Load CSV state
    Load-ProgressCsv
    
    Write-Host "[CORE] Win32 types: " -NoNewline -ForegroundColor Yellow
    if([System.Management.Automation.PSTypeName]'Win32'.Type) {
        Write-Host "✓ Win32" -ForegroundColor Green
    } else {
        Write-Host "✗ Win32" -ForegroundColor Red
    }
    
    if([System.Management.Automation.PSTypeName]'HDSNative.U32'.Type) {
        Write-Host "                     ✓ HDSNative.U32" -ForegroundColor Green
    } else {
        Write-Host "                     ✗ HDSNative.U32" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "[CORE] Initialization complete." -ForegroundColor Green
    Write-Host ""
    
    Log 'CORE_INIT' @{ 
        version = '4.5 (Stable)'
        csvRecords = $script:ProgressTable.Count
    }
}

# ==========================================================
# EXPORTED FUNCTIONS (for other modules)
# ==========================================================
# This module exports:
#   - $script:DEFAULTS (read-only config)
#   - $script:ProgressTable (CSV state)
#   - All path variables ($script:LogPath, etc.)
#   - Log, Write-LogLine, Ensure-Dir
#   - Normalize-Serial, Normalize-Name, Key-PortSerial
#   - CSV functions: Load-ProgressCsv, Write-ProgressCsv, Set-Record, Clear-Record, Purge-SerialOnOtherPorts
#   - Initialize-Core
# ==========================================================

Write-Host "[CORE] Module loaded." -ForegroundColor DarkGray