# Perturbation in isolated copies

Read this before mutating anything. The checkout is never the experiment.

## Copy, mutate, run, discard

```bash
A=/tmp/ct-audit; mkdir -p "$A/base"
git archive HEAD | tar -x -C "$A/base"
```

`git archive HEAD` exports the committed tree only: no untracked files, no
`__pycache__`, no local edits. To audit uncommitted work, record
`git status --porcelain` and copy the working tree with
`rsync -a --exclude .git ./ "$A/wip/"` instead.

Make one copy per mutation (`$A/mut-<name>`), change exactly one behavior,
then run the same command the baseline used, from inside the copy:

```bash
cd "$A/mut-<name>" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3
```

The tests resolve `bin/commit-tracker` relative to their own file, so the copy
tests its own mutated collector. Record the failing test names
(`grep -E '^(FAIL|ERROR):'`) and *why* each fails. A failure caused by an
unrelated crash (an `ERROR` from a syntax slip) is not evidence of protection.
Delete the copy afterwards.

Apply mutations with a checked replacement, so a mutation that matched nothing
cannot silently produce a "green" result:

```bash
python3 - "$A/mut-since/bin/commit-tracker" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
n = s.replace('            return "--since-as-filter"\n', '            return "--since"\n')
assert n != s, "mutation did not apply"; open(p, "w").write(n)
EOF
```

## Recorded at 73ce012

| Copy           | Replacement                                                                 | Result              |
| -------------- | --------------------------------------------------------------------------- | ------------------- |
| `mut-detached` | `head_args = ["HEAD"] if head_is_detached(repo_path) else []` → `head_args = []` | `test_27` FAIL      |
| `mut-author`   | remove the `author_matches(...)`/`continue` pair in the windowed loop of `process_repo()` | `test_12c` FAIL     |
| `mut-since`    | `detect_since_flag()` returns `"--since"`                                   | 74 OK (unprotected) |

These are observations for that revision. Recheck them against the current
code before relying on them.

## Candidate mutations not yet run

These are hypotheses, ranked by how much a silent regression would cost the
user. For each, name the test you expect to fail before running it.

- `attribution_order()` sorts by path only (clone credit; expect `test_23`).
- `pushed_by_sha` ignores clones other than the credited one (expect `test_26`).
- `remote_to_web_url()` keeps the port or the userinfo (expect `test_18` and
  the hardening tables).
- `summarize_numstat()` counts lockfiles (expect `test_07`).
- `RECORD_MARK` becomes a fixed string (expect `test_22`).
- `_bucket_records_by_day()` uses UTC rather than the local date (expect
  `test_02a`).
- In `process_repo()`, the unpushed query runs even with no remote. Expect
  *no* failure, because `run()` filters by `has_remote` again. A green result
  would mean the "must never cost an extra git process" comment has no test.

## What a mutation cannot tell you

A mutation can only show that the suite reacts to code paths inside
`bin/commit-tracker`. It says nothing about `Widget.qml` parsing the JSON, the
`inotifywait` watcher, or `History.js`. Those have no executable check in this
repository, so report them as unavailable evidence, not as covered.
