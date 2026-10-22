# Oracle and workloads

Read this when measuring a change to `bin/commit-tracker`. Copy the scripts
into a task directory outside the checkout (for example `/tmp/ct-perf/tools/`)
and run them with `python3 -I`. They use only the standard library and the
system `git`.

## Synthetic workload: `make_workload.py`

This builds a pinned, isolated workload with `git fast-import`: one commit per
hour per repository, with distinct SHAs per repository.

`repo-000` also gets a trap: a recent commit sitting behind a commit with an
old committer date. A plain `--since` traversal stops at the old commit and
loses everything behind it. The workload also includes a clone of `repo-000`,
for dedupe and attribution.

```python
#!/usr/bin/env python3
"""Build a pinned synthetic workload for bin/commit-tracker.

usage: make_workload.py DIR REPOS COMMITS_PER_REPO
Creates DIR/home (isolated git identity) and DIR/roots/repo-NNN, each with a
linear history written by `git fast-import`, one commit per hour ending just
before NOW. repo-000 also gets an out-of-order trap (a recent commit hidden
behind an old committer date) and a clone at DIR/roots/copies/repo-000.
Prints the env and --now to use.
"""
import os, subprocess, sys

root, n_repos, n_commits = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
NOW = 1790000000  # fixed so every run sees the same window
home = os.path.join(root, "home")
roots = os.path.join(root, "roots")
os.makedirs(home)
os.makedirs(roots)
env = dict(os.environ, HOME=home, GIT_CONFIG_NOSYSTEM="1",
           GIT_CONFIG_GLOBAL=os.path.join(home, ".gitconfig"), TZ="UTC")

def git(*args, cwd=None, data=None):
    subprocess.run(["git", *args], cwd=cwd, env=env, input=data, check=True, capture_output=True)

git("config", "--global", "user.email", "owner@example.com")
git("config", "--global", "user.name", "Owner")

def commit(lines, ts_author, ts_committer, i, r):
    msg = f"r{r} c{i}\n".encode()
    body = f"{i}\n".encode()
    lines += [b"commit refs/heads/main",
              f"author Owner <owner@example.com> {ts_author} +0000".encode(),
              f"committer Owner <owner@example.com> {ts_committer} +0000".encode(),
              b"data %d" % len(msg), msg,
              b"M 644 inline f.txt", b"data %d" % len(body), body, b""]

for r in range(n_repos):
    path = os.path.join(roots, f"repo-{r:03d}")
    os.makedirs(path)
    git("init", "-q", "-b", "main", cwd=path)
    lines = []
    start = NOW - n_commits * 3600
    for i in range(n_commits):
        ts = start + i * 3600
        commit(lines, ts, ts, i, r)
    if r == 0:
        recent = NOW - 2 * 86400
        commit(lines, recent, recent, "trap-hidden", r)              # should count
        commit(lines, NOW - 400 * 86400, NOW - 400 * 86400, "old-dated", r)
        commit(lines, NOW - 3600, NOW - 3600, "tip", r)
    git("fast-import", "--quiet", cwd=path, data=b"\n".join(lines) + b"\n")
    git("checkout", "-q", "main", cwd=path)

git("clone", "-q", os.path.join(roots, "repo-000"), os.path.join(roots, "copies", "repo-000"))
print(f"HOME={home} GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL={home}/.gitconfig TZ=UTC")
print(f"--now {NOW} --root {roots}")
```

This is a stress shape (24 commits a day per repository), not a model of real
use. Pair it with the user's real roots and an empty root.

## Oracle: `git_oracle.py`

```python
#!/usr/bin/env python3
"""Independent per-day commit counts straight from `git log`.

usage: git_oracle.py --now TS --days N [--include-merges] --author P [--author P ...] REPO...
Lists every commit reachable from HEAD, branches, remote-tracking refs and tags
(no --since of any kind), keeps exact case-insensitive author matches (a
pattern with '@' is an email, otherwise a name), unions SHAs across repos and
buckets by local author date. Prints {"YYYY-MM-DD": commits} oldest first.
Shares no code with bin/commit-tracker.
"""
import argparse, json, subprocess
from datetime import datetime, timedelta

ap = argparse.ArgumentParser()
ap.add_argument("--now", type=int, required=True)
ap.add_argument("--days", type=int, required=True)
ap.add_argument("--include-merges", action="store_true")
ap.add_argument("--author", action="append", required=True)
ap.add_argument("repos", nargs="+")
a = ap.parse_args()

pats = [p.strip().casefold() for p in a.author]
def mine(email, name):
    return any(p == (email if "@" in p else name).strip().casefold() for p in pats)

today = datetime.fromtimestamp(a.now).date()
window = [today - timedelta(days=i) for i in range(a.days - 1, -1, -1)]
seen, counts = set(), {d: 0 for d in window}
for repo in a.repos:
    cmd = ["git", "-C", repo, "log", "HEAD", "--branches", "--remotes", "--tags",
           "--format=%H%x00%at%x00%ae%x00%an"]
    if not a.include_merges:
        cmd.insert(4, "--no-merges")
    out = subprocess.run(cmd, capture_output=True, text=True).stdout  # unborn HEAD: empty
    for line in out.splitlines():
        h, at, email, name = line.split("\x00")
        d = datetime.fromtimestamp(int(at)).date()
        if h in seen or d not in counts or not mine(email, name):
            continue
        seen.add(h)
        counts[d] += 1
print(json.dumps({d.isoformat(): c for d, c in counts.items()}))
```

It checks commit counts per day, which is the default metric. A change to line
counting needs its own oracle (`git show --numstat <sha>` per commit, minus
binaries and `LOCKFILE_BASENAMES`). A change to unpushed detection needs
`git log --branches --not --remotes` per repository, plus the any-clone push
evidence rule from `run()`.

## Running a comparison

```bash
T=/tmp/ct-perf/tools; W=/tmp/ct-perf/wl
python3 -I $T/make_workload.py $W 30 3000
export HOME=$W/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$W/home/.gitconfig TZ=UTC
repos=$(find $W/roots -name .git -prune -printf '%h\n' | sort)
python3 -I $T/git_oracle.py --now 1790000000 --days 7 --author owner@example.com --author Owner $repos > $T/oracle.json
python3 bin/commit-tracker --now 1790000000 --days 7 --root $W/roots \
  | jq -c '[.days[] | {key: .date, value: .commits}] | from_entries' > $T/got.json
diff <(jq -cS . $T/oracle.json) <(jq -cS . $T/got.json) && echo agrees
```

For the user's real roots, list repositories independently of
`discover_repos()`, then pass the user's `user.email` and `user.name` to the
oracle:

```bash
find "$ROOT" -mindepth 1 -maxdepth $((DEPTH + 1)) \( -name '.?*' ! -name .git \
  -o -name node_modules -o -name __pycache__ -o -name venv -o -name site-packages -o -name target \) \
  -prune -o -name .git -printf '%h\n' 2>/dev/null | sort
```

At `73ce012` this listed 25 repositories under `~` at depth 4, matching
`repoCount`. `find` does not stop at a repository, but the collector does, so
a repository nested inside another one appears only in `find`. Resolve any
mismatch before comparing counts: discovery is part of correctness.

## Recorded at 73ce012

Host: 12 CPUs, git 2.56.0, Python 3.14.8, warm caches. Ranges are over
repeated runs.

| Workload                                      | Strip run                  | History run (182 d, `--commits 300`) |
| --------------------------------------------- | -------------------------- | ------------------------------------ |
| Real `~`, depth 4, 25 repos, 78 git processes | 0.125–0.127 s              | 0.192 s                              |
| Synthetic 30 repos × 3000 commits + clone     | 0.18–0.19 s (user ≈0.55 s) | 0.99–1.06 s (user ≈2.4 s)            |
| Empty root                                    | 0.078 s                    | not measured                         |

Discovery under the real `~` took about 3 ms (cProfile, `discover_repos`), so
the git processes dominate there. On the synthetic workload, the history
window covers all of the roughly 90 000 commits, against about 3 600 in the
strip's 5 days. That the extra second is `--numstat` work is an inference;
no phase measurement has confirmed it.

| Implementation                       | Workload             | Result                                       |
| ------------------------------------ | -------------------- | -------------------------------------------- |
| `bin/commit-tracker` at `73ce012`    | 5 repos × 300, 7 days | agrees with the oracle                       |
| copy with `detect_since_flag()` → `--since` | same          | differs: 96/day instead of 120, all of `repo-000` lost |

The oracle therefore detects the regression that the unit suite misses.
Re-run both rows before trusting them on a later revision.
