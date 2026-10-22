# Measuring the suite

Read this before claiming the suite got faster or slower.

## Equivalent completed work

Record the revision, the command, the `Ran N tests` count, skips (there are
none at `73ce012`), the exit status, and the host: CPU count, Python and git
versions, and whether other heavy work was running. A run with fewer tests,
an earlier abort or a narrower selection does not count as acceleration.
Unittest's own `Ran N tests in X s` excludes interpreter startup. Bash's
`time` keyword covers the whole command:

```bash
time PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>/dev/null
```

`user`+`sys` larger than `real` means git children ran in parallel. Repeat at
least three times and report the range, not one number. The first run after
boot pays cold file caches. Dropping caches needs root, so if you cannot,
report warm runs only and say so.

## Where the time goes

Time a single class or test to see the split. Pure-function classes take
milliseconds. `CommitTrackerCLITests` dominates, because each test runs
`git init`/`commit` several times and the collector one to three times:

```bash
python3 -m unittest -v test_commit_tracker.CommitTrackerCLITests 2>&1 | tail -3   # run from tests/
python3 -m unittest -v test_commit_tracker.RemoteToWebUrlTests 2>&1 | tail -3
```

Run these from `tests/`, so the module name resolves. The tests locate
`bin/commit-tracker` from their own path, so the working directory does not
change what they test.

## Changes that keep the gate

- Reusing one repository across tests is only safe when no test mutates it and
  each test still gets its own `HOME` and global config. `test_20` depends on
  having no identity, and `test_09` corrupts `HEAD`.
- Parallel test runners are not in the standard library. Adding one is a new
  dependency, which needs its own justification.
- Never trade an assertion, a scenario or the `--now`/`TZ` determinism for
  speed. A 5 s suite rarely justifies structural change; say so when measured.
