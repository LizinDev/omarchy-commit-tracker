---
name: performance-optimization
description: Measure and reduce the cost of bin/commit-tracker runs, using git log itself as the correctness oracle. Covers repository discovery under roots and maxDepth, the per-repository git processes behind every bar refresh, and the second --history-days run behind the history panel. Use when a refresh or the panel feels slow, before adding caching, indexing or parallelism, or when changing discovery or the git queries. Skip for test-suite speed (use tests-audit), QML rendering or layout, and changes with no measured cost.
metadata:
  version: "1"
---

# Performance optimization

> Adapted from morluto/rea `rea-analysis-optimization` (MIT, © 2026 morluto).

Find a concrete source of unnecessary work in a refresh, change it where it is
owned, and show that the output is unchanged. A measured decision to leave the
code alone is a valid outcome, and at today's scale it is the likely one.

This skill does not authorize changing the JSON contract between the collector
and the widget (see the [README](../../../README.md), "The collector"),
writing into scanned repositories ("nothing is written to the repositories"),
or committing. Keep raw output in `/tmp/ct-perf/`. Output from a real home
directory holds other repositories' paths, subjects and remote URLs: that is
data to measure, not something to paste into reports.

## Pin what one refresh costs

**Triggers ([Widget.qml](../../../Widget.qml)).** A refresh starts on the poll
`Timer` (`refreshIntervalSec`, default 300 s); on `watchDebounce`, 1.5 s after
`inotifywait` sees a reflog write; on `refreshDebounce`, 300 ms after a
settings change or midnight; and on a middle click or `omarchy-shell
commit-tracker refresh`. Only the leader instance runs it (`pollTick()`).
`runCollector()` queues at most one follow-up run.

**Strip run** (`run()` in [bin/commit-tracker](../../../bin/commit-tracker)):

1. `resolve_roots()`, then `discover_repos()`: `os.scandir` down to
   `maxDepth`, skipping dot directories, `PRUNE_DIR_NAMES` and symlinks, and
   stopping at a repository.
2. `git config --global` twice (skipped with `--author`), then
   `git --version` (`detect_since_flag()`).
3. Per repository, in up to 8 threads: `git config --local --list`;
   `git log <refs> --since-as-filter=… --numstat`; and, when a remote exists,
   the all-time `git log --branches --not --remotes`.

That is about 3 + 2–3 × N git processes. `--since-as-filter` walks all
reachable history; the README puts that at about 0.3 s per 100 000 commits.

**History run.** `openPanel()` runs `historyCommand`: the strip command plus
`--history-days=<whole weeks>` and `--commits=300`. Its top-level output is
the strip itself (`test_28` holds that), so while a panel is open
`runCollector()` hands every refresh to that instance's `refreshHistory()`
and `applyHistory()` applies the strip too: one scan per refresh, not two.
A strip result from elsewhere (a peer's) still restarts `historyDebounce`
(400 ms).

## Correctness oracle: git log itself

Scripts and recipes are in
[references/oracle-and-workloads.md](references/oracle-and-workloads.md).

- **Same output.** Before and after, with identical arguments and a fixed
  `--now`, the JSON must match after
  `jq -S 'del(.generatedAt) | .warnings |= sort'`. Warnings are sorted
  because, until 2026-10-25, their order followed thread completion; they
  now follow repository order.
- **Agreement with git.** `git_oracle.py` counts commits per day from
  `git log HEAD --branches --remotes --tags` with no `--since`, and must equal
  `days[].commits`. It shares no code with the collector: comparing the
  collector with itself proves nothing.
- **Semantics to keep:**
  - commits behind an out-of-order committer date (no test covers this one;
    see [tests-audit](../tests-audit/SKILL.md));
  - a detached HEAD, and commits reachable only from remote refs;
  - SHA dedupe, credited to the least nested clone;
  - the merges flag, and lockfile and binary exclusion from line counts;
  - unpushed counted only where a remote exists;
  - a repository with no identity contributing nothing.

An empty result proves absence only within the scanned roots and depth.

## Locate the earliest unnecessary work

Measure by phase (discovery, git processes, aggregation, JSON) before choosing:

| Observed cost                          | Candidate correction                                                      | Condition to establish                                                 |
| -------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Discovery dominates (big `~`, depth 8) | Narrower `roots`/`maxDepth` (user settings), or prune a proven-useless name | No user repository sits under a pruned name; README states the rule     |
| Two scans per refresh, panel open      | Done: the history run feeds the strip while the panel is open              | `test_28`; `historyKey` covers the strip, since `historyCommand` extends `collectorCommand` |
| `--numstat` volume in the history run  | Compute line stats only where they are needed                             | The lines-shaded graph and per-repository stats stay exact             |
| Whole-history walk in a huge repo      | Leave it: correctness needs it. A commit-graph comes from the user's `git gc` | The collector stays read-only                                          |
| Fixed startup per run                  | Done for imports (`concurrent.futures`, `secrets`); what is left is the interpreter, `argparse` (~13 ms on 3.14) and 3 git processes | Leave `argparse`: its errors and abbreviations are contract |

Do not add a cache, index or daemon without naming the work it removes, along
with its **key, owner, invalidation and lifetime**. The collector keeps no
state between runs, and that is worth keeping. A cross-run cache would need to
key on every ref tip, the config, the identity, the window, the flags and the
timezone. Reflog watching only sees repositories already discovered, and
nothing may be written inside a scanned repository.

## Measure equivalent completed runs

- Use bash `time` (real, user, sys), three or more runs per variant,
  alternating before and after. For phases, use
  `python3 -m cProfile -s cumtime bin/commit-tracker --now NOW`; its count of
  `subprocess.run` calls is the number of git processes.
- Use three workloads: the user's real roots; the pinned synthetic workload
  from the reference; and an empty root, for fixed cost. Measuring only one
  size hides regressions on the others.
- Dropping file caches needs root. Without it, report warm runs only and say
  so.

The baselines recorded at `73ce012` and on 2026-10-25 are
in the reference: real `~`, 25–26 repositories, a strip run of about 0.115 s
and a history run of about 0.19 s. At
that scale a 5-minute poll costs nothing measurable. Only the history run on
heavy histories (about 1 s for the synthetic 30 × 3000) merits a look, and
only once a real workload shows it.

## Finish

Report:

- the bottleneck and the change made where it is owned;
- the semantics preserved;
- the checks run: the test command, the oracle on each workload, and the
  normalized diff;
- before and after numbers with the workload and host;
- what stays unmeasured (cold caches, panel rendering).

Update the README's quoted numbers only when edits are authorized. Stop once
the shown bottleneck is fixed, or when further gains are speculative.
