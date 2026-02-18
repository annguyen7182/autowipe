# DECISIONS

## 2026-02-17 - D-001: Use repository context spine as shared memory

- Decision: Use `.context/PROJECT_STATE.md`, `.context/TASKS.md`, `.context/DECISIONS.md`, and `.context/ARCHITECTURE.md` as the persistent cross-agent source of truth.
- Rationale: Chat history is agent-local; file-based context is branch-local and visible to all agents working in the same repo.

## 2026-02-17 - D-002: Enforce authority order for conflict resolution

- Decision: Resolve guidance conflicts by this order: pinned artifact/spec, `.context/*`, then current code/docs.
- Rationale: Prevents drift from long chat threads and keeps implementation grounded in explicit project contracts.

## 2026-02-17 - D-003: Require handoff write-back

- Decision: Every completed task must update project state, task status, and decisions (when applicable) in `.context/*`.
- Rationale: Ensures no critical rationale remains only in transient chat logs.

## 2026-02-17 - D-004: Set agent precedence order

- Decision: When agents conflict and no newer approved decision exists, precedence is Claude -> Codex -> Gemini.
- Rationale: Establishes deterministic conflict resolution while preserving the existing context-first source authority model.

## 2026-02-17 - D-005: Require signed handoff reports

- Decision: Every completed handoff/report must end with `Signed-By: <Claude|Codex|Gemini>`.
- Rationale: Adds lightweight accountability and clear authorship across multi-agent sessions.

## 2026-02-17 - D-006: Use local NAS launcher with embedded credential

- Decision: Use `Start-AutoWipe-NAS.bat` on wipe rigs to connect `\\truenas\td_nas`, then launch AutoWipe from `\\truenas\td_nas\Autowipe`.
- Rationale: Operator prioritizes one-click reliability over secret hygiene for this local production environment.
## 2026-02-17 - D-007: Keep settings local and move only HDS XML path

- Decision: Keep settings/log/progress files on local C:\HDMapping; do not switch to per-machine NAS settings folders yet. Set only HDS XML path to C:\Program Files (x86)\Hard Disk Sentinel\HDSentinel.xml.
- Rationale: Operator requested deferring machine-by-machine settings migration while preserving current local workflow.
## 2026-02-17 - D-008: Harden NAS launcher connectivity and diagnostics

- Decision: Start-AutoWipe-NAS.bat first tries \\truenas\td_nas then falls back to \\192.168.0.184\td_nas, clears stale server sessions, and surfaces exit codes on launch failure.
- Rationale: Field startup failures were hard to diagnose and could be caused by host resolution or stale credential sessions.
## 2026-02-17 - D-009: Add persistent NAS launcher logging for field debugging

- Decision: Start-AutoWipe-NAS.bat writes timestamped logs to Start-AutoWipe-NAS.log (script directory, fallback %TEMP%) covering elevation, NAS auth, path checks, and app exit code.
- Rationale: Some rigs show no visible error when launching from desktop; persistent logs allow quick root-cause capture from operators.

## 2026-02-17 - D-010: Capture v5 fleet web-control design as review artifact

- Decision: Store the proposed major update architecture in `autowipe_v5.0.MD` as a draft specification before implementation.
- Rationale: Enables iterative review and risk trimming for a large multi-machine control-plane change without destabilizing v4.5 runtime behavior.

## 2026-02-18 - D-011: Keep popup/nuke behavior, patch discovery and wipe safety surgically

- Decision: Keep existing popup targeting (`#32770` + snapshot) and current nuke behavior unchanged, while fixing `HDS_GetTopWindowsOfProcess` to pass the real PID to `EnumWindows`.
- Rationale: Field behavior for popup/nuke is already validated by operators; the PID forwarding bug caused avoidable HDS window rediscovery failures.

## 2026-02-18 - D-012: Enforce OS-disk skip policy and live LEN thresholds

- Decision: In wipe selection, skip OS-disk targets and continue with remaining disks; do not abort entire wipe batch when non-OS targets remain. Use GUI `Pass LEN` / `Fail LEN` values in watcher verdict logic when valid.
- Rationale: Preserves throughput while adding safety guardrails against accidental system-disk wipes and ensuring operator LEN controls are effective.

## 2026-02-18 - D-013: Make drive-selector acquisition resilient to z-order/focus races

- Decision: In wipe flow, detect selector windows via HDS process + owner chain + class fallback (`TFormDriveSelect*`), then retry `Multiple` opening up to three times before failing.
- Rationale: Field failures showed selector can open behind Surface Test, causing false "selector not found" failures despite successful dialog creation.

## 2026-02-18 - D-014: Publish as semver patch release 4.5.1

- Decision: Mark this change set as `v4.5.1` (patch release) without renaming existing entry-point filenames.
- Rationale: Changes are backward-compatible reliability/safety fixes and UI/runtime metadata updates, which fit semantic-version patch scope.
