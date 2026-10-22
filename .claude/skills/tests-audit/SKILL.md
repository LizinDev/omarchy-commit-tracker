---
name: tests-audit
description: Audit the Commit Tracker test suite (tests/test_commit_tracker.py, run locally with python3 -m unittest) for false passes, fixture drift against real git behavior, untested contracts, and measured cost, by perturbing behavior in isolated copies. Use for suite-level questions such as "does this test protect anything?", "what is untested?" or "why is the suite slow or flaky?". Skip for writing the test for a new feature, fixing one known failing test, or ordinary edits; there is no CI workflow to audit.
metadata:
  version: "1"
---

# Tests audit

Canonical copy: [`.agents/skills/tests-audit/SKILL.md`](../../../.agents/skills/tests-audit/SKILL.md).
Read it now and follow it; its `references/` and `agents/openai.yaml` sit beside it.

This is a stub, not a symlink: `omarchy plugin validate` refuses any symlink inside a plugin
folder (`/usr/share/omarchy/bin/omarchy-plugin-validate`), and this repository's root is the
plugin folder. Edit only the canonical copy; keep this frontmatter in step with it.
