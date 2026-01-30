# Changelog

All notable changes to the **Autowipe** project will be documented in this file.

## [5.5.0] - 2025-12-28 (Consolidated Release)
### Added
- **Modular Architecture:** Fully decoupled modules (`Core`, `Watcher`, etc.) for easier maintenance.
- **Safe List Cleanup:** `HDS_SmartCleanup` now uses a snapshot system to prevent accidental closure of the Main Dashboard or Active Surface Tests.
- **Batch Automation:** "Auto-Wipe" and "Auto-Save" now use "Newest Drive" logic to reset timers, preventing premature execution while loading a rig.
- **Lost Drive Detection:** System now identifies drives that were "WIPING" but disappeared from WMI, marking them as `LOST` (Orange) instead of just clearing the row.

### Changed
- **GUI Layout:** Batch Counters moved to a dedicated column (X=390) to prevent overlap with countdown timers.
- **Verdict Logic:** Refined thresholds: `PassLenMax` (500) and `FailLenMin` (1000) are now strictly enforced with a 2-tick confirmation for failures.
- **Logging:** Enhanced JSON-structured logging in `WipeWatcher.log` for better debugging.

## [4.4.0] - 2025-12-20
### Added
- **Auto-Clean:** Periodic popup dismissal (every 30s).
- **Safe Window Classes:** Removed `#32770` (Dialog) from safe list to allow aggressive cleanup of error popups.

### Fixed
- **Countdown Bug:** Timers now correctly display hours (e.g., `01:00:00` instead of `60:00`).
- **Dependency Loading:** Main script now checks for module existence before execution.

## [4.0.0] - 2025-11-15
### Added
- **Initial Modularization:** Split the original `Unified.ps1` into 5 distinct modules.
- **CSV Database:** `Port_Serial_Progress.csv` introduced for persistence across app restarts.

## [3.5.0] - 2025-10-01
### Added
- **Report Indexing:** Cached file listing of the HDS Report folder to instantly verify if a report exists (`OK` vs `MISSING`).
- **Center-Click:** Solved "Delphi Button" issue where standard `BM_CLICK` messages were ignored by HDS.

## [2.0.0] - 2025-06-01
### Added
- **Surface Test Tracking:** Ability to bind a specific `Surface Test` window handle to a physical `Port` based on Disk Index.
- **Traffic Light GUI:** Initial WinForms grid implementation.

## [1.0.0] - 2025-02-01
### Added
- **Port Mapping:** Basic script matching `PNPDeviceID` to physical USB ports to replace magnifying glasses.
