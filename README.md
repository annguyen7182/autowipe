# AutoWipe v4.5

![Version](https://img.shields.io/badge/version-4.5-blue.svg) ![Platform](https://img.shields.io/badge/platform-Windows_PowerShell_5.1-blue.svg)

**AutoWipe** is an industrial automation system for high-volume hard drive testing and erasure. It acts as a "Robot Operator" for **Hard Disk Sentinel (HDS)**, managing up to 24 drives simultaneously with minimal human intervention.

## Key Features

- **Traffic Light Grid**: Visual dashboard for 24 physical USB ports
  - 🟢 **Green**: PASS (100% complete, no errors)
  - 🔴 **Red**: FAIL (Error detected or health failure)
  - 🟡 **Yellow**: READY / WIPING in progress
  - 🟠 **Orange**: LOST (Drive disconnected mid-wipe)

- **Auto-Wipe & Batch Logic**: Automatically starts surface tests with smart batching that waits for the operator to finish loading drives

- **Verdict Engine**: Analyzes HDS log windows to determine Pass/Fail without human review

- **Auto-Cleanup**: Dismisses nuisance popups (error confirmations, "Are you sure?" dialogs) without closing critical windows

- **Modular Architecture**: Clean separation into 5 maintainable modules

---

## Prerequisites

1. **OS**: Windows 10 or 11
2. **Software**:
   - **Hard Disk Sentinel Pro** (default path: `C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.exe`)
   - **PowerShell 5.1** or newer
3. **Hardware**: USB wiping rig with known port mappings (up to 24 ports)

---

## Installation

### 1. File Placement
Copy the `Autowipe_4.5` folder to your desired location (e.g., `C:\AutowipeApp`).

### 2. Port Mapping Setup
Create the data directory at **`C:\HDMapping\`** and place a **`Port_Reference.csv`** file:

```csv
PortNumber,PortID
1,USB\VID_XXXX&PID_XXXX\Location_1
2,USB\VID_XXXX&PID_XXXX\Location_2
...
```

This maps Windows `PNPDeviceID` strings to your physical slot numbers (1-24).

---

## Usage

1. Navigate to the `Autowipe_4.5` folder
2. Double-click **`autowipe_v4.5.bat`** (or right-click `autowipe_v4.5.ps1` → Run with PowerShell)
3. Grant **Administrator privileges** when prompted (required for HDS window control)

### Interface Controls

| Button | Function |
|--------|----------|
| **Refresh Baseline** | Scan for newly connected drives |
| **Auto-Check** | Toggle periodic Pass/Fail verdict scanning |
| **Auto-Wipe** | Toggle automatic Surface Test launching |
| **Clean** | Remove "Empty" or "Lost" rows from view |

---

## Architecture

```
Autowipe_4.5/
├── autowipe_v4.5.ps1    # Entry point (loads modules)
├── autowipe_v4.5.bat    # Batch launcher
└── modules/
    ├── core.ps1         # Config, logging, CSV, Win32 API
    ├── hds_control.ps1  # Window enumeration, button clicking
    ├── watcher.ps1      # Port mapping, verdict engine
    ├── automation.ps1   # Timers, batch logic, scheduling
    └── gui.ps1          # WinForms interface
```

| Module | Role |
|--------|------|
| **Core** | Foundation - logging, configuration, Win32 P/Invoke |
| **HDS Control** | "The Hands" - clicks buttons, manages windows |
| **Watcher** | "The Eyes" - maps ports, judges Pass/Fail |
| **Automation** | "The Brain" - timers, batch scheduling |
| **GUI** | "The Face" - visual grid display |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "HDS not found" | Install Hard Disk Sentinel to default `Program Files (x86)` path |
| Drives showing as "Disk 0" | Check `Port_Reference.csv` mapping; look for "UNMAPPED_PORT" in logs |
| Popups not closing | Close pre-existing popups manually; the safety snapshot may have captured them |

---

## Version History

| Version | Changes |
|---------|---------|
| v1.0 | Basic port-to-serial grid display |
| v2.x | Surface Test window tracking |
| v3.x | Verdict logic, report indexing |
| v4.0 | Modular refactor (5 modules) |
| v4.1-4.4 | Batch timing, Auto-Clean, GUI fixes |
| **v4.5** | Stable release - Lost Drive detection, snapshot cleanup, refined verdicts |

See `docs/PROJECT_EVOLUTION.md` for the full development story.

---

## License

This project was developed for internal production use.
