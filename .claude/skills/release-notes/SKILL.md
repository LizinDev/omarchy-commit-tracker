---
name: release-notes
description: Prepare user-facing release notes for the Commit Tracker plugin from an inventoried git range, with the version read from manifest.json. Use when asked for release notes, a changelog entry, "what changed since X", or before bumping manifest.json's version. Skip for writing commit messages, README edits, and anything that tags, pushes or publishes; notes prepare a release, they do not authorize one.
metadata:
  version: "1"
---

# Release notes

Canonical copy: [`.agents/skills/release-notes/SKILL.md`](../../../.agents/skills/release-notes/SKILL.md).
Read it now and follow it; its `references/` and `agents/openai.yaml` sit beside it.

This is a stub, not a symlink: `omarchy plugin validate` refuses any symlink inside a plugin
folder (`/usr/share/omarchy/bin/omarchy-plugin-validate`), and this repository's root is the
plugin folder. Edit only the canonical copy; keep this frontmatter in step with it.
