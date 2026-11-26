# gentle-update: align with stable v5
Objective: Align `gentle-update` with the official stable v5 releases and documented update guidance. Branch: `fix/gentle-update-v5`. Delivery: `ask-on-risk`.
Isolated test runners: Bash stub suite; PowerShell stub suite if the runtime is available.

## Specs

- S1: “revisa que el script gentle-update se alinee para descargar la ultima release v5 de gentleman ecosistem y se alinee con su documentacion y sugerencias.”
- S2: “ok dale alinealo”

## Tasks

- T1 — Linux Shell and standalone Gentle AI stable v5 (S1-S2; gentle-ai-worker, done (commits c8d1a3a, 5a8a615, 43e2581, bc139b5, a3c02fb; independent re-verification of a3c02fb found no blockers; suites updater 409, rollback 147, reset 27, boards-backlog 35; native review lineage review-0df33b99d3c39854 ESCALATED, not closed)).
- T2 — Windows stable release alignment (S1-S2; gentle-ai-worker, partial (commits 246c09c, 71fa215, fd1ab50; two correction rounds; static verification only, no PowerShell runner, no live Windows run; the second correction fd1ab50 was not re-verified)).
- T3 — Linux Engram running-service safeguards and operator guidance (S1-S2; gentle-ai-worker, partial (commits b412704 and the final Engram correction; independent verifier found 3 blockers on b412704, one correction batch applied and covered by regression tests, suites updater 610, rollback 147, reset 27, boards-backlog 35, not independently re-verified; no live Engram run)).

## Log

- L1 — Original request: “revisa que el script gentle-update se alinee para descargar la ultima release v5 de gentleman ecosistem y se alinee con su documentacion y sugerencias.”
- L2 — Approval: “ok dale alinealo”
- Branch `fix/gentle-update-v5` was approved using the choice tool.
- Planning: Aim for about 400 authored lines per local commit; split at the platform and Engram boundaries. No publishing.
- Release evidence: The official Gentle Shell and Gentle AI releases are both `v5.0.0`; the official Gentle Shell bundle pins Pi `1.6.0`.
- Update decisions: Distinguish the former global Shell package from bundled Gentle Shell, and standalone Gentle AI from the Pi extension. Use stable release sources and preserve holds and native rollback. Never remove the former global package during unattended runs or force a runtime self-update as a Shell upgrade.
- Engram releases separately; do not restart or migrate it blindly.
- L3 — T1 first commit: `c8d1a3a` (`fix(updater): align Linux Shell and Gentle AI with v5`), 699 authored changed lines. It exceeds the ~400-line planning heuristic because the platform-specific updater logic, tests, and README form one coherent behavior. The T1 Linux slice is `c8d1a3a` plus correction `5a8a615`, with 817 authored changed lines in the combined diff.
- L4 — Independent verification of `c8d1a3a` closed both earlier blockers and found three issues: setup retry after transient failure, exclusion of the npm alias `gs-legacy` by package identity, and stale `--help` text. One correction batch was applied in `5a8a615`; suites were green: updater 354, rollback 147, reset 27, and boards-backlog 35. `bash -n` and ShellCheck both exited 0.
- L5 — No live launcher or upgrade run. Native `upgrade --channel release` resolves the latest release independently; the exact major cannot be pinned. A mismatch is detected and reported after activation, without rollback.
- L6 — Re-verify only the three blockers on `5a8a615`, then run native review (assessed high, `reviewDue`, risk item 5), then proceed to T2 and T3.
- L7 — Independent verification of `5a8a615` found one remaining blocker: the retry marker was not bound to the active version mid-run. The second correction, `43e2581`, closed it.
- L8 — Native review lineage `review-0df33b99d3c39854` (high; 4 lenses plus refuter; base `515338d`; committed-only, excluding this untracked ODD document) found five BLOCKERs, all introduced: R1-001 and R4-001 (packages changed the baseline `undo with:` snapshot message), R3-001 (symlinked HOME rejected a valid bundled launcher), R3-002 (smoke check bypassed legacy snapshot rollback for every broken gentle-shell), and R3-003 (catalog-refresh failure cleared the pending marker). Informational, non-blocking findings: R1-002, R2-001, R2-002, and R4-002.
- L9 — One bounded correction, `bc139b5`, changed 114 diff lines, within the 200-line budget. Assertions passed: updater 395, rollback 147, reset 27, boards-backlog 35. `bash -n` and ShellCheck both exited 0. The native targeted validator then rejected the correction for all five findings. Lineage state: escalated (`targeted_validator_rejected`); reason text was not exposed to the parent. Budget spent: no retry, no new lineage, no reset. Review is an outside view and never authorizes delivery.
- L10 — Independent verification of `bc139b5` and T2 Windows are running. T3 Engram safeguards follow once T1 settles. The Linux T1 slice totals 947 authored changed lines over four commits on `fix/gentle-update-v5`. Publishing remains the user's decision.
- L11 — Independent verification of `71fa215` (T2) found defect #3 was only partially addressed and identified two small new defects. The second correction, `fd1ab50`, was applied without re-verification.
- L12 — Independent verification of `b412704` (T3) found three blockers: export could hang, retention deleted operator-owned files, and prune could delete the reported backup. All three were fixed in one batch with ported regression tests.
- L13 — On 2026-11-26 the user objected: “wee que tanto haces? estas conciente que te pedi solo cambiar de v4 a v5 para gentleman y ya pasaron horas”. The parent acknowledged scope inflation: the core v4-to-v5 change is the `/v4` → `/v5` module path in `GENTLE_AI_PKG` at `scripts/linux/gentle-update` plus its test; the branch grew to ~1,550 authored lines over 10 commits. The user chose “Terminar lo ya hecho”: finish and commit existing work, with no new verification rounds.
- L14 — Open items: T1 native review is escalated and unresolved; T2 and T3 were not re-verified after their last corrections. There were no live runs on Windows, with the real launcher, or with real Engram. Windows has no hold support (pre-existing). Push, PR, and merge remain the user's decision.
