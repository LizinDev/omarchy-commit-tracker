---
name: performance-optimization
description: Measure and reduce the cost of bin/commit-tracker runs, using git log itself as the correctness oracle. Covers repository discovery under roots and maxDepth, the per-repository git processes behind every bar refresh, and the second --history-days run behind the history panel. Use when a refresh or the panel feels slow, before adding caching, indexing or parallelism, or when changing discovery or the git queries. Skip for test-suite speed (use tests-audit), QML rendering or layout, and changes with no measured cost.
metadata:
  version: "1"
---

# Performance optimization

Canonical copy: [`.agents/skills/performance-optimization/SKILL.md`](../../../.agents/skills/performance-optimization/SKILL.md).
Read it now and follow it; its `references/` and `agents/openai.yaml` sit beside it.

This is a stub, not a symlink: `omarchy plugin validate` refuses any symlink inside a plugin
folder (`/usr/share/omarchy/bin/omarchy-plugin-validate`), and this repository's root is the
plugin folder. Edit only the canonical copy; keep this frontmatter in step with it.
