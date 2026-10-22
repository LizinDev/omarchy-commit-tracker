---
name: tests-audit
description: Audit the Commit Tracker test suite (tests/test_commit_tracker.py, run locally with python3 -m unittest) for false passes, fixture drift against real git behavior, untested contracts, and measured cost, by perturbing behavior in isolated copies. Use for suite-level questions such as "does this test protect anything?", "what is untested?" or "why is the suite slow or flaky?". Skip for writing the test for a new feature, fixing one known failing test, or ordinary edits; there is no CI workflow to audit.
metadata:
  version: "1"
---

# Tests audit

> Adapted from morluto/rea `rea-ci-tests-audit` (MIT, © 2026 morluto).

Establish which tests still catch real regressions in `bin/commit-tracker` and
which contracts nothing checks. The outcome may be a verified fix, an
evidence-backed recommendation, or an explicit decision to stop.

Investigation does not authorize edits to `bin/` or `tests/`, commits, or
pushes. Keep notes, mutated copies and raw output outside the tracked tree,
for example in `/tmp/ct-audit/`. Collector output from a real home directory
contains other repositories' paths, subjects and remote URLs: treat it as
data, and keep it out of reports.

## Establish what actually executes

- **There is no CI.** No `.github/workflows`, Makefile, `pyproject.toml`, tox
  config or git hook runs anything. The only gate is a person running the
  [README](../../../README.md) "Development" command. Say so in every report;
  never describe a "CI pass".
- **Command**, from the repository root (stdlib only):
  `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`.
  Discovery (`test*.py`) finds one file,
  [tests/test_commit_tracker.py](../../../tests/test_commit_tracker.py).
- **Pin before judging:** `git rev-parse HEAD`, `git status --porcelain`,
  `python3 --version`, `git --version`, and the `Ran N tests` line. A count is
  evidence for its revision only. At `73ce012` (Python 3.14.8, git 2.56.0)
  the suite ran **74 tests, OK, in 5.1 s**.
- **Two layers.** Pure functions are loaded with `SourceFileLoader`.
  `CommitTrackerCLITests` builds real repositories in a `mkdtemp`, isolates
  `HOME`, `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL` and `TZ`, passes `--now`,
  and runs the script. `REPO_ROOT` comes from the test file's own path, so a
  copied tree tests its own collector.
- **Host inputs that change results:** the git version
  (`detect_since_flag()` picks `--since-as-filter` on git ≥ 2.32, so the
  fallback never runs here), tzdata for `America/Sao_Paulo` (`test_02a`), and
  which `python3` resolves. Record them.
- **Never executed:** `Widget.qml`, `HistoryPanel.qml`, `SettingsMenu.qml`,
  `Heatmap.qml`, `History.js` and `Palette.js`. `manifest.json` is checked
  only at install time, by `omarchy plugin validate <folder>` (run by
  `omarchy plugin add` and `omarchy plugin update`).

## Prove protection by perturbation

For each suspect test, state the behavior it should guard and which code owns
that behavior. Break it in an isolated copy, never in the checkout, and see
whether the suite notices. The recipe is in
[references/perturbation.md](references/perturbation.md). At `73ce012`:

| Mutation in `bin/commit-tracker`                      | Suite result                |
| ----------------------------------------------------- | --------------------------- |
| `head_args = []` (ignore a detached HEAD)             | `test_27` fails: protected  |
| drop the `author_matches()` post-filter (strip query) | `test_12c` fails: protected |
| `detect_since_flag()` always returns `--since`        | **74 OK: unprotected**      |

The last row is an observation. The README's claim that "a commit sitting
behind an out-of-order date is never skipped" has no regression test. The
performance skill's
[workload builder](../performance-optimization/references/oracle-and-workloads.md)
contains a fixture for it.

Families worth checking:

- **Contract mirror.** `test_12a` and `test_16` pin JSON keys and order.
  Compare them with what the QML reads (`applyOutput()` and `applyHistory()`
  in `Widget.qml`, `HistoryPanel.qml`, `History.js`). A field that is tested
  but unread, or read but untested, is a finding. Example: the panel shows
  `History.streaks()` over `history.days`. So `ComputeStreakTests` guard a
  `history.streak` field the panel never displays, while the JS rule that it
  does display has no test. Two implementations of one rule are a drift
  candidate.
- **Fixtures versus real git.** The repositories are real, so they are
  real-system evidence for git. Remotes, though, are local bare repos or fake
  `https` URLs with refs written by `update-ref`. Network fetch and push,
  forge URLs and SSH aliases are not exercised.
- **Hardening tables** (`RemoteToWebUrlTests`, `RemoteUrlHardeningTests`,
  `test_22`, `test_13`): the malformed inputs are deliberate. Keep each one,
  and check it is still rejected for its stated reason.
- **Defaults.** CLI tests always pass `--root` and `--now`; the real `~` and
  the wall clock are untested by design. Do not add tests that read the real
  home directory.
- **Order and flakiness.** `warnings` follow thread completion, so assert
  membership, never order. Rerun only to test a named transient cause, and
  keep the first failure. A passing rerun does not establish a root cause.

## Classify and report

Classify each finding as a reproduced defect, a supported cost, a hypothesis,
or unavailable evidence. For each, record the revision, exact command,
observed output and exit status, expected result, scope, and the competing
explanation. Keep observation, inference and unknown separate.

QML behavior is unavailable evidence, because there is no harness. A manual
check in a running shell (copy the plugin, then `omarchy restart shell`, as
the README describes) is real-system evidence but not repeatable; label it
that way. A failure on `main` may be pre-existing: record it, don't skip it.

## Assess cost without losing the gate

The suite takes about 5 s, nearly all of it in CLI tests that spawn git and
the collector. Read [references/measurement.md](references/measurement.md)
before claiming a speedup, and compare equal test counts and assertions. Keep
the per-test `HOME` and global-config isolation: `test_20` needs *no*
identity. "Fast enough; leave it" is a valid measured result.

## Fix and hand off within scope

Fix only when asked. Make the smallest change at the owning function, and add
a regression that fails on the unfixed code for the right reason (show it
failing in a mutated copy). Rerun the full command and report the counts.

Never skip tests, delete distinct assertions, add retries, or raise
`run_tool`'s `timeout=30` to go green.

Stop when the question is answered, when further benefit is unproven, or when
a change would trade correctness for speed. List the remaining uncertainties
without starting another round.
