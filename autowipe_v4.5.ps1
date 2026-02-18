# ==========================================================
# AUTOWIPE v4.5.1 (STABLE) - MAIN ENTRY POINT
# ==========================================================
# Modular architecture:
#   CORE         → Foundation (logging, CSV, Win32)
#   HDS_CONTROL  → HDS automation API
#   WATCHER      → Surface test observer
#   AUTOMATION   → Timer engine
#   GUI          → Presentation layer
# ==========================================================

# ==========================================================
# ADMIN PRIVILEGE CHECK & ELEVATION
# ==========================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "  AUTOWIPE requires Administrator privileges" -ForegroundColor Yellow
    Write-Host "  Restarting with elevation..." -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host ""
    
    # Restart script as admin
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Running as Administrator" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  AUTOWIPE v4.5.1 (STABLE) - LOADING MODULES" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Verify module directory exists
$modulePath = Join-Path $PSScriptRoot "modules"
if (-not (Test-Path $modulePath)) {
    Write-Host ""
    Write-Host "ERROR: modules directory not found!" -ForegroundColor Red
    Write-Host "Expected path: $modulePath" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Load modules in dependency order
try {
    Write-Host "[MAIN] Loading CORE..." -ForegroundColor Yellow
    . "$PSScriptRoot\modules\core.ps1"
    
    Write-Host "[MAIN] Loading HDS_CONTROL..." -ForegroundColor Yellow
    . "$PSScriptRoot\modules\hds_control.ps1"
    
    Write-Host "[MAIN] Loading WATCHER..." -ForegroundColor Yellow
    . "$PSScriptRoot\modules\watcher.ps1"
    
    Write-Host "[MAIN] Loading AUTOMATION..." -ForegroundColor Yellow
    . "$PSScriptRoot\modules\automation.ps1"
    
    Write-Host "[MAIN] Loading GUI..." -ForegroundColor Yellow
    . "$PSScriptRoot\modules\gui.ps1"
    
    Write-Host ""
    Write-Host "[MAIN] All modules loaded successfully." -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host ""
    Write-Host "ERROR loading modules!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Initialize modules
try {
    Initialize-Core
    Initialize-HdsControl
    Initialize-Watcher
    Initialize-Automation
} catch {
    Write-Host ""
    Write-Host "ERROR during initialization!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Show GUI (blocking)
try {
    Show-AutowipeGUI
} catch {
    Write-Host ""
    Write-Host "ERROR in GUI!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
