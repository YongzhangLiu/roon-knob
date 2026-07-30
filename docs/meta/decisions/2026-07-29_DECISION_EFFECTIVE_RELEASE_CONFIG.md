# Decision: enforce the *effective* firmware release configuration

**Date:** 2026-07-29
**Issue:** [#202](https://github.com/muness/roon-knob/issues/202) (parent [#189](https://github.com/muness/roon-knob/issues/189), program [#201](https://github.com/muness/roon-knob/issues/201), epic [#196](https://github.com/muness/roon-knob/issues/196))
**Status:** Accepted; implemented and enforced. Optimization candidate amended to PERF after the SIZE-built Dial preview failed sustained boot.

**Hardware amendment, 2026-07-30:** PR #204's published Dial/round preview at `9ef325a12d2564848f3a944d889b57e9f99ec9c7`, built with `CONFIG_COMPILER_OPTIMIZATION_SIZE=y`, entered a boot loop on the target device. That is a release-blocking failure of #203's sustained-boot check, although the observation alone does not isolate compiler optimization as the cause. The static measurements below remain valid historical evidence, but they are insufficient to choose a shippable mode. The corrected candidate restores the complete working-v4 build profile rather than changing optimization alone: ESP-IDF `release-v5.5`, `CONFIG_COMPILER_OPTIMIZATION_PERF=y`, 16 MB merged-image geometry, a 4096-byte main-task stack, and PSRAM BSS placement. It remains blocked pending a real flash and sustained-boot test. If that exact candidate also boot-loops, the next diagnostic is its serial boot log and a DEBUG control from the same source SHA—not weakening the release gate.

**Observed:** the host half, and reproducibly so — both suites are committed and both run in `release-config-fixtures`, so these are not one-off scratch runs:

* `tools/test_check_release_config.sh` — the checker and the host asserter: exit contract, token precedence in both directions, absence-directionality, secret non-leakage, assert-the-assertion, caller-owned marker, caller-owned refusal of absence-satisfied invariants (both directions, plus its vacuous-pass guard), empty-argument contract, and the tripwire that the CI-only canary is not committed.
* `tools/test_release_config_cmake.sh` — the **gate** itself, running under `cmake -P` with IDF's two commands stubbed: compliant-pass, ON-violation-fails, OFF-violation-continues (with banner and `enforced:false`/`verdict:fail` report), `NOCHECKER`, the **message-attribution** cases (an empty capture, a tokenless-but-noisy capture and a metadata-only capture each synthesize a non-empty `RK-RELCFG-INTERNAL` first line; noise *preceding* a verdict is demoted below it so the verdict heads the failure, and is preserved rather than dropped; and two cases run the **real** checker against a real violating fixture to pin that `RK-RELCFG-VIOLATION` heads the failure ahead of the `RK-RELCFG-REPORT` path the checker prints first, and that `NOREPORT` outranks `VIOLATION` when the report cannot be written), `;`→`,`, `NOREPORT`, an unlaunchable interpreter (the non-numeric `RESULT_VARIABLE` case that `STREQUAL "0"` exists for), and a missing `fail_at_build_time` (which must fail attributably with `RK-RELCFG-NOHELPER` rather than reaching CMake's unlabelled "Unknown CMake command" at the exact moment the gate is trying to block a build). An earlier revision of this record cited an *uncommitted* harness for these, which by this record's own standard was a claim that could not be checked from the tree.
Only those two suites are committed and re-runnable, and only they support this Status line.

Separately, and **not** evidence in the same sense: before landing, each host `run:` step in `build-idf`, `build-stale-config` and `release` was exercised by hand against a simulated runner — a root-owned read-only `build/config`, a missing report, a wrong log, differing ON/OFF digests, the mode-agnostic seed against synthetic SIZE- and PERF-selected defaults, and the canary both passing and failing on a reworded warning. Those checks were scratch scripts extracted from the workflow, not committed fixtures: they informed the design and caught real defects, but nobody can re-run them from this tree, so they are recorded here as provenance rather than counted as coverage. The workflow's own host steps now have real coverage from CI, recorded below.

**Observed in container CI.** The container half is no longer pending. Run [**30506101326**](https://github.com/muness/roon-knob/actions/runs/30506101326), event `pull_request`, attempt 1, head **`62ffc4ae577787cf5b67a197bf985634a633b861`**, conclusion **success**, 3m44s total:

| Surface | Result | Wall time |
|---|---|---|
| `release-config-fixtures` | success — 77/77 host, 13/13 CMake | 0m10s |
| `build-idf` | success — forced ON, three host assertions, clean log scan | 3m32s |
| `build-stale-config` | success — ON fails at the gate, OFF succeeds, canary live | 3m27s |
| `deploy-pr-preview` | success | 0m07s |
| `release`, `deploy-pages` | skipped (not a tag) | — |

* **Resolved release configuration:** report `enforced: true`, `verdict: pass`, token `RK-RELCFG-OK`, **11 of 11** invariants passing, mode `COMPILER_OPTIMIZATION_SIZE`, `config_digest sha256:d14a7cf7be5fe6978a4455267f8eeca45860864ccefa8af68a4f6d1385a41589`.
* **Artifact** `esp32s3-firmware` (id 8745418925) contained **exactly three** files — `idf_app/build/roon_knob.bin` (1 613 984 B), `roon_knob_merged.bin` (1 679 520 B) and `idf_app/build/config/rk_release_config.json` (3 335 B) — each asserted present by byte count before upload. The shipped binary is exactly the SIZE figure from the measurement table, so the mode this record claims is the mode that shipped.
* **The ON/OFF pair proved causal, not merely correlated.** Both runs resolved the *same* configuration, `config_digest sha256:8ceb68901f52f526de4b72360b7c16381a2563277e3f107a27a4e47bed28ce8b`, with the same `fail` verdict; enforcement ON failed at the gate (exit 2, `fail_at_build_time`'s target visible in the ninja edge) while enforcement OFF built a 1 761 952-byte binary — exactly the DEBUG measurement figure. `fail_at_build_time()` is the only difference between a blocked build and a shipped one, demonstrated rather than argued.
* **The delegated determination is live.** The canary produced exactly `RK-RELCFG-UNDEFINED: CONFIG_RK_CANARY_UNDEFINED_SYMBOL` at the required exit 4, and its sentinel value never appeared in the checker's output. kconfgen's wording on this image still matches what the regex reads.
* The clean `build-idf` log contained **zero** `unknown kconfig symbol` occurrences and no `UNDEFINED`/`NOLOG`/`NOREPORT` token, and the log-identity assertion reported `digest-matched markers=RK-RELCFG-VERDICT:`.

**Scope of that observation, stated precisely.** Run `30506101326` executed the tree at `62ffc4ae577787cf5b67a197bf985634a633b861`. Every code, workflow, CMake, checker and fixture file was byte-identical between that commit and its documentation-only successor, so that evidence described the successor's behaviour too. The record then predicted a re-run on that docs-only successor and said a *material* divergence would itself be a finding. That prediction was discharged rather than left outstanding; the result is below.

**Recorded run at `876c0786d59938deb2794aa4e3e104642c35f601`.** Run [**30507024502**](https://github.com/muness/roon-knob/actions/runs/30507024502), event `pull_request`, head **`876c0786d59938deb2794aa4e3e104642c35f601`**, conclusion **success**, ~4m00s total:

| Surface | Result | Wall time |
|---|---|---|
| `release-config-fixtures` | success — 77/77 host, 13/13 CMake | 0m10s |
| `build-idf` | success | 3m43s |
| `build-stale-config` | success — ON fails at the gate, OFF succeeds, canary live | 3m19s |
| `deploy-pr-preview` | success | 0m07s |
| `release`, `deploy-pages` | skipped (not a tag) | — |

**No material divergence between the first two recorded runs.** Run `30507024502`'s `esp32s3-firmware` report carries the *same* `enforced: true`, `verdict: pass`, `RK-RELCFG-OK`, **11 of 11** invariants passing, and the identical `config_digest sha256:d14a7cf7be5fe6978a4455267f8eeca45860864ccefa8af68a4f6d1385a41589` as run `30506101326`, with `roon_knob.bin` at the same 1 613 984 B and the merged image at the same 1 679 520 B. The two runs agree byte-for-byte on every figure this record quotes. The implementation-run history above is retained deliberately rather than overwritten: the ON/OFF causal pair, the artifact composition and the canary were *first* observed there, and collapsing the history into a single latest-run line would discard the provenance of how each claim came to be checkable.

**Two further recorded runs, at the ancestors carrying the message-attribution work.** The two runs above predate the review findings described below, so they are not the whole container record and an earlier revision of this section left the rest of it uncited. Two more `pull_request` runs of `Build and Release`, each attempt 1, each conclusion **success** with `release-config-fixtures`, `build-idf` and `build-stale-config` all green and `release` / `deploy-pages` skipped (not a tag):

| Run | Head commit | Fixtures job | `build-idf` | `build-stale-config` | Total |
|---|---|---|---|---|---|
| [**30510929713**](https://github.com/muness/roon-knob/actions/runs/30510929713) | `4d16d3b84916246ace024ce49b781ee83c8c6384` | success — **77/77 host, 17/17 CMake** (0m08s) | success 3m43s | success 3m24s | 3m57s |
| [**30512450762**](https://github.com/muness/roon-knob/actions/runs/30512450762) | `1eae955bb4aba60673396eae91b7cf2903fa99f6` | success — **77/77 host, 23/23 CMake** (0m08s) | success 3m43s | success 3m34s | 4m03s |

Both agree with the earlier pair on every figure this record quotes. In each, `build-idf` printed `RK-RELCFG-OK` and `RK-RELCFG-VERDICT: pass` with the identical `config_digest sha256:d14a7cf7be5fe6978a4455267f8eeca45860864ccefa8af68a4f6d1385a41589`, its host asserter reported `RK-RELCFG-ASSERT-OK: enforced=true verdict=pass digest-matched`, and `roon_knob.bin` linked at `0x18a0a0` — 1 613 984 B, the SIZE figure from the measurement table. In each, `build-stale-config`'s ON run failed at the gate with `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG` on `config_digest sha256:8ceb68901f52f526de4b72360b7c16381a2563277e3f107a27a4e47bed28ce8b`, the OFF run built on that same resolved configuration, and both *Assert kconfgen's undefined-symbol determination is still live* and *Assert run 2 succeeded, unenforced, on the same violating config* passed — so the canary and the controlled pair are live at `1eae955bb4aba60673396eae91b7cf2903fa99f6`, not only at the first two SHAs.

**The CMake suite's growth is visible across the four runs — and so is the defect it covers.** 13 cases at `62ffc4ae…` and `876c0786…`, **17** at `4d16d3b8…`, **23** at `1eae955b…` and in this tree. More usefully, the exit-code-keyed headline is **container-observed before and after**, not only host-covered: in run `30510929713`'s ON build the `fail_at_build_time()` ninja edge led with `RK-RELCFG-REPORT: /app/…/build/config/rk_release_config.json` — precisely the defect described below, in the live container — while in run `30512450762`'s it leads with `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG`. That is the fix demonstrated on the real checker's real output, which is the one thing the stubbed cases cannot show.

**How to read all four runs, and what they do not cover.** Each run above is attributed to the **immutable exact commit it executed**, and to nothing else. Neither is described as "the final head" or "the current head": those are moving labels, and a record that pins evidence to a moving label stops being checkable the moment the branch advances. What each run licenses is a statement about *that* commit's tree.

All four of `62ffc4ae577787cf5b67a197bf985634a633b861`, `876c0786d59938deb2794aa4e3e104642c35f601`, `4d16d3b84916246ace024ce49b781ee83c8c6384` and `1eae955bb4aba60673396eae91b7cf2903fa99f6` are **verified predecessors** of the commit carrying this paragraph — ancestors whose CI results are recorded above. No relative position among them is asserted here, deliberately. Earlier revisions of this paragraph labelled first `876c0786…` and then `1eae955b…` as "the immediate parent"; each was true when written and each stopped being true when the branch advanced. "Immediate parent" is a moving label of exactly the kind the paragraph above rejects, so it is removed rather than re-pointed at a third SHA: every claim below names the commit it is about.

The first two SHAs predate real **runtime** differences, all from review findings, so their evidence does not carry to this tree unqualified — the later two carry those differences, which is why they are now recorded rather than left uncited. They are enumerated below rather than counted: an earlier revision said "two real code differences" and missed one, and this record has now mispriced a change surface by a number three times. Re-derive with `git diff 876c0786d59938deb2794aa4e3e104642c35f601..HEAD` and discard the hunks that are comment-only.

* `cmake/rk_release_config.cmake` now chooses `fail_at_build_time()`'s required first line by **the checker's exit code**, promoting the token that exit code designates ahead of ambient interpreter output *and ahead of the checker's own metadata lines*, and synthesizing an `RK-RELCFG-INTERNAL` line when no governing verdict was emitted. An earlier revision of this bullet described the rule as "promote the first `RK-RELCFG-*` token", which was the rule and was wrong in two ways that only the real checker exposes. The real checker leads with `RK-RELCFG-REPORT: <build dir>/config/rk_release_config.json`, then `RK-RELCFG-ENFORCED`, and only then the verdict — so "first token" headed every violating build with a build-directory path. And output order does not track precedence: a violating tree whose report cannot be written exits **6** (`NOREPORT` outranks `VIOLATION`) while still printing `VIOLATION` first, so the positional rule named a verdict the checker did not govern by. Keying to the exit code is keying to the same contract CI reads. Metadata (`REPORT`, `ENFORCED`, `DIGEST`, `VERDICT`, `OK`) can never lead — `OK` heading a *failing* build would be a flat contradiction — and every demoted line is preserved below line 0 rather than dropped. This changes the *ordering and attribution* of an existing failure message; it does not change whether any build fails.
* `tools/test_release_config_cmake.sh` gains fixture cases pinning that behaviour, so the CMake suite is **23 cases in this tree**, where the first two recorded runs observed 13 and `4d16d3b8…`'s observed 17. All 23 are container-observed at `1eae955bb4aba60673396eae91b7cf2903fa99f6`, in run `30512450762`. `tools/cmake_gate_harness.cmake` moves with it: the stub `fail_at_build_time()` now records **every** argument in order as `ARG=` lines, not just `LINE0=`, which is what makes "demoted, not dropped" an assertion rather than an assumption. Two of the new cases run the **real** `check_release_config.py` against a real violating fixture with the real `--report`/`--enforced`, because the defect above was invisible to stubs: a stub that emits a verdict as its first line cannot expose a rule that mistakes metadata for a verdict. Verified as real coverage by reverting the gate alone — the new cases fail against the previous selection rule, naming `RK-RELCFG-REPORT` as the line that claimed line 0 — and corroborated in the container by the before/after headline ordering across runs `30510929713` and `30512450762` recorded above. The `13/13` and `17/17` figures in the tables are left as recorded: they are what those runs actually reported at those SHAs, and editing them to match this tree would be exactly the retro-fitting this record exists to prevent.
* `.github/workflows/docker.yml` gains two **executable** blocks, which is the surface the earlier "two real code differences" wording dropped. Both are `out += [...]` appends inside the embedded `python3` heredocs — one in `build-idf`'s *Publish release config evidence to the run summary* step, one in the `release` job's published-summary step — and both emit the static caveat that a green gate is a **configuration** verdict and not image geometry, naming the open `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` versus `merge-bin --flash-size 8MB` disagreement. They change what CI *publishes to a reader*, not merely what the workflow file explains to a maintainer, which is why they belong on this list and why the two copies are marked in-file as having to stay in step. Everything else in that file's delta since `876c0786…` is comment-only.

**Not on this list, and checked rather than assumed:** at the time this list was written, the deltas to `idf_app/tools/assert_release_report.py` (its docstring, rescoping "CI cannot opt out" to the narrower claim that actually holds) and to `idf_app/tools/check_release_config.py` were **comment-only** in the same mechanical sense used above, as was `idf_app/sdkconfig.defaults`. None of the three changed a byte the interpreter executed, so none of them qualified a run's evidence, and counting them here would have inflated the surface in the opposite direction from the undercount being corrected. That is still true of the checker and the defaults; it is **no longer** true of `assert_release_report.py`, which has since gained the executable `--forbid-absent-satisfied` flag — see "The byte-identity carry-forward argument no longer holds" below, which is where that delta is accounted for.

At the executable `aee0a78` head, deliberately **no same-commit run was claimed in-tree**: a record cannot cite CI for the tree that contains the citation, because the run must exist after that commit. That principle is unchanged. The prediction is no longer left open, however — this documentation-only successor can cite `aee0a78`'s immutable run, and the next documentation-only confirmation, without claiming evidence from its own future.

**What has changed is that the prediction it used to leave outstanding is now an observation.** An earlier revision closed this paragraph with "CI at this commit is expected to reproduce the tables with `23/23 CMake`; if it does not, that is a finding" — and then did not go and look, while a green container run reporting exactly `23/23` already existed at a recorded predecessor. `23/23` in the container is **recorded**, not expected: run `30512450762` at `1eae955bb4aba60673396eae91b7cf2903fa99f6`, above. Leaving that uncited was the same fault this record corrects elsewhere in the other direction — a checkable fact left as an expectation understates the evidence just as an unchecked claim overstates it, and by this record's own standard the prediction should have been discharged rather than restated.

**The byte-identity carry-forward argument no longer holds, and this section says so before making any weaker claim.** Through `1eae955bb4aba60673396eae91b7cf2903fa99f6`'s docs-only successors, every checker, gate, workflow, CMake, fixture and defaults byte that run `30512450762` executed was the byte in the tree, so that run's evidence carried forward unqualified. Two review adjustments — closing the preview-gating asymmetry (#207) and pinning the absent-invariant shape (#206's signal half) — are **executable**, so that argument is now void and is retired rather than quietly leaned on. What changed, enumerated:

* `.github/workflows/docker.yml` — **executable, three places.** `deploy-pr-preview`'s `needs:` gains `build-stale-config`, making it identical to `release`'s; `build-idf`'s *Assert the release config gate ran, enforced, and passed* step gains `--forbid-absent-satisfied`; and the tag-only `release` job applies the same flag when it re-asserts the downloaded artifact before publication. The first changes the job graph; the other two add the same failure mode at build and publication boundaries. None is a comment edit and none should be read as one.
* `idf_app/tools/assert_release_report.py` — **executable**: the new opt-in `--forbid-absent-satisfied` flag and its check. It is **opt-in by construction**, so the three invocations that do not pass it — the two in `build-stale-config` and the caller-owned log-marker assertion in `build-idf` — behave exactly as the recorded runs observed. Its docstring's `deploy-pr-preview` paragraph is rewritten to match the new graph.
* `idf_app/tools/test_check_release_config.sh` — **executable**: six cases covering the new flag positively and negatively, its vacuous-pass guard, and a malformed-row guard. A later review remediation adds one more case proving that a malformed config still emits log-derived `UNDEFINED` diagnostics without echoing an assigned value. The host suite is therefore **84 cases in this tree**, where the four earlier recorded runs observed 77 and the preview/absence-floor runs observed 83. As with the CMake suite's `13/13` and `17/17`, every earlier figure in the tables is left as recorded: it is what that run actually reported at that SHA.
* `idf_app/cmake/rk_release_config.cmake` — **comment-only**: the maintainer-facing enforcement-ceiling comment now describes the same three-job publication boundary as the workflow. No CMake byte executed by the gate changes.
* `docs/dev/KCONFIG.md` and this record — documentation.
* `idf_app/tools/check_release_config.py` and `idf_app/sdkconfig.defaults` — **unchanged by these two adjustments**, and that is the load-bearing part of what survives. The checker's semantics, its invariant set and the build's inputs are untouched, so the resolved configuration, `config_digest sha256:d14a7cf7be5fe6978a4455267f8eeca45860864ccefa8af68a4f6d1385a41589`, the `11 of 11` invariant count and the SIZE binary figures all still describe this tree. Earlier revisions of this section also recorded comment-only rewrites in both files (the `ESPTOOLPY_FLASHSIZE` stance and the accepted-set pointer); those remain comment-only.

**A later CodeRabbit remediation changes executable bytes again, so the `a9e6fd3` evidence is not carried across it.** Commit `52f82b82c64ddb2e1fc5c63eb3e604be876eb3e1` makes log-derived `UNDEFINED` symbols visible even when the effective config is unreadable or malformed, while preserving `NOCONFIG` exit precedence. Its new host fixture drives that combined failure, requires both tokens, and rejects echoing the assigned value. The same commit adds a ten-minute ceiling to `release-config-fixtures` and disables checkout credential persistence in both review-remediated jobs (`release-config-fixtures` and `build-stale-config`); `build-stale-config` retains its existing 60-minute ceiling. Commit `bc1870931f3fdb697c72a9157513cbc12b94039b` is an empty validation-trigger commit over exactly that tree. Run `30523566990` is therefore exact-tree evidence for the remediation rather than a carry-forward from the 83-case tree. The exact-head CodeRabbit re-review was rate-limited; this record claims only that the two earlier actionable findings were fixed and that the remediated tree passed the gates below.

That bounded prediction is now discharged with exact-SHA container evidence:

| Run | Exact head | Executable relationship | Fixtures | Required observations |
|---|---|---|---|---|
| [30515747808](https://github.com/muness/roon-knob/actions/runs/30515747808) | `17edfc772383be1a4436d6286fed3096a4b2eb2c` | predecessor before the preview/absence adjustment | 77/77 host, 23/23 CMake | all proof jobs green; prior host assertion shape |
| [30518128099](https://github.com/muness/roon-knob/actions/runs/30518128099) | `aee0a786fb9f470d88ed046ef5e4f8a694308ce5` | first executable head with preview parity and the absence floor | **83/83 host, 23/23 CMake** | `build-idf` emitted `RK-RELCFG-ASSERT-OK: enforced=true verdict=pass digest-matched no-absent-satisfied`; all three proof jobs and preview green |
| [30519518551](https://github.com/muness/roon-knob/actions/runs/30519518551) | `a9e6fd329a3520bd548b37b981d1ae0c78be6791` | documentation-only over `aee0a78` | **83/83 host, 23/23 CMake** | the same assertion token and green proof/preview graph reproduced |
| [30523566990](https://github.com/muness/roon-knob/actions/runs/30523566990) | `bc1870931f3fdb697c72a9157513cbc12b94039b` | exact tree carrying the diagnostics and workflow-hardening remediation at `52f82b8` | **84/84 host, 23/23 CMake** | the combined `NOCONFIG`/log-`UNDEFINED` regression passed; `build-idf` emitted the same assertion token; the ON/OFF stale-config pair resolved the same digest; all three proof jobs and preview green |

The preview/absence-floor evidence stands on `aee0a78` itself rather than being transferred from an earlier tree: the job graph, `build-idf` host assertion, 83-case suite and `--forbid-absent-satisfied` implementation all ran in container CI, and `a9e6fd3` reproduced them from a byte-identical executable tree. The later diagnostics remediation stands independently on `bc18709`: its 84-case suite and unchanged 23-case CMake suite ran with the enforced build and the same-digest ON/OFF causal pair. The preview edge can increase latency because the dependent waits for the maximum of three jobs. It added zero observed wait in the first two schedules because `build-stale-config` finished before `build-idf`; in run `30520392120` it delayed preview eligibility by roughly five seconds, so zero delay is not a general property. The cost is both variance and failure coupling. No run is claimed for the documentation-only commit carrying this paragraph; none is needed to support a new behaviour claim, because it changes no executable or configuration input.

**Supersedes (partially):** the release-safety role of the `sdkconfig.defaults` staleness guard from closed #149

## Context

The original task was "add the missing performance-optimization line to `sdkconfig.defaults`."
That framing is wrong in a way worth writing down, because it will recur.

`sdkconfig.defaults` is an **input**, not a record of what was built. It can be:

* **stale** — an existing `idf_app/sdkconfig` takes precedence, so a newly added default is silently ignored (this is exactly what #149 was created for);
* **undefined** — a symbol that no longer exists is accepted, ignored, and warned about in a line nobody reads;
* **overridden** — `sdkconfig.local` (wired by `scripts/install.sh`, which exports `SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.local"`), the `SDKCONFIG_DEFAULTS` environment variable, and `-D` cache variables all change the outcome. (`idf_app/sdkconfig.override` exists in the tree but is **not** a wired override path: nothing in this repo passes it to IDF and IDF does not read it on its own. It is named here only to correct an earlier draft of this record that listed it as one. It was not read, modified, or staged by this work.)
* **incomplete** — most of the resolved configuration comes from IDF's own Kconfig defaults, which change with the SDK.

So the file cannot prove what the compiler actually used. Adding one line to it would have produced a release build that *probably* was optimized. IDF, however, writes the fully resolved configuration to `build/config/sdkconfig.json` during `project()`. That artifact **can** prove it.

The reframe: **enforce a small release policy against IDF's generated effective configuration**, and treat committed defaults as merely one input to it.

## Decision

1. A dependency-free checker, `idf_app/tools/check_release_config.py`, validates declared release invariants against an explicitly named `sdkconfig.json`, emits stable `RK-RELCFG-*` tokens and a JSON report, and identifies its own failure modes rather than passing silently.
2. `idf_app/cmake/rk_release_config.cmake`, included **after** `project()`, runs the checker at configure time, always writes the report, always prints a banner, and defers failure via `fail_at_build_time()`.
3. CI forces enforcement **on** through the ci-action's `command:` input and then **asserts the report on the host**, including that the build log the undefined-symbol scan read is the one the gate wrote.
4. Undefined-symbol detection is **delegated to kconfgen**, not reimplemented — and a requested-but-missing verdict is a failure, not silence.
5. Negative proof lives in committed fixtures plus exactly one integration build, and both **gate** shipping via `release`'s `needs:` rather than merely reporting.
6. #149's guard is restored, with its limited local purpose documented rather than overstated.

## The measurement that chose the optimization mode

#202's soft constraint was explicit: the optimized mode must be **selected from measurement**, not inherited from the v4 branch. Inheriting is what produced the original bug.

All three modes were built on **CI's own toolchain**, in the same container image the release build uses, from three isolated build directories with three isolated `sdkconfig` files and explicit `-DSDKCONFIG_DEFAULTS` per build. Run: GitHub Actions `30498910795`, pull request #204 (draft, measurement only).

### Provenance

| Item | Value |
|---|---|
| Image | `espressif/idf:release-v5.4` (mutable tag — see the ceiling below) |
| `idf.py --version` | `ESP-IDF v5.4.4-1000-g8543b57cf15` |
| IDF commit | `8543b57cf15853fd8648cb12e63a1b0e7ea4075b` |
| Compiler | `xtensa-esp-elf-gcc (crosstool-NG esp-14.2.0_20260121) 14.2.0` |
| `esp-idf-kconfig` | 2.5.4 |
| CMake / Ninja / Python | 3.30.2 / 1.11.1 / 3.12.3 |
| Target | `esp32s3` (passed as `IDF_TARGET` per build; `set-target` deliberately not used) |
| Source | PR #204 merge commit `55e9d5d3e25ffb9c0684d30840db586b2b330f99`; attributable branch head `82f36a62b04bc8623d3ce93516e65d03f8a2fd0b` |

### Results

| Mode | Link | `roon_knob.bin` | % of `0x280000` app slot | Flash code | Flash data | Static DIRAM | DIRAM free | IRAM | Effective symbol |
|---|---|---|---|---|---|---|---|---|---|
| DEBUG (`-Og`) | ok | 1 761 952 B | 67.21 % | 1 099 598 | 523 160 | 222 931 (65.23 %) | 118 829 | 16 383 | `COMPILER_OPTIMIZATION_DEBUG=true` |
| **SIZE (`-Os`)** | **ok** | **1 613 984 B** | **61.57 %** | **974 124** | **511 104** | **212 259 (62.11 %)** | **129 501** | **16 383** | `COMPILER_OPTIMIZATION_SIZE=true` |
| PERF (`-O2`) | ok | 1 765 520 B | 67.35 % | 1 112 020 | 518 268 | 219 007 (64.08 %) | 122 753 | 16 383 | `COMPILER_OPTIMIZATION_PERF=true` |

Each run's effective mode was read back from that build's own `build/config/sdkconfig.json`, which is how we know the fragment reached the resolved configuration rather than merely the defaults file.

### Decision rule and outcome

The rule, applied in order: (1) the mode must link with non-zero static DRAM headroom; (2) prefer the smallest image, because the app partition is a fixed `0x280000` slot and OTA needs two of them; (3) break ties on static DIRAM headroom, because DRAM exhaustion is the failure mode this device actually hits.

All three modes link. **SIZE wins outright**: smallest image (−147 968 B vs DEBUG, −151 536 B vs PERF) *and* lowest static DIRAM (−10 672 B vs DEBUG, −6 748 B vs PERF), at identical IRAM. No trade-off had to be adjudicated, which is a stronger result than the rule anticipated.

Note also what PERF — the mode the original one-line framing would have added — actually measured against DEBUG, stated exactly, because an earlier revision of this paragraph called PERF "larger and hungrier than DEBUG" and the second half of that is contradicted by the table three lines above it:

* PERF's **image is larger** than DEBUG's: 1 765 520 B vs 1 761 952 B, **+3 568 B**.
* PERF's **static DIRAM is lower** than DEBUG's: 219 007 B vs 222 931 B, **−3 924 B** — so PERF is *less* memory-hungry than DEBUG, on the very metric this decision rule names as the tiebreaker because DRAM exhaustion is the failure mode this device actually hits. "Hungrier" was wrong.

The one-line PERF prescription was still the wrong prescription, and the accurate reason is simpler than the one that was written: **SIZE beats PERF on both ranked metrics** — 151 536 B smaller and 6 748 B lower on static DIRAM — so adopting PERF would have shipped the worse of the two optimized modes. It would not have shipped something worse than DEBUG in every respect. That is a concrete example of why the measurement was made a precondition, and correcting it here is also an example of why a claim adjacent to its own table still has to be checked against it.

The static-only decision therefore initially put `CONFIG_COMPILER_OPTIMIZATION_SIZE=y` in `sdkconfig.defaults`. The 2026-07-30 hardware amendment above supersedes that runtime choice: `sdkconfig.defaults` now carries `CONFIG_COMPILER_OPTIMIZATION_PERF=y`, pending the same hardware checks. The recorded SIZE builds and their exact-SHA evidence remain historical observations and are not rewritten as PERF results.

### The limit of this measurement — read this before quoting "chosen by measurement"

Every metric above is **static**: link success, image bytes, static DIRAM/IRAM. There is **no dynamic datapoint**. `-Og` → `-Os` is a behavioural change on a device whose felt qualities are encoder responsiveness and LVGL redraw smoothness, and nothing here measured either. "Chosen by measurement" must never be read as "chosen by performance measurement."

What makes that acceptable rather than reckless is reversibility: the gate accepts SIZE **or** PERF, so switching *within that pair* is a one-line `sdkconfig.defaults` diff that the gate still checks — no gate, fixture, workflow, or ADR edit required. Reversibility is bounded to that pair by design; a mode outside it is a deliberately more expensive move, described below.

That claim is only true because it was made true. An earlier revision of `build-stale-config` matched the literal `CONFIG_COMPILER_OPTIMIZATION_SIZE=y` line when seeding its stale tree, so flipping the default to PERF would have failed that job at its seed step with `found 0` — and since the job gates tagging, the "one-line" switch would silently have been a two-place edit that blocks a release. The seed now matches whichever release mode is selected (`^CONFIG_COMPILER_OPTIMIZATION_(SIZE|PERF)=y$`) while keeping the `exactly one` tripwire, so two selected modes or none still stops the job loudly. Verified against synthetic SIZE-selected and PERF-selected defaults, and against both tripwire cases.

**#203's combined hardware test must therefore include, as named items:**

1. **Encoder input latency** at `-Os` — rotation-to-visible-response, including fast continuous rotation.
2. **LVGL redraw** — artwork transitions and screen changes; watch for dropped frames or tearing that `-Og` did not show.
3. **Battery brownout behaviour at `-Os`** against the level-4 / 2.50 V tuning, on battery, including Wi-Fi association inrush (the condition that made level 7 unusable).
4. **Boot and OTA from a prior release** built at `-Og`, to confirm the mode change does not interact with the update path.

**If any of those regress, the remedy is staged, and no stage disables enforcement.** An earlier revision of this record named the remedy as *the* one-line SIZE→PERF switch, flatly. That is right about the first move and silent about the case where it does not work, which is exactly the case where someone reaches for the escape hatch:

1. **Try the alternative optimized mode first.** Switch `sdkconfig.defaults` to PERF (costing ~151 KB of image and ~7 KB of DIRAM against SIZE, per the table above), re-run the hardware items, and record the result. The gate accepts SIZE or PERF, so this stage is the one-line diff described above and the gate keeps checking throughout.
2. **If *both* optimized modes regress, amend the gate explicitly — reviewed and recorded.** The invariant forbids DEBUG and NONE, so a mode outside the SIZE/PERF pair cannot be adopted by editing defaults alone; it requires changing what the gate accepts. That change is legitimate when hardware evidence justifies it, and it goes through the same mechanism as a reviewed invariant amendment under "The permitted response to upstream drift": establish and record what regressed and why the chosen mode is the right answer *for this device*, amend the invariant to admit that mode, and move every place that names the accepted set with it — enumerated below, because an earlier revision of this record priced it at fewer places than it costs. It is a review, not a unilateral unblock.
3. **Never silently disable enforcement.** The prohibited list under "The permitted response to upstream drift" applies unchanged here — no `RK_ENFORCE_RELEASE_CONFIG=OFF` in CI, no `continue-on-error`, no deleting the gate call, the host assertion or the log scan, no blanket allowlist. A recorded amendment is more expensive than a flipped flag precisely because it leaves a decision a later reader can find and disagree with; a disabled gate leaves a green build that means nothing.

**What stage 2 actually costs, so nobody discovers it mid-regression.** It is the multi-place edit that "Why the gate does not pin SIZE" deliberately avoided for the SIZE↔PERF case. Two earlier revisions of this record got the price wrong in the same direction: the first said three places (the checker's accepted set, the fixtures that pin it, and this record), the second said six and still missed a location. So the surface is given below **as something to re-derive rather than a number to trust** — a count is exactly the claim that rots silently as the tree grows, and this record's own standard is that a claim which cannot be checked should not be made. Re-derive it before starting:

```bash
grep -rnE "SIZE or PERF|SIZE/PERF|either SIZE|COMPILER_OPTIMIZATION_(SIZE|PERF|DEBUG|NONE)" \
  --include='*.md' --include='*.py' --include='*.cmake' --include='*.yml' \
  --include='*.sh' --include='sdkconfig.defaults' .
```

Note `-rnE` and the symbol alternation: a prose-only pattern (`"SIZE or PERF"` and friends) misses `CHOICE_INVARIANT`'s `allowed`/`rejected` lists entirely, because those name the symbols and never the prose — so the *most* load-bearing location is the first one a careless grep drops. It also deliberately matches the fixture-and-suite references and `build-stale-config`'s regressed-mode lines, which are the bulk of the real work.

What that finds in this tree, and why each one has to move:

* the **accepted set** in `idf_app/tools/check_release_config.py` — all three parts of `CHOICE_INVARIANT`, not one: `allowed` and `rejected` (admitting DEBUG or NONE means moving a symbol from the second list into the first, not merely extending the first) **and** the `why` string beside them, `"release builds must be optimized; exactly one of SIZE/PERF, never DEBUG/NONE"`, which is emitted into the report and into the violation message and would otherwise keep asserting the old pair from inside the evidence the gate publishes;
* the **fixtures**, and by **inversion** rather than by edit. `opt_debug.json` and `opt_none.json` exist to assert `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG` / `_NONE`, so admitting one of those modes turns that mode's own negative fixture into a compliant config. The case has to be re-pointed at a mode that is still rejected, not re-valued — the same trap the flash-size section records for `wrong_flashsize.json`. `opt_debug.json` is also the stand-in *violating* config elsewhere — 8 references in `tools/test_check_release_config.sh` (report, log, `--enforced no` and host-asserter paths) and 5 in `tools/test_release_config_cmake.sh` — every one of which needs a config that still violates something;
* `.github/workflows/docker.yml`'s **`build-stale-config` regression**, which is more than the seed regex. The seed matches `^CONFIG_COMPILER_OPTIMIZATION_(SIZE|PERF)=y$`, writes `CONFIG_COMPILER_OPTIMIZATION_DEBUG=y` as the regression, and the job asserts the exact token `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG`. If DEBUG becomes an accepted mode, the job's premise is gone — its seeded tree is no longer a violating tree — so both the accepted-mode pattern and the regressed mode must move. It fails loudly rather than passing vacuously (run 1 requires step outcome `failure`, and a compliant seed would build), which is the right failure; the hazard is that the cheapest-looking repair is relaxing that assertion instead of re-pointing the regression, and relaxing it is on the prohibited list;
* **`docker.yml` again, in a different job** — the mode-resolution comment in `build-idf`'s run-summary step, which explains that "the invariant deliberately accepts SIZE or PERF, so `verdict: pass` does not say WHICH mode shipped" and is why the summary reads the mode from the report's `invariants` rows instead of the defaults file. This is the location the previous six-place count missed, and it is worth naming as the reason the surface is now grep-derived: it is in the same file as the bullet above but in an unrelated job, so an enumeration written per-file rather than per-location walks straight past it. The rationale survives a change of accepted set — a summary must still not infer the mode from an input — but the sentence naming the pair does not;
* the **explanatory comment in `idf_app/sdkconfig.defaults`** above the optimization line, which states which modes are accepted and rejected and points at `tools/check_release_config.py` as the file that owns that set;
* the **invariant text in `docs/dev/KCONFIG.md`**, which names the same pair and tells a developer that switching *within* it needs no change to the gate, its fixtures, the workflow or this record — the version a developer actually reads, since `CLAUDE.md` routes build/config questions there;
* this record.

That cost is the point, and stating it *re-derivably* is part of the point: an undercount reads as "cheap", stage 2 is meant to be expensive enough that it leaves a decision behind, and two revisions of this record have now undercounted it — which is the argument for the grep above rather than a third number. And because #189's release-blocking checklist blocks **tagging**, an unresolved hardware regression stops the release on its own; it does not need an unenforced build to be caught, and must not be absorbed by one.

### Why the gate does not pin SIZE

The invariant is deliberately looser than the measurement: **exactly one of `COMPILER_OPTIMIZATION_SIZE` / `COMPILER_OPTIMIZATION_PERF` true, and `COMPILER_OPTIMIZATION_DEBUG` / `COMPILER_OPTIMIZATION_NONE` false.**

The gate's job is "this build is optimized," which is the property that was actually violated. Encoding "SIZE specifically" would mean a hardware-driven SIZE↔PERF switch in #203 requires editing every place that names the accepted set — the surface enumerated and grep-derived under stage 2 above, which two earlier revisions of this record priced at three places and then six — to say one thing. The measured choice lives in `sdkconfig.defaults`, where changing it is a one-line diff that the gate still checks.

## Invariants asserted

Every symbol name and expected default below was verified **against IDF commit `8543b57cf15`** — the exact tree CI built with — not against a local checkout. References are given as *symbol declarations in named files*, deliberately **not** as `Kconfig:NNN` line anchors: those drift with every SDK bump and were already stale against a locally installed v5.5.3 within a day of being written. Locate with `grep -rn "^ *config <SYMBOL>$" $IDF_PATH/components/`.

| Invariant | Expected | Why | Declared in |
|---|---|---|---|
| `COMPILER_OPTIMIZATION` choice | exactly one of SIZE/PERF; never DEBUG/NONE | the release must be optimized | root `Kconfig`, `choice COMPILER_OPTIMIZATION` |
| `COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE` | true | OTA field devices, no crash-reporting channel; pins IDF's own default | root `Kconfig`, `choice COMPILER_OPTIMIZATION_ASSERTION_LEVEL` (first member = default) |
| `SPIRAM` | true | artwork RGB565 buffers do not fit without PSRAM | `esp_psram/esp32s3/Kconfig.spiram` |
| `PARTITION_TABLE_CUSTOM` | true | OTA layout comes from `partitions.csv` | `partition_table/Kconfig.projbuild` |
| `HEAP_POISONING_DISABLED` | true | debug-only cost; IDF default | `heap/Kconfig`, `choice HEAP_CORRUPTION_DETECTION` (`default HEAP_POISONING_DISABLED`) |
| `HEAP_TRACING_OFF` | true | permanent IRAM + malloc overhead; IDF default | `heap/Kconfig`, `choice HEAP_TRACING_DEST` (`default HEAP_TRACING_OFF`) |
| `COMPILER_DUMP_RTL_FILES` | false | debug-only compiler output | root `Kconfig` |
| `ESP_DEBUG_STUBS_ENABLE` | false | debug-only on-target stubs | `esp_system/Kconfig` — see the note below; its default expression is **not** what an earlier revision of this record claimed |
| `ESP_SYSTEM_PANIC_GDBSTUB` | false | a field device must reboot, not wait for gdb | `esp_system/Kconfig`, `choice ESP_SYSTEM_PANIC` (non-default member) |
| `FREERTOS_USE_TRACE_FACILITY` | false | debug-only scheduler bookkeeping | `freertos/Kconfig` (`default n`; selected only by `FREERTOS_GENERATE_RUN_TIME_STATS`, itself `default n`) |
| `ESPTOOLPY_FLASHSIZE` | `"16MB"` | must match what the committed defaults declare | `esptool_py/Kconfig.projbuild` (string, defaulted from the `ESPTOOLPY_FLASHSIZE_*` choice) |

**`ESP_DEBUG_STUBS_ENABLE`, stated conservatively.** An earlier revision said its default "tracks the debug optimization level, so choosing SIZE satisfies this as a side effect." That reasoning does not hold. At commit `8543b57cf15` the declaration reads `default COMPILER_OPTIMIZATION_LEVEL_DEBUG` — and `COMPILER_OPTIMIZATION_LEVEL_DEBUG` is **not a declared symbol** anywhere we inspected at that commit (root `Kconfig`, `esp_system/Kconfig`, `esp_common/Kconfig`, `freertos`, `heap`, `esp_psram`, `partition_table`, `esptool_py`). It appears only in the root `sdkconfig.rename` as a legacy input alias mapping `CONFIG_COMPILER_OPTIMIZATION_LEVEL_DEBUG → CONFIG_COMPILER_OPTIMIZATION_DEBUG`. Rename files translate *sdkconfig inputs*; they do not resolve names inside Kconfig expressions. So what the source says is: the default expression references a legacy name that is not a symbol in this tree, which in kconfiglib makes the default evaluate to `n` irrespective of the optimization choice.

Either way the invariant is satisfied and cannot false-positive — the expectation is `false`, and absence is treated as satisfied for `false`-expected symbols — but the *reason* is "the default is unconditionally n", not "SIZE implies it".

**Now observed, not only reasoned.** Run `30506101326`'s artifact report records `ESP_DEBUG_STUBS_ENABLE` as **`false`, status `pass`**, present in the resolved configuration rather than absent. So the source reading and the resolved value agree: the symbol exists in `sdkconfig.json`, and it is off. The source reasoning above is retained because it explains *why* — an undeclared legacy name in the default expression, not the optimization choice — which is what a future maintainer needs if IDF ever declares `COMPILER_OPTIMIZATION_LEVEL_DEBUG` for real.

**Nothing was written into `sdkconfig.defaults` merely because it happens to be true today.** The "inherited IDF default" symbols are checker assertions, not new default lines. The only line added to that file is the measured optimization choice.

### Why inherited defaults are asserted but not declared — and what a failure means

Four of these invariants (`COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE`, `HEAP_POISONING_DISABLED`, `HEAP_TRACING_OFF`, and the `false` debug symbols) pin values the repo never writes down, over a **mutable** `release-v5.4` tag. That combination is a deliberate choice, and the objection to it is fair enough to answer explicitly rather than leave implied.

Writing those values into `sdkconfig.defaults` was **excluded by the accepted phase-1 adjustment** ("nothing is written into `sdkconfig.defaults` merely because it is true today"), for a good reason: a committed line asserting an IDF default is indistinguishable, six months later, from a deliberate project decision, and it silences precisely the signal we want. Pinning the SDK to an immutable tag was **also excluded** — all SDK version selection and pinning is #183, and #202 changing `esp_idf_version` would quietly take over another issue's one-way door.

So the intended semantics are: **an invariant failure under a moved `release-v5.4` is drift detection working, not the gate malfunctioning.**

### The permitted response to upstream drift — and the four that are not

This is written out as a procedure rather than a sentence because it is the moment the design is most likely to be defeated, and it will be met by whoever is mid-way through unrelated work when an upstream tag moves. The red build will look like an obstacle rather than a signal, and the cheapest-looking fixes are all in the prohibited list.

When `build-idf` goes red naming a symbol, the permitted path is, in order:

1. **Remeasure and review.** Establish what the resolved value actually is now and why it changed — read the symbol's declaration at the IDF commit the container resolved to, not a local checkout. Drift, a genuine upstream policy change, and a defect in our own invariant are three different findings and the response differs for each.
2. **Decide whether the new upstream default is right for this device.** This is a judgement about the product, not about CI. It requires review; it is not a unilateral unblock.
3. Then exactly one of:
   * **Amend the invariant** to the reviewed value, recording *why* the new value is correct for this device — a reviewed amendment, not a silent edit; or
   * **Declare the value explicitly** in `sdkconfig.defaults`, which converts an inherited IDF default into a project decision, again recording why. Note this is the one sanctioned exception to "nothing is written into `sdkconfig.defaults` merely because it is true today" — here the value is being written down *because it was reviewed and chosen*, which is the opposite case.

Either outcome leaves the gate enforcing and leaves a record of a decision having been made. Both are cheap. Neither is a bypass.

**What must never happen, stated as a closed list**, because each of these converts a one-time review into a permanent silent hole:

* **Never set `RK_ENFORCE_RELEASE_CONFIG=OFF` in CI.** The hatch is local-only by design. In CI it would leave a job that still runs, still prints, still writes a report and still looks green while enforcing nothing — the most expensive possible failure, because it is indistinguishable from success at a glance.
* **Never add `continue-on-error`** to the gate job or any of its steps. It preserves the appearance of a check while removing its only consequence.
* **Never delete the step** — the gate call, the host assertion, or the log scan. The host assertion cannot catch its own deletion (see the ceilings below), so this is the one edit the design is structurally blind to.
* **Never add a blanket allowlist** — a "known failures" list, a skipped-symbols set, or a wildcard exemption. A per-symbol reviewed amendment is the sanctioned mechanism precisely because it forces the review the allowlist skips.

The cost of this design is a possible red build on an unrelated PR; the benefit is that a silent upstream behaviour change cannot reach users' devices unnoticed. That trade was made knowingly. Note that the prohibitions above are **conventions, not enforced controls** — nothing in this tree prevents a `continue-on-error` from being added, and under current branch protection nothing prevents it from being merged either (see the narrowing under "Enforcement ceilings"). They hold because they are written down and reviewed, which is why they are written down here in the imperative rather than implied.

Immutable SDK selection remains **#183**. When it lands, this whole class of failure becomes a deliberate, reviewed event at version-bump time instead of an ambient risk — which is the right place for it.

### Absence is directional, and that is deliberate

IDF omits a symbol from `sdkconfig.json` when it is not written out, so "key missing" is ambiguous in general but unambiguous per direction:

* expected **true** and absent → **violation**. Not written out means not enabled.
* expected **false** and absent → **satisfied**. Same reasoning, opposite sign.
* the **entire optimization choice family** absent → `RK-RELCFG-UNDEFINED` (exit 4). That is not a configuration error; it means the symbol names moved out from under the checker, and it must not read as a pass.

This is what keeps "absent ≠ pass" honest without manufacturing false positives out of IDF's own visibility semantics.

**Both single-symbol directions have a known attribution limit, now tracked rather than merely tolerated.** The rules above are right about *failing closed* and imprecise about *why* a build failed or passed, because absence has two possible causes — the value really is off, or the symbol left the SDK schema — and neither bullet distinguishes them:

* An absent **required-true** symbol fails as `RK-RELCFG-VIOLATION` with a configuration rationale, which sends a maintainer to look at configuration when the actual event may be an upstream rename. Attributing that as schema drift instead is [**#209**](https://github.com/muness/roon-knob/issues/209) (*Attribute missing positive release invariants as schema drift*). It changes attribution, not the verdict: absent-required-true must keep failing closed.
* An absent **expected-false** symbol is treated as satisfied, so a symbol that disappears upstream silently stops being checked at all — coverage shrinking without a signal. That is [**#206**](https://github.com/muness/roon-knob/issues/206) (*Fail closed when negative release invariants disappear*), and it is the more dangerous of the two, because its failure mode is green.

Neither is a defect in what #202 enforces, and neither is deferred because it is hard: the honest fix for both needs active Kconfig/schema evidence rather than an inference from absence in `sdkconfig.json`, which is a different mechanism than this checker has. They are recorded here so the third bullet's family-level `UNDEFINED` is not misread as covering the single-symbol cases too.

**The green failure mode is nonetheless closed for *this* build, from the caller's side.** The report records each row's status, and the release config as it resolves today reports **zero** `absent_satisfied` rows — every negative invariant is written out as an explicit `false`. That shape is observed in run `30512450762`'s `esp32s3-firmware` report: all 11 rows are `pass`, with zero `absent_satisfied`, on the same unchanged checker/defaults and `config_digest sha256:d14a7cf7be5fe6978a4455267f8eeca45860864ccefa8af68a4f6d1385a41589` recorded above. That is therefore a fact about this build that CI can pin: `build-idf`'s host assertion passes `--forbid-absent-satisfied`, which fails if any `invariants[].status` is `absent_satisfied`. If a future IDF bump drops one of those symbols, the job turns red — and with it both `release` and `deploy-pr-preview`, which need it — instead of quietly checking one invariant fewer. Read the boundary precisely: this is an **assertion the auditor owns**, in the same family as `--expect-log-marker` and for the same reason (a report-sourced version would have nothing to iterate over in exactly the case it must catch). It changes **no checker semantics** — the same config still exits 0 with `RK-RELCFG-OK` and the same report still says `verdict: pass`, both pinned by fixtures. It also cannot distinguish a legitimately hidden/off symbol from one removed or renamed upstream, so it may red on either cause; that honest attribution limit is why #206 still needs active Kconfig evidence. It buys a signal, not the model.

The same principle governs a **requested but unreadable log**: `--log` is how kconfgen's undefined-symbol verdict reaches the checker, so an absent, unreadable or empty log is `RK-RELCFG-NOLOG` (exit 5), never silence. Passing no `--log` is different and legitimate — the determination is simply not requested, which is the configure-time gate's case — and never fails on that basis. In CI the log is additionally required to contain `RK-RELCFG-VERDICT:`, which proves the log read is the one the gate itself wrote rather than some other file that happened to exist.

And the same principle again for the **report**: a `--report` that was requested but could not be written is `RK-RELCFG-NOREPORT` (exit 6), and the `OK` token is withdrawn so no passing verdict can be printed after failing to produce the artifact CI audits. A determination that cannot be recorded is not a trustworthy pass. The report is written atomically (temp file plus rename) so a failure partway through cannot leave a truncated file for a later reader to parse as a pass. Passing no `--report` is, again, different and legitimate.

That leaves `--defaults` as the one deliberately non-failing channel: it is provenance only, never parsed, so nothing is inferred from its absence and it cannot make any determination fail open. Its entries record `readable` so a mis-wired path is still visible. This is a decision, not an oversight, and it is **not** promoted to an enforced assertion: doing so would make the gate depend on a file it deliberately does not trust, which is the opposite of the reframe.

### Absent flag vs empty value

One more shape of the same fail-open, closed in the same family: an **explicitly supplied empty value** is a wiring bug, not a request for nothing. `--report ""` was falsy, so no report was requested, none was written, and the checker printed `RK-RELCFG-OK` and exited 0 — reachable in CI simply by deleting or reordering the step that defines the path variable, since `bash -e` without `-u` leaves it empty. Empty values for `--config`, `--report`, `--log`, `--log-must-contain` and `--defaults` are now `RK-RELCFG-USAGE` (exit 64), as is `--log-must-contain` with no non-empty `--log` (which could only pass vacuously). Omitting a flag entirely remains legitimate and means "not requested" — that is the configure-time gate's case for `--log`. The host asserter applies the same rule to `--report`, `--config` and `--expect-log-marker`.

### Token precedence

When several conditions hold at once, **every** applicable token is printed and recorded in the report; only the exit code is single-valued, resolved as:

```
NOCONFIG (3)  >  NOREPORT (6)  >  NOLOG (5)  >  UNDEFINED (4)  >  VIOLATION (2)
```

The first three mean *no trustworthy determination was made, or none could be recorded*, and must outrank a mere policy violation — reporting "the optimization mode is wrong" when the real problem is "the config could not be parsed" would send the reader to the wrong place. Nothing is hidden by the precedence: a config that is both undefined and violating exits 4 while its violation rows remain visible in the report's `invariants`, and fixtures assert exactly that for every ordering.

This precedence is a contract shared by two independently maintained places — the checker's exit codes and the gate's exit-code-keyed selection of the failure headline (see the Status block). Today's cases are pinned by fixtures; keeping the two lists synchronized as either side changes is tracked as [**#208**](https://github.com/muness/roon-knob/issues/208) (*Detect checker/gate token-contract drift in release CI*). That is contract-integrity coverage: it must not change whether a compliant or violating build passes.

### Not asserted here

Image size, DRAM headroom thresholds, partition geometry, the merged-image header, `--flash-size` direction, `PROJECT_VER` binary inspection, and toolchain identity. Those belong to #203 / #183.

## Undefined defaults: delegated to kconfgen, not reimplemented

`esp-idf-kconfig` already decides "this assignment names a symbol that does not exist," on the exact input file, with correct alias/rename semantics, and prints:

```
warning: unknown kconfig symbol 'SYM' assigned to 'VALUE' in FILE
```

An earlier review proposed reconstructing that determination from three build artifacts (`sdkconfig.json` + `sdkconfig.h` + `kconfig_menus.json`) with its own exit code. That was **rejected**, and the record is corrected here because it is load-bearing for anyone revisiting this:

* The string is emitted by **kconfgen** (`kconfgen/core.py`, defaults-loading path), **not** kconfiglib.
* It is **not version-fragile** across the range `release-v5.4` can resolve to: `espidf.constraints.v5.4.txt` pins `esp-idf-kconfig>=2.0.2,<3.0.0`, and the format string is byte-identical in all eleven in-range 2.x releases (2.0.2 → 2.5.4).
* `ignore_build_warnings.txt` is **live suppression that IDF's own CI depends on**, not legacy residue.
* kconfgen's verdict is **visibility-independent and alias-correct**: `missing_syms` is appended only for genuinely undefined symbols (`not sym.nodes`), and renames are excluded by consulting the `sdkconfig.rename` files directly.
* **#202's acceptance criterion as originally worded was accurate.** The "correction" away from it was the error.

So the checker **consumes** that line (`--log`) and never re-derives it. Three consequences worth stating:

* **The value is never captured.** The regex stops before the assigned value, because `sdkconfig.defaults` historically carried a credential and a gate must not become an exfiltration path. A fixture asserts the value never appears in output — including on the new `RK-RELCFG-NOLOG` paths, where only the path, a byte count and marker booleans are ever reported, never log content.
* **This layer is enforced in CI, not at configure time.** `kconfig.cmake` does not capture kconfgen's stdout, so the configure-time run's warnings are not available to the checker without re-invoking kconfgen. Rather than re-run it with reconstructed arguments, CI tees the build log and scans it. Locally, an undefined default warns (kconfgen's own output) but does not fail. That is an honest ceiling, not an oversight.
* **Delegation must not become abdication.** Consuming someone else's verdict introduces a failure mode reimplementation does not have: the verdict can simply fail to arrive. So requesting a log via `--log` makes its existence, non-emptiness and identity part of the contract — absent, unreadable, empty, or missing the `RK-RELCFG-VERDICT:` marker all produce `RK-RELCFG-NOLOG` (exit 5) and a `verdict:"fail"` report. This closed a real fail-open hole: the same invocation with a missing log previously exited 0 with `RK-RELCFG-OK`, so a renamed or dropped `tee` would have silently disabled one of #202's own acceptance criteria forever. Fixtures now cover missing, empty, whitespace-only and wrong-log cases, and the host asserter can require the report to *prove* a log was read (`--require-logs-read`).

### Removed lines

Confirmed by kconfgen **in the CI container** (measurement logs, all three builds): exactly four distinct undefined symbols, across five lines, all now removed —

| Old line | Symbol | Note |
|---|---|---|
| 1 | `CONFIG_WIFI_SSID` | never referenced by any source file |
| 2 | `CONFIG_WIFI_PASSWORD` | never referenced; had no effect on any build |
| 3 | `CONFIG_EXAMPLE_IPV6` | leftover from an IDF example |
| 33 | `CONFIG_LWIP_NETIF_HOSTNAME` | not an IDF symbol; hostname comes from `CONFIG_LWIP_LOCAL_HOSTNAME` |
| 85 | `CONFIG_LWIP_NETIF_HOSTNAME` | duplicate of line 33 |

**Retained deliberately:** the four brownout rename aliases (old lines 41–44), as required by the accepted phase-1 adjustment ("retain documented brownout rename aliases unless separately justified"). The rationale needs stating precisely, because an earlier draft of this record got it wrong:

* **The aliases do not carry the tuning.** The canonical `CONFIG_ESP_BROWNOUT_DET_LVL_SEL_4=y` and `CONFIG_ESP_BROWNOUT_DET_LVL=4` lines immediately above them carry the effective level-4 / 2.50 V configuration. The four alias lines resolve to those same two values through `esp_system/sdkconfig.rename` and `sdkconfig.rename.esp32s3`, so as *effective configuration* they are redundant. It is not true that deleting them would lose the tuning.
* **They are retained as transition/history compatibility inputs**, deliberately: they let this defaults file be applied to older trees and older branches (v4 lineage) where the pre-rename symbol names were the real ones, and they document, in-file, which names the tuning has travelled under. Deleting them is a separate, justifiable change — explicitly **out of scope here** and not made.
* **Their present behaviour is tested, not assumed.** `tools/fixtures/kconfgen_rename.log` carries the actual `was replaced with` notices these lines produce in the CI container, and a fixture asserts the checker exits 0 on them. Renames are not unknown symbols.
* **Their eventual promotion to `unknown kconfig symbol` is a deliberate, pre-explained loud signal, not a mystery.** When IDF eventually drops those rename entries, the log gate turns `build-idf` red naming the alias. That is the intended drift alarm: it tells us the compatibility window has closed, at which point the correct response is to delete the four alias lines (the canonical lines already carry the tuning, so the effective configuration does not change) and record that the window closed. This paragraph exists so that whoever sees that red build finds the answer here instead of guessing.

Note on line 2: it is removed because kconfgen proves it is undefined and inert, **not** as credential remediation. The value remains in git history, and history/credential remediation stays out of scope for #202 (private operational track). `idf_app/sdkconfig.override` was not read, modified, or staged.

## Mechanism details worth recording

### `SDKCONFIG_DEFAULTS` precedence — corrected

In `tools/cmake/project.cmake`, `_sdkconfig_defaults` is first seeded from `$ENV{SDKCONFIG_DEFAULTS}` and then, a few lines later, overwritten from the `SDKCONFIG_DEFAULTS` **cache variable** when one is set. So `-DSDKCONFIG_DEFAULTS` **wins over the environment**. (Stated by symbol rather than by line number, per the convention above; locate with `grep -n SDKCONFIG_DEFAULTS $IDF_PATH/tools/cmake/project.cmake`.) This matters twice: it is why the measurement's isolation against `scripts/install.sh`'s exported `sdkconfig.defaults;sdkconfig.local` was real rather than redundant, and it is one of the override paths that makes the defaults file untrustworthy as evidence.

### Why `fail_at_build_time()` and not `FATAL_ERROR`

`FATAL_ERROR` at configure time wedges `idf.py menuconfig`, which is one of the two documented recovery paths — the gate would block the tool you need to fix what it is complaining about. `fail_at_build_time()` instead fails `idf.py build` while leaving `menuconfig` (a non-`ALL` custom target) and `reconfigure` working, and it deletes its own stamp so the next invocation re-evaluates. Both recovery paths — fix it in `menuconfig`, or `rm sdkconfig && idf.py build` — are reachable **without** touching the escape hatch, which is what stops the opt-out from becoming the path of least resistance.

Two hardening requirements at the call site, both verified as real and both implemented:

* `fail_at_build_time(target, message_line0)` takes `message_line0` as a **required positional**, so an empty capture would become a configure-time CMake argument error — the exact hard failure the design avoids. The CMake wiring guarantees a non-empty first line.
* the helper does `foreach(line ${ARGN})`, which **splits on `;`**. The checker strips `;` from its output and the CMake wiring replaces any remaining `;` with `,`.

### Why `command:`-forcing over `extra_docker_args`

`CI` does not cross into the container, so enforcement cannot be inherited from the environment. Putting `-DRK_ENFORCE_RELEASE_CONFIG=ON` on the `idf.py` command line via the action's `command:` input makes the forcing **visible in the workflow diff** — an `-e` in `extra_docker_args` is both easier to miss in review and easier to drop silently.

### Enforcement ceilings — stated plainly

**First, the claim itself needs narrowing.** Earlier revisions of this record — and a comment in the workflow — asserted "CI cannot opt out" without qualification. Stated that broadly it is **not true**, and the qualification matters enough to lead with:

* **What is true:** *within a workflow run*, a `build-idf` job cannot run **unenforced**. Enforcement is forced on the `idf.py` command line and then re-derived from the report on the host, so a flipped flag, a deleted checker or a removed CMake call fails the job. And **publication** is genuinely gated by a real in-repo dependency, not a convention — both consumers now gate on the *same* set; an earlier revision used different sets and blurred that asymmetry:
  * `release` needs **all three** proof jobs: `needs: [build-idf, release-config-fixtures, build-stale-config]`. Any one of them red or skipped stops a firmware asset from being published.
  * `deploy-pr-preview` needs **the same three**: `needs: [build-idf, release-config-fixtures, build-stale-config]`. An earlier revision of this record disclosed an asymmetry here — the preview path needed only the first two, so a red `build-stale-config` alone stopped a release but *not* a publicly flashable preview. That gap is now **closed rather than merely disclosed**: the two lists are identical, and any one of the three proof jobs red or skipped stops both. The trade that produced the asymmetry (not making previews pay for the container negative) does not survive inspection, because `build-stale-config` carries no `if:` guard and therefore already runs in every triggered workflow, including every pull-request run — so requiring it costs a preview *waiting*, not an extra build. That decision is what [**#207**](https://github.com/muness/roon-knob/issues/207) (*Decide whether PR previews require the stale-config blocking proof*) asked for: previews are held to the release standard, deliberately, because a preview is flashed to real hardware by whoever opens the link.
* **What is not true:** that CI blocks **merging**. Measured on `master` at the time of writing, branch protection has `required_status_checks.contexts` **empty** and `checks` **empty**, `required_approving_review_count` **0**, and `enforce_admins` **false**. So no job is a required check, no approval is required, and administrators are not bound by what protection does exist. Merging is effectively **review-only**: a maintainer can merge this PR with every #202 job red, and nothing in the repository can prevent that. Force-pushes and deletions are blocked, which is the protection that *is* in force.

The practical reading: the gate reliably stops a bad configuration from being **published**, and reliably stops a build from **claiming** enforcement it did not have. It does not stop a bad configuration from being **merged**. Those are different guarantees and this record should not have blurred them.

**Making CI a required check is the follow-up, and it is authorization-gated.** Adding `build-idf`, `release-config-fixtures` and `build-stale-config` as required status contexts is the change that would close the merge gap, and it is a **repository-settings** change outside this tree — so it is out of #202's scope by construction, not by preference. It needs an explicit maintainer decision because it is not free: with `build-stale-config` costing a container build on every pull-request workflow run, required checks convert a slow registry or a moved upstream tag into a hard merge block on unrelated PRs, which is exactly the adoption failure this record warns about elsewhere. It is therefore **named here as a follow-up requiring authorization** and deliberately **not** actioned: no repository setting was inspected for the purpose of changing it, and none was changed. It is now tracked as [**#205**](https://github.com/muness/roon-knob/issues/205) (*Require release-integrity checks before merging to master*), which carries the same observed protection baseline recorded above; an earlier revision of this paragraph said no tracking issue had been opened, which was true when written and is not now.

With that narrowing in place, the remaining edges:

1. `fail_at_build_time()` creates an `ALL` target, so the gate fires for **anything that builds `all`** — which includes both `idf.py build` and `idf.py flash`, since the flash action carries `all` in its dependencies. The bypass is narrower than an earlier draft of this record claimed: specifically **`idf.py app` and `idf.py app-flash`**, which build the app target directly. So the dominant local paths *are* covered, and a developer has to reach for a component-specific target to produce a `roon_knob.bin` with the gate never running. Local coverage is broad but not absolute.
2. The host assertion catches a flipped flag, a deleted checker, and a removed CMake call. It does **not** catch **deletion of the assertion step itself**, and nothing in-repo can. Closing that requires branch protection with required checks, which — per the narrowing above — is **not currently configured** and is the named authorization-gated follow-up, tracked as **#205**. Note the two halves of this edge have different consequences today: a deleted assertion step still cannot produce a *published* release, because `release` needs the job and a deleted step does not un-declare the `needs:` edge; but it can produce a *merged* tree, because no check is required to merge.
3. `espressif/idf:release-v5.4` is a **mutable tag**. The measurement table above is attributable to `v5.4.4-1000-g8543b57cf15` / GCC 14.2.0 because those were recorded, but a future run of the same workflow may resolve to a different commit. Recording is not pinning; SDK pinning is #183. An invariant failure after the tag moves is drift detection working as intended — see "Why inherited defaults are asserted but not declared" above for the required response. If the numbers are ever re-derived, re-record the provenance rather than assuming this table still applies.
4. `RK_ENFORCE_RELEASE_CONFIG=OFF` is a CMake **cache** variable: once set in a build tree it persists for every subsequent build in that tree, with no further mention on the command line. The multi-line `*** RELEASE CONFIG INVARIANTS NOT ENFORCED ***` banner is re-emitted on every configure precisely so that state stays visible rather than silently inherited; if you are ever unsure whether a local artifact was gated, grep the build log for that banner.
5. The undefined-symbol layer is enforced **in CI, not at configure time**, because `kconfig.cmake` does not capture kconfgen's stdout for the checker to read. Locally an undefined default warns in kconfgen's own output but does not fail the build. This ceiling was previously worse than stated: a requested log that was absent, empty or unreadable used to be treated as "nothing found" and exit 0, which made the CI half fail *open*. That is now `RK-RELCFG-NOLOG` (exit 5), and CI additionally requires the log to contain `RK-RELCFG-VERDICT:` so a renamed or dropped `tee` cannot pass vacuously.

### Two rules for anything added to `build-idf` later

Both were learned the expensive way and are cheap to honour:

**Host steps may only READ under `idf_app/build/`.** The ESP-IDF container runs as root with no `--user` and the action passes no `-u`, so every path the container creates on the bind mount — including `build/config/` — is root-owned, while host `run:` steps execute as `runner`. An earlier revision of this work pointed the host log-scan `--report` at `idf_app/build/config/`, which no host step can write to. Anything a host step must write belongs in `$RUNNER_TEMP`; the path is defined once into `$GITHUB_ENV` so the writer and the reader cannot drift apart. Note what made this dangerous rather than merely broken: the checker swallowed the write failure and exited 0, so the *following* step failed with "no report … (checker did not run, or CMake call removed)" — a permission problem wearing a deleted-gate costume, whose cheapest-looking fix is deleting the assertion. That is why `RK-RELCFG-NOREPORT` exists.

**An auditor must not take its expectations from the artifact it audits.** `--require-logs-read` originally checked the log-identity marker against the report's own `logs_required_markers`. If a workflow edit drops `--log-must-contain`, that list is empty, the check iterates zero times, and the assertion passes while proving nothing. CI therefore supplies `--expect-log-marker 'RK-RELCFG-VERDICT:'` from the caller side, checked against what the report says it *observed*. Fixtures pin the gap shut, including a report that is internally self-consistent about having read the wrong log.

### `ESPTOOLPY_FLASHSIZE` = 16MB vs the 8MB merge — historical decision trail

**Resolution amendment, 2026-07-30:** the corrected PR #204 candidate uses 16 MB
for both the resolved configuration and `esptool merge-bin`, matching the working
v4 build profile. This removes the in-tree 16/8 MB disagreement. It does not
substitute for #193 hardware identity evidence or #203's physical sustained-boot
test. The discussion below is retained as the decision trail that identified the
disagreement and the full edit surface.

`sdkconfig.defaults` declares `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` while `.github/workflows/docker.yml`'s `esptool merge-bin` step passes `--flash-size 8MB`. That disagreement is real, and it belongs to **#203** (with #193 for hardware identity).

**But "#202 takes no position on 8MB vs 16MB" — how an earlier revision of this record and a comment in the checker put it — describes the tree inaccurately, and the imprecision matters.** #202 does take a position; it is just a narrower one than "16MB is correct". Stated exactly: #202 **pins** the value the committed defaults currently declare, `"16MB"`, as an enforced invariant of the *resolved* configuration, and touches no image header. What it **defers** to #203 is the **correct direction** — whether this device should be 16MB or 8MB. Pinning today's declared value and deferring the decision about it are compatible, and that combination is the whole reframe (see the refusal to downgrade this row, below). What they are not is neutrality: until #203 decides, a build that resolves to any other flash size fails the gate, which is the intended behaviour and not something a reader should have to discover from a red build.

The practical consequence, worth stating because it sets #203's cost: **deciding 8MB is an edit, not merely a decision.** It moves together across the declared value, the checker's expectation, the fixture corpus, the committed suite that pins the violation token, the `merge-bin` invocation, the run-summary caveats, the operator-facing flashing guide and the documentation — enumerated with the re-derivation command under "a coherent multi-place edit" below, which is canonical rather than this sentence. That is the price of pinning an effective value instead of merely recording it, and it is charged deliberately.

**A passing config verdict is not a statement about image geometry, and the run summaries now say so.** This is the one place where a reader could reasonably over-read the gate: a green `RK-RELCFG-OK` with `ESPTOOLPY_FLASHSIZE` passing means *the resolved Kconfig configuration declares 16MB, as the committed defaults do* — it does **not** mean the published image is laid out correctly for the device's flash. The merged image this workflow publishes is still built with `--flash-size 8MB`, and the gate neither reads nor validates the image header. Because the run summary is precisely where someone reconciling #189's checklist will look, and because a table of green fields invites exactly that over-reading, both summary trust points — `build-idf`'s and `release`'s — now carry a **static** caveat stating that the verdict is a configuration verdict, not image geometry, and naming the 16MB/8MB disagreement as open pending #203. The caveat is deliberately static rather than derived from the report: it must appear even when there is no report to derive anything from, so `build-idf`'s failing and missing-report summaries carry it too. A caveat that vanishes on the runs where the reader is most confused would be worse than none.

It was suggested that the invariant should therefore be downgraded to a recorded-only provenance row, on the grounds that the gate should not certify a value the project may change. **Declined, deliberately.** #202's whole reframe is that the *effective* configuration must be pinned to what the project currently declares, so that it cannot drift silently; a value being scheduled for review is not a reason to stop noticing when it changes by accident. Recording-only would mean a stray `sdkconfig` that flipped the flash size to 4MB — which does change partition-table validity — would pass the gate.

**Two narrower alternatives were considered and are rejected for different reasons.** Recording them matters because each is the obvious next suggestion once recorded-only is declined, and each looks like the looseness this record chose elsewhere:

* **A membership invariant — accept either `"8MB"` or `"16MB"`**, mirroring the `SIZE`/`PERF` looseness above. **Rejected: it would hide the live disagreement #203 exists to resolve.** SIZE and PERF are two *legitimate* choices awaiting a measurement, and a gate that accepts both still enforces the property that matters ("this build is optimized"). 8MB and 16MB are not that: they are a standing contradiction between what the committed defaults declare and what the published merged image is built with, and exactly one of them is right for this device. Accepting both would make the gate pass whichever value a build happened to resolve, so the contradiction would stop being visible in CI at precisely the moment someone is working on it. Looseness is right for a pending *choice* and wrong for a pending *contradiction*.
* **Deriving the expectation from `sdkconfig.defaults`** — read the declared value and assert only that the resolved value equals it. **Rejected on the reframe itself: the gate deliberately does not trust that input as proof.** The premise of this whole design is that `sdkconfig.defaults` is an input that can be stale, overridden or incomplete, which is why the checker validates IDF's resolved output instead and why `--defaults` is provenance-only and explicitly not promoted to an assertion. An expectation taken from that file moves with it, so a wrong or accidental edit to the defaults would shift the expectation alongside the value and pass — the same fail-open shape as "an auditor must not take its expectations from the artifact it audits" above. The expectation has to sit somewhere a reviewer must change on purpose.

What is true, and worth stating so the next maintainer is not surprised, is that a #203 direction change is a **coherent multi-place edit**. Three revisions of this record tried to state that surface as a fixed list and each was short — three places, then six, then six again while the section's own re-derivation note named a seventh in the next paragraph. So the rule here is now the same one adopted for stage 2, and it is a rule about *authority*, not just about method:

> **The reviewed output of the command below is canonical. The bullets after it are current categories and examples, not a permanently exhaustive list.** If the command surfaces a hit no category covers, the hit is right and the prose is stale.

That inversion is the whole correction. A prose list is a snapshot that rots as the tree grows and reads authoritative while doing it; a command re-derives. What the prose is still for is judgement — which hits *matter*, and why — because a command cannot tell a load-bearing location from an incidental mention. Run it over tracked files:

```bash
git grep -nE 'FLASHSIZE|--flash-size|--flash_size'
git grep -l ESPTOOLPY_FLASHSIZE -- 'idf_app/tools/fixtures/*.json'
```

Three things about that pattern, each of which cost a location when it was absent. It matches the **symbol** (`FLASHSIZE`) and **both esptool spellings** — `--flash-size` *and* the underscore form `--flash_size`, which is how `docs/usage/FIRMWARE_FLASHING.md` writes it and is why an earlier hyphen-only pattern never saw that file at all. It runs over **tracked files** rather than an `--include` whitelist, because two locations were previously missed by a wrong *file set* — `idf_app/sdkconfig.defaults`, the file that actually declares the value, and `idf_app/tools/test_check_release_config.sh`. A command that cannot find the item at the top of the list it re-derives is worse than no command: it answers short and confidently.

The categories that output currently falls into, and why each has to move:

* the declared value in `idf_app/sdkconfig.defaults` — two lines, `CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y` and `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"`;
* the expected value in `check_release_config.py`, **and the comment beside it** — which states this stance and names both sizes, so a direction change must move it too;
* the **fixture corpus**, not one fixture: twelve fixtures under `idf_app/tools/fixtures/` currently carry `ESPTOOLPY_FLASHSIZE`. Flipping the expectation to 8MB makes the compliant ones (`pass.json`, `pass_perf.json`) violating and adds a second violation row to the single-violation fixtures. And `wrong_flashsize.json` does not merely need editing — its "wrong" value **is** `"8MB"`, so an 8MB decision **inverts** it and a different wrong value has to be chosen;
* the **committed suite that pins the token**, which no earlier revision of this list carried: `idf_app/tools/test_check_release_config.sh` asserts the exact violation token `RK-RELCFG-VIOLATION: ESPTOOLPY_FLASHSIZE` against `wrong_flashsize.json` (its "flash size mismatch rejected" case, requiring exit `2`) and names `ESPTOOLPY_FLASHSIZE` in its invariant-coverage set. This is where the inversion trap is actually *felt*: the #203 handoff's simulated flip reports that case exiting `0` where it requires `2`, and that case lives here. A list that named the fixture but not the case asserting it described half the edit;
* the **`esptool merge-bin` invocation itself** in `.github/workflows/docker.yml`'s *Create merged flash image for web flashing* step, which passes `--flash-mode dio --flash-freq 80m --flash-size 8MB`. This is the executable line that *is* the other half of the disagreement, as against the caveats that merely describe it — and it was the most consequential omission of all three, because every earlier revision of this list named the commentary and not the cause. A 16MB direction changes this argument; an 8MB direction is the decision to keep it and move everything else to match;
* both copies of the static **run-summary caveat** in the same file (`build-idf`'s and `release`'s), which hardcode the two sizes and describe the disagreement as open;
* **`docs/usage/FIRMWARE_FLASHING.md`** — the *Creating Merged Binaries* instructions reproduce the merge command with `--flash_size 8MB` for a human to run by hand. It is operator-facing, so leaving it behind would have a maintainer publishing images at one geometry while telling users to build them at another;
* **`docs/dev/KCONFIG.md`** — the flash-configuration block quotes both declared lines verbatim, and both it and the release-gate section state the 16MB pin and name the disagreement as open. That page is the version a developer actually reads, and it defers to **this section as canonical** rather than duplicating it, which is precisely why authority here had to move from the prose to the command: a deferral to a hand-maintained list inherits that list's undercounts;
* this record.

**What the command also returns, and what is deliberately *not* on the list.** The judgement the prose owes a reader is the boundary, so it is stated rather than left to be re-litigated:

* Hits inside this record and inside `KCONFIG.md` that are *narrative* — the rejected alternatives, the "not asserted here" scope line, this paragraph — are covered by "this record" / that page and need no separate accounting.
* Hardware-identity statements that a wider pattern would catch (`docs/esp/hw-reference/board.md`'s `Flash | 16 MB`, `docs/dev/DEVELOPMENT.md`'s board line) are **#193's surface, not this one**, which is why the pattern is scoped to the symbol and the esptool flags rather than to `16MB`/`8MB` as bare strings. If #203 concludes the device is not 16MB, those change *because the hardware record was wrong* — a different claim from the config expectation, arriving through #193.
* PSRAM's 8 MB is unrelated and shares only a number. A pattern loose enough to catch it would bury the real surface in noise, which is its own way of producing a confidently short answer.

No claim of exact equality between the command's output and these bullets is made here, because none has been mechanically established: the two are different kinds of object — a line-level hit list and a set of categories with judgement attached. Check the output against the categories; do not expect the counts to match.

Naming that surface accurately is the point of recording it: an undercount reads as "cheap", and the argument for pinning rather than recording only holds if the bill is stated. #203 changing all of it together is the correct process, not a design smell.

### `sdkconfig.defaults.ble`

Invariants are declared for the default profile only. `sdkconfig.defaults.ble` is a manual, non-CI profile that flips `BT_ENABLED` / `ROON_KNOB_BLE_HID_ENABLED` and touches none of the asserted symbols. The checker's explicit `--config` path is the seam a future profile would use; **no profile mechanism is built here** (that is #200).

## Negative proof

| Layer | What only it can prove | Cost | Gates shipping? |
|---|---|---|---|
| `tools/fixtures/` + `tools/test_check_release_config.sh` (CI job `release-config-fixtures`) | the checker's logic: exact exit code and exact token per case, positive and negative, including that rename aliases pass, that a requested-but-unreadable log fails, that empty flag values are usage errors, and that assigned values are never echoed | host-only, seconds | **yes** — in `release` *and* `deploy-pr-preview` `needs:` |
| assert-the-assertion cases in the same runner | that the host gate has teeth: it rejects `enforced:false`, a digest belonging to another build, a missing report, a failing verdict, a report proving no log was read, and — with `--forbid-absent-satisfied` — a report where an invariant is satisfied only by its symbol's absence | host-only, folded in rather than a separate job | **yes** — same job |
| `tools/cmake_gate_harness.cmake` + `tools/test_release_config_cmake.sh` (same job) | the **gate's** own decision paths under `cmake -P` with IDF's two commands stubbed: ON fails / OFF continues, `NOCHECKER`, empty output, `;`→`,`, `NOREPORT`, an unlaunchable interpreter, and a missing `fail_at_build_time` | host-only, seconds; needs `cmake` and `python3` only | **yes** — same job |
| the liveness canary in `build-stale-config` | that kconfgen still *emits* the diagnostic the delegated undefined-symbol determination reads — the one thing no recorded fixture can prove | zero extra container cost | **yes** — in `release` *and* `deploy-pr-preview` `needs:` |
| CI job `build-stale-config` | the wiring, **and that `fail_at_build_time()` is load-bearing**: a faithful stale tree fails with enforcement ON and builds successfully with enforcement OFF | two effectively full container builds; 60-minute job ceiling now also bounds preview availability | **yes** — in `release` *and* `deploy-pr-preview` `needs:` |

These jobs **require** evidence rather than merely producing it. `release` *and* `deploy-pr-preview` both declare `needs: [build-idf, release-config-fixtures, build-stale-config]` — the same prerequisite set, not a subset — so a red checker-logic job or a red wiring job stops both a `v*` tag from publishing firmware and a hardware-flashable preview from being published. That is job-graph parity only: `release` additionally re-asserts the downloaded report before publication, while `deploy-pr-preview` does not yet; #210 owns that artifact-validation gap. (An earlier revision of this record described the preview list as a subset that omitted `build-stale-config`; see the #207 bullet under "Enforcement ceilings" for why that trade was dropped.) None of these prerequisites carries an `if:` event guard, deliberately: a *skipped* dependency skips the dependent job as well, so an event-guarded prerequisite would silently un-gate exactly the tag builds it was meant to protect. The price is that `build-stale-config` runs in every triggered workflow — eligible `master`/`main` pushes, `v*` tags, and pull requests to those branches — one container build of runner time, accepted in exchange for a graph whose safety does not depend on reading GitHub's skip semantics correctly. This deliberately accepts for preview availability the same registry/upstream-flake coupling #205 declines to impose on merging: losing a preview is recoverable and visible, while blocking every unrelated merge is a materially stronger repository-wide policy.

### `build-stale-config` is a controlled ON/OFF pair, not a single red build

The first version of this job seeded a **three-line** `sdkconfig`. Because a stale `sdkconfig` overrides the defaults, that also dropped PSRAM, the custom partition table and the flash size — so the build could not link for reasons having nothing to do with the gate. Worse, all three of its assertions were satisfiable without `fail_at_build_time()` ever mattering: the violation token is printed at configure time by `message(STATUS)` **even when enforcement is OFF**, and the report is written unconditionally by design. The job proved the checker *noticed*. It did not prove the gate *blocked*, which is what #202 AC 6 asks for — and `fail_at_build_time()`, the single most load-bearing line in the change, was exercised by no test at all.

It is now a genuine control:

1. **Seed a faithful stale tree.** `idf_app/sdkconfig` is a full copy of `sdkconfig.defaults` with *only* the optimization selection regressed to `CONFIG_COMPILER_OPTIMIZATION_DEBUG=y` (plus the three `is not set` lines). A `diff` of both files with the optimization lines stripped must be empty, asserted in the job, so every other setting is provably identical and cannot be the cause of a failure.
2. **Run 1, enforcement ON — must fail.** Requires step outcome `failure`, the exact token `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG`, the `RK-RELCFG-ENFORCED` banner, and a report with `enforced: true` / `verdict: "fail"`. That report and the resolved `sdkconfig.json` are copied to `$RUNNER_TEMP` before run 2 overwrites them.
3. **Run 2, the positive control — identical tree, enforcement OFF, must SUCCEED.** No `continue-on-error`: requires the `*** RELEASE CONFIG INVARIANTS NOT ENFORCED ***` banner, a real `roon_knob.bin`, and a report with `enforced: false` / `verdict: "fail"`. If this run fails, something other than the gate was stopping the build and the negative proof above would have been worthless.
4. **Prove it was a controlled pair.** The two reports must carry the **same `config_digest`** and the same `fail` verdict, differing only in `enforced`. Same tree, same resolved configuration, same violation, opposite outcomes — which makes `fail_at_build_time()` the sole difference between a blocked build and a shipped one. Demonstrated, not assumed.

Two containers rather than one, so each outcome is separately attributable in the log. Neither run calls `set-target`, which would rename the seeded `sdkconfig` to `sdkconfig.old` and destroy the condition under test.

**Timeouts: ceilings, now reviewed against real wall times.** `build-idf` carries `timeout-minutes: 30` and `build-stale-config` `60`. First real run (`30506101326`) measured **`build-idf` 3m32s** (its build step 3m20s) and **`build-stale-config` 3m27s** (ON run ~1m31s, OFF run ~1m52s) — so both ceilings ran roughly 8–17× the observed time.

They were reviewed against those numbers and **intentionally retained**. The observed times are a warm best case: the ESP-IDF image was already cached on that runner, and neither number includes a cold `docker pull` of a multi-gigabyte image, which is the dominant variable and the one most likely to spike on an unlucky runner. Tightening to, say, 10 and 15 minutes would convert a slow registry into a red required check on an unrelated PR — the precise adoption failure this record warns about elsewhere, bought for no safety gain, since the purpose of a ceiling is only to stop a *hung* build from occupying a runner for GitHub's six-hour default. Revisit if a pattern of runs approaches these numbers, not on the strength of one warm run.

**Cost, stated accurately.** An earlier revision of this record called run 2 "incremental." It is not: `fail_at_build_time()`'s target has no dependencies, so ninja schedules it immediately and stops within seconds of the ON run starting — almost nothing is compiled, so there are almost no objects for run 2 to reuse. Run 2 is therefore effectively a **full** build, and this job costs roughly **two** full container builds. With `build-idf`, and with `build-stale-config` deliberately carrying no `if:` guard, every triggered workflow — eligible `master`/`main` push, `v*` tag, or pull request — pays about **three** full container builds. That is the real price of proving the gate blocks rather than merely notices; it is worth stating plainly so that a future cost-cutting pass makes an informed choice rather than discovering the bill.

### The one delegated determination gets a liveness canary

Eleven invariants are computed here. The twelfth — "this assignment names a symbol that does not exist" — is kconfgen's, consumed by regex from the build log. That asymmetry has a failure mode nothing else in this design has: `esp-idf-kconfig` is constrained only to `<3.0.0`, so a future release could reword the diagnostic and the checker would return "nothing found" indefinitely, silently. Fixtures cannot detect it, because a fixture is a recording of the old wording. Worse, that same silence would disarm the brownout-alias drift alarm promised above, whose whole premise is that the aliases eventually become *unknown* symbols and say so loudly.

So `build-stale-config` arms a canary against the live toolchain, at zero extra container cost:

* A uniquely named bogus assignment, `CONFIG_RK_CANARY_UNDEFINED_SYMBOL`, is appended to the CI checkout's `sdkconfig.defaults` — **test-only, never committed**, with a tripwire in the host fixture suite that fails if it ever appears in the committed file.
* It is appended **after** the seed/diff assertion (so byte-identity is unaffected) and **before** run 1 (so the #149 guard sees the same defaults hash on both runs; appending between them would trip its `FATAL_ERROR` in run 2 and break the control for the wrong reason).
* It goes into `sdkconfig.defaults`, never `sdkconfig`. An undefined symbol cannot reach `sdkconfig.json`, so both runs still resolve an identical effective config and the digest-equality control is preserved. kconfgen loads defaults *before* the existing config — "always load defaults first" is its own comment — so the warning is emitted even though the seeded `sdkconfig` already exists.
* After run 1, the host checker is run against the real ON-run log and requires **exactly** exit 4 with `RK-RELCFG-UNDEFINED: CONFIG_RK_CANARY_UNDEFINED_SYMBOL`. Exit 2 would mean the wording moved and the determination has gone quiet.
* The canary's *value* is a sentinel, and the assertion requires it never to appear in the checker's output — so the no-echo discipline is proven against real kconfgen output rather than against a fixture.

Simulated both ways before landing: with the current wording the assertion passes; with the warning reworded it fails with exit 1 and names the cause.

A failure with **no token** — container hiccup, checkout problem, unrelated configure error — still turns the job red, and correctly so: the token is what tells you the gate is what fired.

Exit codes are contract, asserted by fixtures: `0` OK, `2` violation, `3` no/malformed config, `4` undefined, `5` requested log absent/unreadable/empty/missing its marker, `6` requested report unwritable, `64` usage error (distinct from every verdict). Precedence is documented above.

The unwritable-report fixtures fail for **structural** reasons — the report's parent path component is an existing file, or the destination is an existing directory — rather than by `chmod`. Permission-based fixtures are not deterministic: they silently pass as writable when the suite runs as root, which is exactly the environment where a fail-open would matter least to detect and most to have.

## #149's guard: restored and re-scoped

The `sdkconfig.defaults` staleness guard from closed #149 is restored in `idf_app/CMakeLists.txt`, essentially verbatim, with two documented decisions:

* **It keeps `FATAL_ERROR`**, unlike the config gate, because its recovery is `rm sdkconfig && idf.py build` and does not require `menuconfig` to still work. The asymmetry is deliberate.
* **Its scope is stated honestly.** It hashes `sdkconfig.defaults` and requires **both** an existing `idf_app/sdkconfig` **and** a stamp in the build dir, so it is silent on a fresh CI checkout, and `scripts/install.sh`'s `rm sdkconfig` bypasses it. It is a **local developer-ergonomics guard**; its release-safety role is **superseded** by the effective-config gate, which fires where the guard cannot.

It is restored rather than merely superseded because of one non-substitutable contribution: `set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_DEFAULTS_FILE}")`. IDF registers `sdkconfig`, `sdkconfig.h` and `sdkconfig.cmake` as configure dependencies but **not** `sdkconfig.defaults`, so without that line editing the defaults would not re-run configure and the new gate would not re-evaluate. The gate's own CMake file registers the same dependency plus the checker, so the two mechanisms are complements: the guard tells a developer their `sdkconfig` is stale, the gate tells anyone what the build actually resolved.

## Alternatives rejected

| Option | Why rejected |
|---|---|
| **A — add the one missing line** | Leaves every failure mode above intact: the next stale `sdkconfig` silently ships a debug build. It is the framing that produced the bug. |
| **B — assert on `sdkconfig.defaults`** | Validates the input, not the outcome. Passes while the build resolves to something else entirely. |
| **C — post-build binary/image inspection** | Late, indirect, and mostly #203's territory. Cannot distinguish "unoptimized" from "differently linked" without a size oracle. |
| **E — rely on kconfgen warnings alone** | Warnings do not fail builds, and they say nothing about the invariants that matter (SPIRAM, panic handler, assertions). Kept for exactly the one determination it is authoritative about. |
| **Reconstruct undefined-symbol detection from three artifacts** | Rebuilds, less correctly, a verdict the toolchain already emits. See above. |

## Consequences

* A release build that resolves to a debug or unsafe configuration fails at configure time, naming the symbol — **observed**, not projected: run `30506101326`'s ON run failed exactly that way on a faithful stale tree, and the OFF run on the identical resolved configuration built firmware.
* CI's enforcement **is** provable from an artifact rather than assumed from a workflow line, and the jobs that prove it gate **publishing** rather than merely reporting. The gate ran forced-on in the container, the host re-derived and matched the config digest, and the artifact carries the report — all observed in that run. Read this with the narrowing under "Enforcement ceilings": a job cannot run unenforced, and **both** release and preview publication are gated on all three proof jobs — but **merging is not** CI-gated at all under current branch protection.
* The optimization mode is a recorded measurement, so the next maintainer does not have to guess whether it was reasoned or copied — but it is a *static* measurement; see "The limit of this measurement".
* `roon_knob.bin` shrinks from 1 761 952 B to 1 613 984 B (67.21 % → 61.57 % of the app slot) and static DIRAM drops 10 672 B. This is a **behavioural change** — `-Og` → `-Os` — and CI cannot validate it. It interacts with the brownout tuning above.
* Hardware validation is release-blocking but **not** merge-blocking: #202 merges on contract/CI evidence; #203's PR build (containing both #202 and #203) is the single combined hardware-test candidate; the release-blocking checklist lives on #189 and blocks **tagging**, not merging.
* New CI surface: enforcement forcing plus three host assertions in `build-idf`, one host fixture job, and one integration build that runs in every triggered workflow, including every pull-request run. The known adoption risk is that a red-for-infrastructure-reasons job gets `continue-on-error` or is quietly dropped during #203's workflow edit. Three things push against that: the fixtures job is seconds and host-only, the ADR names the required response to a drift-induced red build as a procedure with a closed prohibited list ("The permitted response to upstream drift" above), and both publishing consumers now carry all proof jobs in their `needs:` lists, so dropping one is a visible change to the release and preview paths rather than a quiet one. What does *not* push against it is required checks, which are not configured — that is the named authorization-gated follow-up, **#205**.

## Evidence that outlives the run

The gate is only useful later if its verdict is recoverable later. Two cheap, firmware-free additions:

* `idf_app/build/config/rk_release_config.json` rides along in the existing `esp32s3-firmware` artifact, next to the binary it describes. Be precise about what that preserves: the **verdict, the enforced state, the sha256 of the config that was gated, and one evidence row per invariant** — *not* the gated configuration itself, which cannot be reconstructed from the report. The resolved `sdkconfig.json` is deliberately **not** uploaded: artifacts on a public repository are world-downloadable, and that file is exactly where a future `sdkconfig.local`-style credential would surface, which would undo the checker's own no-echo discipline. So the report is digest-*bearing* but not, in the artifact, digest-*bound* to a published config file; the binding is same-job provenance plus the per-file assertion below, and the `release` job re-asserts the report itself. Recovering the full configuration of a past release remains a #203 concern.
* **Per-file existence is asserted explicitly**, by a host `test -f` over all three artifact inputs (app binary, merged binary, report) immediately before the upload. `if-no-files-found: error` is retained as defence in depth but is **not** a per-file guarantee: `actions/upload-artifact` evaluates it once against the *combined* search result, so with three patterns it fires only when all of them match nothing — the report could be absent and the upload would still be green because the binaries matched. An earlier revision of this record claimed otherwise; the claim was wrong, and a decision record asserting a protection that does not exist is worse than a disclosed gap.
* After the assertions pass — never before, so a summary cannot announce a verdict that was not also enforced — `build-idf` writes the **resolved optimization mode**, verdict, enforced state, config digest, tokens, and the run identity (`repository`, run id, attempt, commit) to `$GITHUB_STEP_SUMMARY`. The mode is read from the report's `invariants` rows, not from the defaults file, because the invariant deliberately accepts SIZE *or* PERF and so "verdict: pass" does not by itself say which one shipped. That step carries `if: always()` so failing runs — where the evidence matters most — still publish; it cannot mask an earlier failure, because a failed step has already failed the job and `always()` only adds a step. It tolerates a missing report and says so, since a build that died before configure never wrote one; the requirement that a *successful* build produce one is carried by the assertion steps, which do not use `always()`. It also emits the static configuration-verdict-is-not-image-geometry caveat on **every** path, including the failing and missing-report ones — see the `ESPTOOLPY_FLASHSIZE` section for why that caveat must not be conditional on there being a report to describe.
* **The `release` job re-asserts the evidence it is about to publish**, after `download-artifact`: the report must be present in the artifact with `enforced: true` and `verdict: pass`, and the release tag, resolved mode, verdict and config digest are recorded in that job's run summary before any asset is uploaded. `build-idf` being a `needs:` prerequisite proves a green job ran; this proves the *thing being published* carries a passing gate report. That summary carries the same static geometry caveat, which matters more here than anywhere else: this is the table someone will read when asking "what did `v1.x.y` ship?", and it must not let a green config verdict be mistaken for a validated flash image while the 16MB/8MB disagreement is open. The job already checks the repo out (so the asserter is present) and `python3` is preinstalled on `ubuntu-latest`. **No CI run is claimed for this block:** `release` is tag-only (`if: startsWith(github.ref, 'refs/tags/v')`), so it was *skipped* in the recorded `pull_request` runs — GitHub reports `Create GitHub Release => skipped` for run `30507024502` — and what is claimed instead is checkable without it: the step is fail-closed and ordered **before** `Create or Update Release`, so a missing or non-passing report aborts the job before any asset is published, and its summary block was **executed locally** on its one reachable path, the present-report path, because the preceding `test -f "$report" || exit 1` under `set -euo pipefail` exits the step before Python starts when the report is absent — leaving no reachable missing-report branch inside it, unlike `build-idf`'s summary, where both paths are reachable and both were exercised.

### The publish-time config-digest trust boundary

Worth stating exactly, because the two assertions are not equivalent and a reader could assume they are:

* **In `build-idf`, the digest is re-derived.** The host recomputes sha256 over `idf_app/build/config/sdkconfig.json` and requires the report's `config_digest` to equal it. That binds the report to the configuration the container actually resolved, in that run, from a file both steps can see.
* **In `release`, the digest cannot be re-derived.** `sdkconfig.json` is deliberately **not** published in the artifact (public artifacts are world-downloadable, and that file is where a future `sdkconfig.local`-style credential would surface). So `release` asserts what the report *says* — schema, `enforced: true`, `verdict: pass` — and records the digest for provenance, but it cannot independently confirm that digest describes the binary beside it.

What closes the gap is **run-scoped same-job provenance**: `roon_knob.bin`, `roon_knob_merged.bin` and `rk_release_config.json` are produced by the same `build-idf` job, in the same workspace, in the same run, and all three are asserted present by name before the upload. The binding is "these files came out of one gated build together", not "the digest was checked twice". That is a weaker claim than a cryptographic tie between report and binary, and it is the honest one. Anyone wanting the stronger property would need to publish the resolved configuration or embed a digest in the firmware — the first trades away the secret discipline, the second is firmware behaviour, and both belong to #203.

Together these make #189's release-blocking checklist satisfiable from CI output rather than from recollection. The log-scan report stays host-temporary in `$RUNNER_TEMP` deliberately: it is a transient proof that a log was read, not a description of the shipped configuration, and persisting it would invite reading the wrong one of the two reports.

**No firmware-reported digest exists, and #202 adds none.** #189's checklist wording asks for a firmware-reported release-config digest reconciled against the CI report; nothing in `idf_app/main` or `idf_app/components` embeds or reports one, and adding it would be firmware behaviour, which #202 excludes. So that half of the checklist item is **knowingly deferred to #203**, not silently waived — see the handoff below. What #202 does provide is the CI-side half: a persisted report and a run summary that a human can reconcile against the flashed build.

## Handoff to #203

Carry these forward when #203 opens; they are consequences of #202, not #202's own scope:

**Static / build-time (the half CI can check):**

1. Reconcile `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` against `esptool merge-bin --flash-size 8MB`, and decide the direction (with #193 for hardware identity). If the answer is 8MB, walk the whole edit surface under "`ESPTOOLPY_FLASHSIZE` = 16MB vs the 8MB merge" — and know the trap in it before starting: **`tools/fixtures/wrong_flashsize.json`'s wrong value *is* `"8MB"`, so flipping the expectation makes that fixture compliant and its case stops describing a flash-size violation.** It has to be re-pointed at a genuinely wrong value, not re-valued to the new expectation and not deleted. Confirmed by simulating the flip against this tree: `wrong_flashsize.json` exits `0` where its case requires `2`, and `pass.json` / `pass_perf.json` exit `2` where they require `0`. So the suite goes **red**, not quietly green — the trap is loud, and the hazard is that the cheapest-looking repair (relaxing or dropping the case) removes negative coverage while turning the suite green again.
2. Image geometry and partition-fits-flash checks; size-headroom gate against the `0x280000` app slot — SIZE currently sits at 61.57 %.
3. `PROJECT_VER` binary inspection and the build-evidence artifact (`$GITHUB_STEP_SUMMARY` reporting), both deliberately excluded here.
4. Re-measure DEBUG/SIZE/PERF if the SDK moves, and **re-record provenance** rather than reusing this table.

**Hardware (the half CI cannot check) — the combined #202+#203 PR build is the single test candidate:**

5. **Encoder input latency** at `-Os`, including fast continuous rotation.
6. **LVGL redraw** smoothness — artwork transitions, screen changes, dropped frames or tearing that `-Og` did not show.
7. **Battery brownout at `-Os`** against the level-4 / 2.50 V tuning, on battery, through Wi-Fi association inrush.
8. **Boot and OTA from a prior `-Og` release**, confirming the mode change does not break the update path.
9. Board revision recorded, plus the enforcement banner and a `sha256sum` reconcilable with the CI artifact.
10. **A firmware-reported release-config digest**, if #189's checklist wording is to be met literally. #202 adds none — that is firmware behaviour and out of its scope — so #203 either implements it or the checklist item is amended to accept the CI-side evidence (persisted report + run summary) that #202 does provide.

## Tracked follow-ups

Every gap, ceiling and deliberate trade this record discloses is now carried by an issue rather than by prose alone. That distinction matters for a record whose whole argument is that a claim which cannot be checked should not be made: a disclosed gap with no tracking issue is a gap that survives on whoever remembers reading this file.

| Issue | Title | The paragraph it comes from | Kind |
|---|---|---|---|
| [#205](https://github.com/muness/roon-knob/issues/205) | Require release-integrity checks before merging to master | "Enforcement ceilings" — protection has no required contexts, so a tree with every gate red is mergeable | authorization-gated repo setting, outside this tree |
| [#206](https://github.com/muness/roon-knob/issues/206) | Fail closed when negative release invariants disappear | "Absence is directional" — an expected-`false` symbol that leaves the SDK schema reads as satisfied | coverage gap; failure mode was **green**, now **signalled** in CI by `--forbid-absent-satisfied`, but the checker-level model is still open |
| [#207](https://github.com/muness/roon-knob/issues/207) (**decision recorded; closes when this PR lands**) | Decide whether PR previews require the stale-config blocking proof | "Enforcement ceilings" / "Negative proof" — `deploy-pr-preview` needed two of the three proof jobs | decided **yes**: `deploy-pr-preview` now needs all three, so the asymmetry is gone |
| [#208](https://github.com/muness/roon-knob/issues/208) | Detect checker/gate token-contract drift in release CI | "Token precedence" and the exit-code-keyed headline in the Status block | contract-integrity coverage |
| [#209](https://github.com/muness/roon-knob/issues/209) | Attribute missing positive release invariants as schema drift | "Absence is directional" — an absent required-`true` symbol fails with a configuration rationale that may misattribute an upstream rename | attribution, **not** verdict |
| [#210](https://github.com/muness/roon-knob/issues/210) | Detect release-workflow contract drift | "An auditor must not take its expectations from the artifact it audits" / "Consequences" — the caller-owned flags and publication graph are correct now, but nothing committed asserts that the workflow keeps calling them | contract-integrity coverage, caller-side |

Four properties they share, worth stating so none of them is later read as a licence to loosen the gate:

* **None weakens fail-closed.** #209 and #206 change *what a failure is attributed to* and *what is noticed*; neither may let an absent required capability pass. #208 explicitly must not change whether any build passes.
* **#206 and #209 are one model, two risks.** Both need active Kconfig/schema evidence rather than an inference from absence in `sdkconfig.json` — which is why neither is a small patch to this checker — and they should land with one documented semantics for symbol disappearance without conflating a shrinking-coverage risk (#206) with a misattribution risk (#209). Both coordinate with **#183**, since an SDK pin/bump is when symbol disappearance actually happens. The `--forbid-absent-satisfied` assertion described under "Absence is directional" does **not** substitute for #206: it makes today's zero-absent shape a CI-visible fact, and deliberately leaves the checker's semantics — and the question of *why* a symbol is absent — untouched.
* **#205 was a decision, not code; #207 has now been made.** #205 is a repository setting requiring maintainer authorization, still open and not #202's to make. #207 was the other decision — what a publicly flashable preview is allowed to mean — and this record answers it: previews are held to the release standard, implemented by giving `deploy-pr-preview` the same three `needs:` as `release`.
* **#210 owns the caller layer that this report cannot witness.** Nothing in this tree currently asserts that `.github/workflows/docker.yml` preserves both three-job publication graphs or continues to pass the caller-owned arguments. Today those controls are protected by diff visibility and the prohibited-response list, not by detection. The follow-up is deliberately risk-ranked: removing `-DRK_ENFORCE_RELEASE_CONFIG=ON` alone preserves enforcement because the CMake option defaults `ON`, and removing checker-side `--log-must-contain` alone is caught by the fixture-pinned caller-side `--expect-log-marker`. The single-point fail-open shapes are a dropped publication `needs:` edge, a dropped `--forbid-absent-satisfied`, or deletion of an assertion step; #210 must mutation-test the layered cases without pretending they all have equal consequence.

These are distinct from the **#203 handoff above**, which carries #202's *consequences* (geometry, size headroom, provenance, the hardware half). Five remain open gaps in #202's enforcement story; #207 is retained in the table as the decision that closed the sixth.

## Acceptance bookkeeping

#202 has **ten** acceptance criteria; earlier revisions of this record miscounted them as eleven, so the two below were cited one number too high.

* **AC 10 (update #181 to remove any cleanup item completed here): satisfied.** The `## Stale kconfig symbols in sdkconfig.defaults` section, naming all four symbols this work removed, was deleted from #181 by a content edit recorded at `2026-07-30T00:04:06Z` and confirmed through the issue's `userContentEdits` history. #181's remaining scope — the `bridge_client.c` dead-code warnings and the ESP-IDF 6.0 bump — is untouched and the issue stays open, which is correct. (A reading that #181 "never contained anything #202 completed" is contradicted by that edit history; the section existed and was removed.)
  A reading that #181 "contained no item #202 completed", so that AC 10 was vacuous, is **wrong on the facts** and is recorded here so it is not repeated: the section existed, it named exactly `CONFIG_WIFI_SSID`, `CONFIG_WIFI_PASSWORD`, `CONFIG_EXAMPLE_IPV6` and `CONFIG_LWIP_NETIF_HOSTNAME` — the four symbols removed by this work — and the issue's `userContentEdits` history shows the revision that contained it and the later revision that does not. The AC had real content and was really discharged.
  **The deletion is conditional, and the condition is recorded on #181 itself**, not only here: comment [`5126316501`](https://github.com/muness/roon-knob/issues/181#issuecomment-5126316501) (2026-07-30T04:08:26Z) states that the section was removed because *this branch* deleted those four symbols, and that if PR #204 is abandoned rather than merged or superseded, the section must be restored so #181 keeps tracking work that still exists on `master`. That is the right place for it: an edit that removes tracking on the strength of an unmerged branch is only safe if the reversal condition lives where the next reader of that issue will see it. #181's dead-code and ESP-IDF 6.0 sections are unaffected either way.
* **AC 1–8 are satisfied and now CI-observed**, per the Status block: measurement (AC 1), checker (AC 2), configure-time invocation with a recovery path (AC 3), forced CI enforcement plus an unmistakable state/digest (AC 4), committed fixtures including the assert-the-assertion meta-test (AC 5), one stale-config integration negative asserting the checker's exact exit and message (AC 6), #149's guard restored and honestly scoped (AC 7), and only genuinely undefined defaults removed with the brownout aliases retained (AC 8).
* Ticking #202's own acceptance checkboxes and #189's execution-split box is ship-phase bookkeeping, deliberately still not done here — the checkboxes are the maintainer's to tick. PR #204 has been retitled `ci: enforce effective release firmware configuration`; its body carries the observed run evidence.
* **AC 9 (record the decision) is satisfied by this file**, and the operator-facing half now lives in [`docs/dev/KCONFIG.md`](../../dev/KCONFIG.md#release-config-gate-202): the tokens, the two recovery paths, and the local-only `-DRK_ENFORCE_RELEASE_CONFIG=OFF` hatch with its cache-persistence caveat. `CLAUDE.md` routes build/config questions there, so a developer whose local build fails with `RK-RELCFG-VIOLATION` finds the answer where they look first rather than only in a decision record.

If 5–8 regress, the **first** move is the one-line switch to the other optimized mode (SIZE→PERF) in `sdkconfig.defaults`, which the gate still checks. If **both** optimized modes regress, the remedy is an explicit reviewed and recorded amendment to the invariant naming the mode the hardware evidence justifies — never a silently disabled gate. The staged procedure and its costs are under "The limit of this measurement"; do not read this line as promising that PERF is always the answer.

## References

* Checker: `idf_app/tools/check_release_config.py`
* Host assertion: `idf_app/tools/assert_release_report.py`
* Fixtures + runner: `idf_app/tools/fixtures/`, `idf_app/tools/test_check_release_config.sh`
* CMake wiring: `idf_app/cmake/rk_release_config.cmake`; #149 guard in `idf_app/CMakeLists.txt`
* CI: `.github/workflows/docker.yml` (`build-idf`, `release-config-fixtures`, `build-stale-config`)
* Measurement run: GitHub Actions `30498910795`, draft PR #204
* Implementation-evidence run (ON/OFF causal pair, artifact composition, live canary): `30506101326` at `62ffc4ae577787cf5b67a197bf985634a633b861`
* Confirmation run at a verified predecessor: `30507024502` at `876c0786d59938deb2794aa4e3e104642c35f601` — same config digest, 11/11, no material divergence.
* Runs at the ancestors carrying the message-attribution work: `30510929713` at `4d16d3b84916246ace024ce49b781ee83c8c6384` (77/77 host, **17/17** CMake) and `30512450762` at `1eae955bb4aba60673396eae91b7cf2903fa99f6` (77/77 host, **23/23** CMake) — the ON build of the latter is where `RK-RELCFG-VIOLATION` is observed heading the failure in the live container.
* Pre-adjustment confirmation: `30515747808` at `17edfc772383be1a4436d6286fed3096a4b2eb2c` (77/77 host, 23/23 CMake).
* Preview-parity and absence-floor execution: `30518128099` at `aee0a786fb9f470d88ed046ef5e4f8a694308ce5` (83/83 host, 23/23 CMake, `no-absent-satisfied`); documentation-only confirmation `30519518551` at `a9e6fd329a3520bd548b37b981d1ae0c78be6791` reproduced those figures.
* Review-remediation execution: `30523566990` at `bc1870931f3fdb697c72a9157513cbc12b94039b` (84/84 host, 23/23 CMake, combined malformed-config/log-undefined regression, same-digest ON/OFF proof, enforced build, and preview green); `bc18709` is tree-identical to remediation commit `52f82b8`.
* Every run is attributed to the exact commit it executed; see the Status block for what each does and does not cover.
* Tracked follow-ups from this record: [#205](https://github.com/muness/roon-knob/issues/205), [#206](https://github.com/muness/roon-knob/issues/206), [#207](https://github.com/muness/roon-knob/issues/207), [#208](https://github.com/muness/roon-knob/issues/208), [#209](https://github.com/muness/roon-knob/issues/209), [#210](https://github.com/muness/roon-knob/issues/210) — see "Tracked follow-ups". Adjacent: **#203** (geometry, size headroom, provenance, hardware), **#183** (SDK pinning), **#193** (hardware identity), **#200** (config profiles).
* #181 conditional-restore note for AC 10: comment [`5126316501`](https://github.com/muness/roon-knob/issues/181#issuecomment-5126316501).
