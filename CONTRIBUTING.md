# Contributing

Bug reports, counts that look wrong, and pull requests are welcome. This page
covers how the repository is laid out and what a change needs before it lands.

## Layout

```
manifest.json          plugin manifest (id, bar widget, settings schema)
Widget.qml             the bar strip; owns the data, the collector runs and the watcher
HistoryPanel.qml       left-click panel: GitHub id, graph, scope row, commit timeline, streak rail
Heatmap.qml            the contribution graph
SettingsMenu.qml       right-click menu
History.js, Palette.js shared helpers (pure functions)
bin/commit-tracker     the collector: stdlib Python, prints one JSON object
tests/                 unittest suite on synthetic git repositories
tools/lint-qml         qmllint against the installed shell
.agents/skills/        project skills: performance, test audit, release notes
```

The JSON the collector prints is the contract between it and the QML; the
README's "The collector" section documents it.

## Setup

You need Omarchy 4, Python 3.11 or newer, git 2.32 or newer, `inotify-tools`,
and [uv](https://docs.astral.sh/uv/) for the linters.

```bash
make dev      # copy into ~/.config/omarchy/plugins/ and restart the shell
make check    # lint (Python, shell, QML), tests, manifest validation
```

QML changes need `make dev` (the shell does not hot-reload third-party
widgets reliably). A collector change applies on the next refresh: middle
click the strip, or `omarchy-shell commit-tracker refresh`.

`tools/lint-qml` catches syntax and import errors. It cannot follow
properties through `root.` in inline components, so open the strip, the panel
and the menu after a QML change.

## The collector

- **Read-only.** It never writes to a scanned repository; git runs with
  `GIT_OPTIONAL_LOCKS=0`.
- **Keep the verified behavior.** SHA deduplication with credit to the least
  nested clone, `--since-as-filter`, the fixed levels, the strict link parser,
  the per-run record marker, push evidence from any clone and detached HEADs
  all came from reproductions ([DEVLOG.md](DEVLOG.md)). Change one only with a
  test that shows the new behavior is right.
- **Performance work** follows `.agents/skills/performance-optimization`:
  measure first, and prove the output identical (normalized JSON, plus its
  independent `git log` oracle) before claiming a speedup.

## Privacy

Run against a real home directory, the collector prints every repository's
name, folder and commit subjects. Never put that output, or a screenshot of
real data, in an issue, a commit or the README. For screenshots, point the
widget at synthetic repositories (`omarchy bar set io.github.lizindev.commit-tracker roots '["/tmp/demo"]' --json`)
and set `roots` back afterwards.

## Tests

`make test` runs the suite (75 tests, a few seconds). Tests build their own
repositories in temporary folders with a fixed `--now`; never point a test at
a real home directory. When you fix a bug, add a test that fails without the
fix, and check that it does (`.agents/skills/tests-audit` explains how).

## Style

- QML follows the shell: `Style` sizes, `Commons.Color` roles, the bar's font,
  the theme's corner radius. No hard-coded colors or pixel sizes.
- Comments explain why, in full sentences.
- Commit messages are one line in the conventional form (`feat:`, `fix:`,
  `perf:`, `docs:`, `chore:`).
- Record user-visible changes in CHANGELOG.md under Unreleased, and the
  reasoning behind non-obvious ones in DEVLOG.md.

## Releasing

Bump `version` in `manifest.json` and `pyproject.toml`, move the Unreleased
entries in CHANGELOG.md under the new version, tag `vX.Y.Z` and publish a
GitHub release with that section as its notes (`.agents/skills/release-notes`
helps inventory the range).
