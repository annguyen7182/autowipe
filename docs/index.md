---
layout: default
title: AutoWipe Docs
---

# AutoWipe Documentation

This documentation set is aligned to **AutoWipe v4.5.1** in this repository.

## What AutoWipe Does

AutoWipe automates Hard Disk Sentinel operations for high-volume drive testing and erasure rigs. It maps physical ports to disks, tracks active surface tests, calculates PASS/FAILED verdicts, and runs timed batch automation.

## Documentation Map

- `CHANGELOG.md` - release-by-release change history
- `PROJECT_EVOLUTION.md` - architecture and design evolution
- `MULTI_AGENT_WORKFLOW.md` - Claude authority + Codex planning + Gemini implementation workflow

## Current Architecture

```text
autowipe_v4.5.ps1 (entry point)
  -> modules/core.ps1
  -> modules/hds_control.ps1
  -> modules/watcher.ps1
  -> modules/automation.ps1
  -> modules/gui.ps1
```

## Quick Start

1. Ensure `C:\HDMapping\Port_Reference.csv` exists.
2. Launch `autowipe_v4.5.bat`.
3. Run as Administrator when prompted.
