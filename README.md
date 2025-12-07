# Autowipe 3.4

Enterprise-scale hard drive wiping automation for R2-certified data sanitization environments.

## Problem

Manual hard drive wiping is inefficient and error-prone. Processing 480 drives across 20 rigs requires constant monitoring and manual intervention, taking approximately 3 hours per cycle.

## Solution

PowerShell automation system that orchestrates Hard Disk Sentinel through Win32 APIs and UI automation, enabling simultaneous management of 480 drives with minimal human intervention.

## Key Features

- **Session Management**: Tracks wiping state across multiple HDS instances
- **Popup Handling**: Automatically manages GUI popups and dialog windows  
- **Progress Monitoring**: Real-time status tracking across HDS surface test windows
- **Wipe History**: Automatic logging of drives that fail during wiping operations
- **R2 Compliance**: Generates audit logs for certification requirements

## Technical Details

- 3,000+ lines of PowerShell
- Win32 API integration for window management
- GUI automation via UI element detection
- Concurrent process orchestration (20 rigs × 24 bays = 480 drives)

## Impact

- Reduced processing time from 3 hours to under 1 hour per cycle
- Enabled full automation across 20 wiping rigs (480 drives simultaneously)
- Eliminated human error in wiping operations

## Status

Production deployment at R2-certified electronics recycler.


