---
name: release-notes
description: Prepare user-facing release notes for the Commit Tracker plugin from an inventoried git range, with the version read from manifest.json. Use when asked for release notes, a changelog entry, "what changed since X", or before bumping manifest.json's version. Skip for writing commit messages, README edits, and anything that tags, pushes or publishes; notes prepare a release, they do not authorize one.
metadata:
  version: "1"
---

# Release notes

> Adapted from morluto/rea `rea-changelog-update` (MIT, © 2026 morluto).

Turn a pinned range of git history into short notes about what changed *for
the person running the plugin*. This skill prepares text only. It does not
authorize editing `manifest.json`, creating `CHANGELOG.md`, tagging, pushing,
or creating a GitHub release. Ask for each of those separately.

## How this project ships

Restate these facts from the current checkout; do not assume them.

- **Version:** the `"version"` field of [manifest.json](../../../manifest.json).
  It was `1.1.0` at `73ce012`, set in the first commit `de7bf9f`, and never
  changed since.
- **Release records:** there are no git tags, no `CHANGELOG.md` and no
  `.github/` workflows.
- **Distribution:** users run `omarchy plugin add <git-url>`, which clones the
  default branch and runs `omarchy plugin validate` on it. `omarchy plugin
  update` fetches `origin HEAD`, fast-forwards, validates again, and rolls back
  if validation fails. Users receive the tip of the default branch, not a tag.
  `version` is the label they see.
- **Language:** commit subjects use Conventional Commit prefixes (`feat:`,
  `fix:`, `docs:`) with Portuguese descriptions. The notes are written in
  English, like the [README](../../../README.md).

## Inventory before prose

Keep every inventory file outside the tracked tree, for example in
`/tmp/ct-release/`.

1. **Pin the target.** Run `git fetch origin` (read-only; skip it if offline
   and say so). Record `git rev-parse origin/main HEAD` and `git status -sb`.
   Notes describe one exact SHA.
2. **Pin the baseline.** It is the last revision users already had. With no
   tags it is **unknown** unless the user names it. Show the candidates with
   `git log --format='%h %ad %s' --date=short -L '/"version"/,+1:manifest.json'`.
   At `73ce012` this shows a single entry: `1.1.0` arriving in `de7bf9f`
   together with all the code. Whether `a7dac6b` and `73ce012` shipped as
   `1.1.0` is unknown. Ask; do not guess. For a first release there is no
   range: describe the feature set from the README and label it that way.
3. **List the range:**

   ```bash
   git log --reverse --format='%H%x09%ad%x09%an <%ae>%x09%s' --date=short BASE..TARGET > /tmp/ct-release/inventory.tsv
   git log --format='%h %(trailers:key=Co-authored-by,valueonly,separator=%x2C)' BASE..TARGET
   git log --merges --oneline BASE..TARGET
   git diff --stat BASE..TARGET
   ```

   Record the commit count. Every commit lands in the notes or is consciously
   left out of them.
4. **Read the diffs of user-facing surfaces.** A subject is a hint, not the
   behavior:
   - `manifest.json`: `id`, `barWidget.defaults` and `barWidget.schema` keys.
     A renamed or removed key strands the value saved in `shell.json`.
   - `bin/commit-tracker`: `build_parser()` flags, the JSON keys and
     `"version": 1`, and the `{"version": 1, "error": …}` contract. Check with
     `git diff BASE..TARGET -- bin/commit-tracker | grep -E '^[+-].*add_argument'`.
   - `Widget.qml`: the `IpcHandler` with target `commit-tracker` (`refresh`,
     `togglePanel`, `toggleSettings`, `toggleMetric`) that keybinds call, plus
     clicks and keys as the README's "Using it" section describes them.
   - README "Install" and "Needs …": commands and dependencies (`python3`,
     `git`, `inotify-tools`, `wl-clipboard`).
   - Tests added in the range show what a fix claims. For example, `73ce012`
     adds `test_25` (malformed remote), `test_26` (push seen from any clone)
     and `test_27` (detached HEAD); the panel filter change is in
     `HistoryPanel.qml`.

## Write for users

Use one Markdown list item per line, under these headings:

- `### Highlights`: a few outcomes that define the release. Small releases
  need none.
- `### Changes`: new capabilities and behavior changes.
- `### Fixes`: correctness, reliability and safety. Example: "A malformed
  remote URL now only costs that repository its commit links; its commits
  still count."
- `### ⚠ Breaking changes`: renamed or removed settings, CLI flags, JSON
  fields, IPC functions, or new dependencies. Give each one a migration, such
  as `omarchy bar set io.github.lizindev.commit-tracker <key> <value>`.

Group entries by what the user touches: the strip, the history panel,
settings, the collector CLI, installation. Leave internal work (tests,
refactors, screenshots such as `a7dac6b`) out of the prose; it stays in the
inventory file.

Unknowns stay unknown. Write "verified" only for checks you ran at TARGET:
the [tests-audit](../tests-audit/SKILL.md) command, and `omarchy plugin
validate` on a `git archive TARGET` export. Run validate on an export, not on
the working tree: it refuses any symlink in the folder, and untracked
`.claude/skills/*` links would fail it.

Credits: at `73ce012`, history has one human author and no co-author
trailers, so there is no thanks line. Thank other people only with a verified
handle, once per contribution. Never thank bots or agent co-authors
(`Co-Authored-By: Claude …`), and never derive a GitHub handle from a name.

## Version, output and authority

- Propose the bump without making it. Breaking settings, CLI or JSON changes
  are major. A new capability is minor. Fixes only are patch. Edit
  `manifest.json` only when asked, and then rerun the tests and the
  validation above.
- Write the notes to `/tmp/ct-release/commit-tracker-VERSION.md` and show
  them. They go into a new `CHANGELOG.md` or a GitHub release only on request.
- Never tag, push or publish from this skill. Never rewrite pushed `main` to
  fix a commit message: users' `omarchy plugin update` fast-forwards only and
  refuses a rewritten branch. Correct the notes, not the history. Once tags
  exist, never move one to fix prose.
- If product commits land after TARGET, re-inventory before calling the notes
  current.
