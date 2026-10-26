# Changelog

Notable changes to Commit Tracker. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions
follow [Semantic Versioning](https://semver.org/). The reasoning behind the
non-obvious changes is in [DEVLOG.md](DEVLOG.md).

## [Unreleased]

### Added
- `make check`, `make dev` and the rest of a `Makefile` for development.
- `tools/lint-qml`, which lints the QML against the installed Omarchy shell.
- CI on GitHub Actions: the tests on Python 3.11 and 3.14, ruff, shellcheck.
- CONTRIBUTING.md, DEVLOG.md, this changelog, issue and pull request templates.

### Changed
- The collector passes ruff (no behavior change; output checked identical).

## [1.2.0] - 2026-10-25

### Added
- The history panel opens on your GitHub id: the new `githubId` setting, or
  the owner behind most of your commits among your repositories' GitHub
  remotes.
- A slim rail with your current streak, longest streak and active days, on
  the same side of the panel as the widget sits in the bar.
- A live readout under the GitHub id: the day or commit under the pointer.
- While you hover a commit, the graph outlines its day.

### Changed
- The commits read as a logbook: a timeline grouped by day, more densely
  packed.
- The contribution graph spans the panel, its columns ending level with the
  commit list, and shares one left edge with the scope row and the timeline.
- The repository picker is a text control (`All repositories`) that opens the
  same searchable list; a picked day shows as a filter you can clear.

### Removed
- The "Commit activity" title, the "Click a day to filter" hint and the
  "Commits" header, which the new layout made redundant.

## [1.1.1] - 2026-10-25

### Changed
- With the history panel open, one collector run per refresh serves both the
  strip and the panel (it was two).
- The panel and the settings menu are built the first time they open.
- The graph's hover and selection outlines no longer re-evaluate every cell.
- The collector starts about 16 ms faster (plain threads instead of
  `concurrent.futures`, no `secrets` import).
- Warnings come out in repository order, the same on every run.

## [1.1.0] - 2026-09-14

### Added
- The bar strip: one box per day for the last five days (up to 31), shaded by
  commits or lines changed, in the theme's accent or GitHub's greens, with
  today outlined and a dot for commits no remote has yet.
- The history panel: a GitHub-style contribution graph (13, 26 or 52 weeks),
  current and longest streak, active days, a searchable repository filter,
  and the commits, which open on GitHub, GitLab or Bitbucket or copy their
  hash.
- The settings menu, saved straight to `shell.json`.
- Refresh within about two seconds of a commit, through `inotifywait` on each
  repository's reflog, with a five-minute poll as a fallback.
- IPC: `omarchy-shell commit-tracker refresh|togglePanel|toggleSettings|toggleMetric`.

### Fixed
- A malformed remote URL costs a repository its links, not its commits.
- A commit pushed from any clone counts as pushed in every clone.
- Commits on a detached HEAD count, and count as unpushed.
- A repository filter that falls out of the graph's window clears itself.

[Unreleased]: https://github.com/LizinDev/omarchy-commit-tracker/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/LizinDev/omarchy-commit-tracker/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/LizinDev/omarchy-commit-tracker/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/LizinDev/omarchy-commit-tracker/releases/tag/v1.1.0
