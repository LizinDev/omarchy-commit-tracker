# Devlog

What was found, decided and measured while building Commit Tracker, newest
first. The README says what the plugin does; this says why it is the way it
is. Several choices below came out of a cross-review and a reproduction; do
not reverse one without a test that shows the alternative is right.

## 2026-10-25 — 1.2.0: the logbook

Five directions were mocked up at real scale with synthetic data. The user
picked the commit list of one ("Logbook": a dense timeline grouped by day)
and the structure of another ("Activity Rail": the streak numbers on a slim
rail instead of a row of their own), and asked for their GitHub id in place
of a title and for the rail on the bar's side.

- **GitHub id.** A `githubId` setting, or the GitHub owner behind most of the
  commits in the repositories with GitHub remotes. It identifies whose
  activity this is better than a generic title.
- **Rail side.** The widget finds its own entry in the bar's `layoutConfig`
  and puts the rail on that side, so it hangs under the bar icon.
- **One surface.** The first attempt at integrating the graph boxed it in a
  card with the profile and the picker; it read as a fourth block. Instead,
  the graph sits on the panel itself, and the graph's weekday labels, the
  scope row and the commit timeline share one left gutter. Columns step by an
  exact share of the width (each column's x rounded), so the last column ends
  level with the list; gaps then differ by a pixel, which reads better than a
  ragged right edge.
- **Scope as text.** The repository picker's boxed trigger became a text
  control in the style of Omarchy's newer panels. It still opens the shell's
  own `SearchableDropdown`: its trigger is kept but transparent, because the
  list is a `QQC.Popup` on the overlay and does not inherit the trigger's
  opacity.
- **A live readout.** The line under the GitHub id sums up the period and,
  under the pointer, reads out the hovered day or commit; hovering a commit
  outlines its day on the graph. That ties the three parts together without
  adding chrome.

Screenshots for the README come from a seeded synthetic workload: the real
home directory holds private repository names and commit subjects.

## 2026-10-25 — 1.1.1: half the work with the panel open

Measured on the real home directory (26 repositories): a strip run took
127 ms and a history run 201 ms, and with the panel open every refresh ran
both. The history run's top level is exactly a strip run (a test now holds
that), so while the panel is open it serves both. About 16 of a strip run's
milliseconds were `import concurrent.futures`, which pulls in `logging`; a
plain thread pool replaced it. Removing `dataclasses` was measured and
refuted: `argparse` imports it anyway on Python 3.14. Collapsing the two
`git config --global` calls into one was also refuted (no measurable gain).

## 2026-09-14 — 1.1.0: decisions from the cross-review

- **Deduplicate by SHA.** An earlier key of date, email and subject merged two
  distinct commits made in the same second. A clone's copy is credited to the
  least nested clone, so a backup or audit copy never takes the credit.
- **`--since-as-filter`, not `--since`.** Plain `--since` stops walking at the
  first commit with an old committer date and silently loses newer commits
  behind it (reproduced with a rebased history). Filtering walks the whole
  history: about 0.3 s per 100,000 commits, a tenth of that with a
  commit-graph.
- **Fixed levels.** Shades start at 1, 2, 4 and 8 commits (1, 50, 200 and 800
  lines). Quartiles over five boxes were unstable from day to day.
- **Strict commit links.** Only `https://host/path` with a dotted host survives;
  credentials, ports, queries, fragments and SSH aliases are dropped, because
  the URL comes from repository config and opens in a browser.
- **A random record marker per run**, so a commit subject cannot forge extra
  records in the parsed `git log` output.
- **Push evidence from any clone**, and a detached HEAD counts (and counts as
  unpushed): both came from reproductions during the review.
- **Refresh by reflog.** `inotifywait` on each repository's `logs/` directory
  refreshes about two seconds after a commit; the poll is only a fallback.
