# TASKS

## In Progress

- [ ] Maintain `.context/*` updates as part of every completed handoff.
- [ ] Enforce `Signed-By: <Claude|Codex|Gemini>` on completed handoff reports.

## Pending

- [ ] Link commits/PRs to completed tasks once Git history exists for this workflow.
- [ ] Add machine-folder path resolution in code (`machines/<COMPUTERNAME>`) while keeping HDS XML local (deferred for now).
- [ ] Review and finalize `autowipe_v5.0.MD` architecture decisions before implementation kickoff.

## Completed

- [x] Bump release metadata/version strings to `v4.5.1` and add changelog entry for current reliability/safety fixes.
- [x] Harden drive-selector discovery/retry in wipe flow to recover when selector opens behind Surface Test and avoid false wipe-failed outcomes.
- [x] Fix `HDS_GetTopWindowsOfProcess` PID forwarding bug in `modules/hds_control.ps1` so fallback HDS window discovery works correctly.
- [x] Add OS-disk safety filter in `Run-WipeByDiskIndices` to skip system disk targets and continue wiping remaining disks.
- [x] Wire live watcher thresholds by adding `Get-FailLenMin` support and GUI accessors for `Pass LEN` / `Fail LEN` boxes.
- [x] Create `autowipe_v5.0.MD` planning document for fleet-wide web monitoring and control (v5 proposal).
- [x] Add persistent troubleshooting log output to `Start-AutoWipe-NAS.bat` (`Start-AutoWipe-NAS.log`) for launch/elevation diagnostics.
- [x] Improve launcher visibility by showing elevation request/failure messages in `Start-AutoWipe-NAS.bat`.
- [x] Improve `Start-AutoWipe-NAS.bat` reliability with hostname/IP fallback and explicit launch/auth error output.
- [x] Keep settings files local on C:\HDMapping and set HDS XML path to C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.xml in modules/core.ps1.
- [x] Create shared context spine files (`PROJECT_STATE.md`, `TASKS.md`, `DECISIONS.md`, `ARCHITECTURE.md`).
- [x] Verify `CLAUDE.md` and `GEMINI.md` share the same startup checklist and authority order.
- [x] Set agent precedence to Claude -> Codex -> Gemini across workflow docs.
- [x] Add NAS launcher script `Start-AutoWipe-NAS.bat` for credentialed startup from share.

