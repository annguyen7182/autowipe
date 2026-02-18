# AutoWipe v4.5.1

![Version](https://img.shields.io/badge/version-4.5.1-blue.svg) ![Platform](https://img.shields.io/badge/platform-Windows_PowerShell_5.1-blue.svg)

AutoWipe is a Windows PowerShell automation system for high-volume hard drive testing and erasure with Hard Disk Sentinel (HDS). It manages up to 24 rig ports with a live dashboard, verdict automation, and batch-driven actions.

## Status

- Current stable release: **v4.5.1**
- Runtime stack: **Windows 10/11 + PowerShell 5.1 + Hard Disk Sentinel Pro**
- Repository layout in this branch is the canonical source of truth

## Core Features

- Traffic-light grid for 24 physical ports (PASS, FAILED, in-progress, missing)
- Automated verdict engine based on Surface Test progress and log length thresholds
- Batch automation for refresh, save report, wipe start, and popup cleanup
- Snapshot-safe popup dismissal to avoid closing critical HDS windows
- Modular architecture for maintainability (`core`, `hds_control`, `watcher`, `automation`, `gui`)

## Repository Structure

```text
Autowipe/
|-- autowipe_v4.5.ps1
|-- autowipe_v4.5.bat
|-- modules/
|   |-- core.ps1
|   |-- hds_control.ps1
|   |-- watcher.ps1
|   |-- automation.ps1
|   `-- gui.ps1
`-- docs/
    |-- index.md
    |-- CHANGELOG.md
    |-- PROJECT_EVOLUTION.md
    `-- MULTI_AGENT_WORKFLOW.md
```

## Prerequisites

1. Windows 10 or Windows 11
2. PowerShell 5.1 or newer
3. Hard Disk Sentinel Pro installed at:
   - `C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.exe`
4. Port mapping file at:
   - `C:\HDMapping\Port_Reference.csv`

Example mapping format:

```csv
PortNumber,PortID
1,USB\VID_XXXX&PID_XXXX\Location_1
2,USB\VID_XXXX&PID_XXXX\Location_2
```

## Run

1. Open this folder locally.
2. Start `autowipe_v4.5.bat` (or run `autowipe_v4.5.ps1`).
3. Accept UAC elevation when prompted.

## Documentation

- Overview: `docs/index.md`
- Changelog: `docs/CHANGELOG.md`
- Development history: `docs/PROJECT_EVOLUTION.md`
- Claude + Codex + Gemini handoff workflow: `docs/MULTI_AGENT_WORKFLOW.md`
- Shared multi-agent context spine: `.context/`

## Troubleshooting

- HDS not found: confirm install path in `modules/hds_control.ps1`
- Incorrect port display: verify `C:\HDMapping\Port_Reference.csv`
- Popups not closing: manually clear old dialogs, then rerun automation

## License

Internal production use.
