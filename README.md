# Commit Tracker

A GitHub-style contribution strip for the [Omarchy](https://omarchy.org/) 4 bar:
one box per day for the last five days, shaded by how much you committed, in
your theme's accent color or GitHub's greens. Click it for the whole picture.

![Commit Tracker in the bar](preview.png)

## Using it

- **The strip.** One box per day, oldest on the left and today on the right
  (outlined). The shade follows that day's commits: none, 1, 2–3, 4–7, 8 or
  more — or lines changed (1, 50, 200, 800+) if you switch it. Hover a box for
  the date, commits, lines added and removed, and the repositories. A small dot
  after the strip means some of your commits are not on any remote yet; hover
  it to see where.
- **Left click: history panel.** A contribution graph for the last six months
  (or three months, or a year), your current and longest streak, and active
  days. A searchable repository picker narrows everything to one repository
  (so does clicking a repository name in the list), and clicking a day narrows
  the list to that day. Clicking a commit opens it on GitHub, GitLab or
  Bitbucket; a commit with nowhere to open (not pushed yet, or a remote with no
  web page) copies its hash instead. Keys: `r` refresh, `s` settings, `a`
  clear the filters, `Esc` close.
- **Right click: settings.** Days shown, commits or lines, theme or GitHub
  colors, graph length, outline today, the unpushed dot, and merge commits.
  Every change is saved to `shell.json` straight away.
- **Middle click** refreshes.

Colors come from the active Omarchy theme (its accent mixed into the theme
background) and change with it when you switch themes. With GitHub colors the
dark or light set is picked from how dark the theme is.

## How it counts

- Finds git repositories under `~`, up to four folders deep. Hidden folders,
  `node_modules`, virtualenvs and `target` are skipped, and so are bare
  repositories.
- Counts commits you authored: your git `user.email` and `user.name`, plus each
  repository's own identity if it sets one. Matching is exact and
  case-insensitive. A repository with no identity at all is skipped with a
  warning rather than counted for everyone.
- Looks at every local branch, remote-tracking branch and tag, so work pushed
  from another machine shows up once you fetch it.
- Buckets by author date on your local calendar. Merge commits are skipped by
  default. A commit present in several clones counts once, credited to the
  least nested copy.
- Repositories are named by folder. When two clones share a folder name, the
  least nested keeps it and the other gets its parent folder as a prefix.
- Lines changed ignore binary files and lockfiles (`package-lock.json`,
  `Cargo.lock`, `uv.lock`, …).
- "Not pushed" means on a local branch but in no remote-tracking branch, and
  only counts in repositories that have a remote at all.
- Refreshes about two seconds after a commit (an `inotifywait` on each
  repository's reflog), every five minutes otherwise, at midnight, and on
  middle click. An open history panel follows along.

On a machine with about twenty repositories a count takes about a tenth of a
second, and nothing is written to the repositories. The collector walks each
repository's whole history, so a commit sitting behind an out-of-order date is
never skipped; that costs roughly 0.3 s per 100 000 commits, and a tenth of
that once git has written a commit-graph (any `git gc` does).

## Install

Needs Omarchy 4, `python3`, `git`, `inotify-tools` and `wl-clipboard` (all part
of a standard Omarchy install).

From GitHub:

```bash
omarchy plugin add https://github.com/LizinDev/omarchy-commit-tracker.git --enable --yes
omarchy bar move io.github.lizindev.commit-tracker --section left --index 0
```

From a local checkout:

```bash
rsync -a --delete --exclude .git --exclude tests --exclude __pycache__ \
  ./ ~/.config/omarchy/plugins/io.github.lizindev.commit-tracker/
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.lizindev.commit-tracker --section left --index 0
```

The plugin folder must be a real copy: `omarchy plugin validate` rejects
symlinks inside it, and the shell's file watcher does not follow a symlinked
folder. After changing any `.qml` file, run `omarchy restart shell` — on
Omarchy 4.0.3 the automatic plugin reload rebuilds the widget from its cached
component, so QML edits only appear after a restart. Changes to
`bin/commit-tracker` apply on its next run.

## Settings

The right-click menu covers the everyday ones. All of them live on the widget's
entry in `~/.config/omarchy/shell.json` and apply as soon as the file is saved:

```bash
omarchy bar set io.github.lizindev.commit-tracker days 7
omarchy bar set io.github.lizindev.commit-tracker roots '["~/Projects", "~/Work"]' --json
```

| Key | Default | Meaning |
|---|---|---|
| `days` | `5` | Boxes in the strip (1–31). |
| `metric` | `"commits"` | Shade by `commits` or `lines`. |
| `appearance` | `"theme"` | `theme` colors or `github` greens. |
| `color` | `"accent"` | With theme colors: a theme role (`accent`, `foreground`, `urgent`, `muted`) or a hex color. |
| `highlightToday` | `true` | Outline today's box. |
| `showUnpushed` | `true` | Show the dot for commits that are not pushed. |
| `graphWeeks` | `26` | Weeks in the history graph (4–53). |
| `includeMerges` | `false` | Count merge commits (they add no lines). |
| `roots` | `["~"]` | Folders to search for repositories (array or comma-separated). |
| `maxDepth` | `4` | Folder levels below each root to search. |
| `authors` | `[]` | Emails or names to count; empty uses your git identity. |
| `levels` | `"default"` | Four ascending lower bounds, e.g. `"1,3,6,10"`. |
| `refreshIntervalSec` | `300` | Fallback poll; commits already refresh within seconds. |

For keybinds and scripts:

```bash
omarchy-shell shell toggle io.github.lizindev.commit-tracker   # history panel
omarchy-shell commit-tracker toggleSettings
omarchy-shell commit-tracker toggleMetric
omarchy-shell commit-tracker refresh
```

## The collector

`bin/commit-tracker` does the counting and prints one JSON object. Run it by
hand to see what the widget sees:

```bash
bin/commit-tracker --pretty
bin/commit-tracker --days 7 --root ~/Projects --metric lines --pretty
bin/commit-tracker --history-days 182 --commits 50 --pretty   # what the panel loads
```

```json
{
  "version": 1,
  "metric": "commits",
  "levelMode": "default",
  "thresholds": [1, 2, 4, 8],
  "days": [
    {"date": "2026-09-13", "commits": 4, "added": 120, "deleted": 30, "files": 7, "level": 3,
     "repos": [{"name": "my-app", "commits": 3, "added": 100, "deleted": 20}]}
  ],
  "totals": {"commits": 4, "added": 120, "deleted": 30},
  "repoCount": 19,
  "unpushed": {"commits": 2, "repos": [{"name": "my-app", "commits": 2}]},
  "watch": ["/home/me/Projects/my-app/.git/logs"],
  "warnings": [],
  "history": {
    "days": ["… one entry per day, same shape as above …"],
    "commits": [{"hash": "…", "short": "a1b2c3d", "repo": "my-app", "subject": "Fix the thing",
                 "ts": 1789337917, "date": "2026-09-13", "added": 12, "deleted": 3,
                 "pushed": true, "url": "https://github.com/me/my-app/commit/…"}],
    "repos": [{"name": "my-app", "commits": 41, "url": "https://github.com/me/my-app"}],
    "streak": {"current": 3, "longest": 12},
    "totals": {"commits": 97, "added": 5120, "deleted": 1873, "activeDays": 38}
  }
}
```

`days` always holds exactly `--days` entries, oldest first, ending today;
`history` appears only with `--history-days`. Commit links are built from each
repository's remote, strictly: only a plain `https://host/path` survives —
credentials, ports, query strings and fragments are dropped, and anything
unusual (odd characters, dot segments, an IP address) gets no link. Errors are reported as
`{"version": 1, "error": "…"}` with exit status 1.

## Limitations

- Only repositories on this machine are counted; commits made elsewhere appear
  after a fetch.
- A rebased or cherry-picked copy gets a new hash and counts separately while
  the old one is still reachable (for example, before a force-push).
- A remote that uses an SSH host alias (`git@github-work:me/repo`) gets no
  commit links: the real host is only in your SSH config.
- Git filters by committer date, so a commit whose committer date is more than
  a day earlier than its author date can be missed. Normal workflows never
  produce that.

## Development

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

`Widget.qml` is the bar widget, `HistoryPanel.qml` and `SettingsMenu.qml` its
two popups, `Heatmap.qml` the graph, and `bin/commit-tracker` the collector;
the JSON above is the contract between them.
