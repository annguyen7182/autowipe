# PROJECT_STATE

## Current goal (1-2 lines)

- Keep AutoWipe v4.5 behavior stable while standardizing cross-agent handoff through a shared context spine.

## Working assumptions

- Runtime target remains Windows 10/11 with PowerShell 5.1 and Hard Disk Sentinel Pro.
- The repository root is the canonical source of implementation and docs state.
- Agents (Claude/Codex/Gemini) read `.context/*` before implementation work.
- Agent precedence for conflict resolution is Claude -> Codex -> Gemini.
- Completed handoffs must include `Signed-By: <Claude|Codex|Gemini>`.
- AutoWipe is launched from NAS share `\\truenas\td_nas\Autowipe` using a local launcher.
- HDS XML remains local at `C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.xml`.
- Fleet web-control scope for v5 is currently documented as a draft in `autowipe_v5.0.MD` and remains under review.

## Active tasks (ranked)

1. [x] Bootstrap shared `.context/` files for multi-agent continuity.
2. [x] Define agent precedence as Claude -> Codex -> Gemini.
3. [x] Enforce signed handoffs with `Signed-By` footer.
4. [ ] Keep `.context/TASKS.md` synchronized with active and completed work.
5. [ ] Record behavior/interface decisions in `.context/DECISIONS.md` before contract changes.

## Interfaces / contracts (must not break)

- Entry points: `autowipe_v4.5.ps1` and `autowipe_v4.5.bat`.
- Module boundaries: `modules/core.ps1`, `modules/hds_control.ps1`, `modules/watcher.ps1`, `modules/automation.ps1`, `modules/gui.ps1`.
- Mapping input path: `C:\HDMapping\Port_Reference.csv`.
- Hard Disk Sentinel executable path assumption: `C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.exe`.

## Recent changes (last 24h)

- (working tree) Bumped patch release metadata to `v4.5.1` (README/docs/changelog and runtime banner strings) following semver patch versioning.
- (working tree) Hardened drive-selector detection in `modules/hds_control.ps1` with process/owner-aware matching, class fallback (`TFormDriveSelect*`), and retry logic to recover when selector opens behind the Surface Test window.
- (working tree) Fixed HDS top-window PID filtering in `modules/hds_control.ps1` so fallback main-window discovery uses the actual process ID.
- (working tree) Added OS-disk guard in `Run-WipeByDiskIndices` to skip system disk targets and continue wiping non-OS disks.
- (working tree) Wired live watcher LEN thresholds by adding `Get-FailLenMin` support and GUI-backed `Get-PassLenMax`/`Get-FailLenMin` accessors.
- (working tree) Added initial `.context/` context spine files for shared agent memory.
- (working tree) Updated multi-agent workflow docs to require `.context` startup and handoff updates.
- (working tree) Added explicit agent precedence (Claude -> Codex -> Gemini) and required handoff signatures.
- (working tree) Added `Start-AutoWipe-NAS.bat` launcher with NAS authentication and UNC startup.
- (working tree) Kept settings files on local C:\HDMapping and changed HDS XML path in code to C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.xml.
- (working tree) Hardened `Start-AutoWipe-NAS.bat` with hostname/IP fallback, NAS session cleanup, and visible launch error codes.
- (working tree) Updated `Start-AutoWipe-NAS.bat` to show explicit elevation status and avoid silent exits during startup.
- (working tree) Added persistent launcher log file `Start-AutoWipe-NAS.log` with timestamped step/error tracing including elevation handoff.
- (working tree) Added `autowipe_v5.0.MD` with v5 fleet monitoring/control architecture proposal for review.
