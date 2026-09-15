"""Tests for bin/commit-tracker.

Two layers:
  * Direct unit tests against the pure functions inside the script
    (dedupe_key, author_matches, level_for_value, compute_thresholds, ...),
    loaded in-process via importlib since the script has no .py suffix.
  * End-to-end tests (CommitTrackerCLITests) that build synthetic git repos
    under a temp dir, isolate git config (HOME / GIT_CONFIG_NOSYSTEM /
    GIT_CONFIG_GLOBAL), and invoke the script as a subprocess with an
    explicit --now and TZ for determinism, then assert on the JSON it prints.

Run from the project root with:
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
"""
from __future__ import annotations

import calendar
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL_PATH = REPO_ROOT / "bin" / "commit-tracker"


def _load_tool_module():
    loader = importlib.machinery.SourceFileLoader("commit_tracker_under_test", str(TOOL_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


ct = _load_tool_module()


def epoch(y, m, d, hh=12, mm=0, ss=0):
    """UTC epoch seconds for a wall-clock time -- use with TZ=UTC tests."""
    return calendar.timegm((y, m, d, hh, mm, ss, 0, 0, 0))


def iso(y, m, d, hh=0, mm=0, ss=0, offset="+0000"):
    return f"{y:04d}-{m:02d}-{d:02d}T{hh:02d}:{mm:02d}:{ss:02d}{offset}"


def find_day(data, date_str):
    for day in data["days"]:
        if day["date"] == date_str:
            return day
    raise AssertionError(f"date {date_str} not found in days: {[d['date'] for d in data['days']]}")


# ---------------------------------------------------------------------------
# Direct unit tests for the small, isolated pure functions.
# ---------------------------------------------------------------------------

class DedupeKeyTests(unittest.TestCase):
    """SHA-only dedupe (post-amendment): the key is just the commit hash."""

    def test_is_identity_function_on_hash(self):
        self.assertEqual(ct.dedupe_key("abc123"), "abc123")

    def test_distinguishes_different_hashes(self):
        self.assertNotEqual(ct.dedupe_key("abc123"), ct.dedupe_key("def456"))


class AuthorMatchesTests(unittest.TestCase):
    """Exact post-filter applied after git's substring-based pre-filter."""

    def test_email_pattern_requires_exact_match(self):
        self.assertTrue(ct.author_matches(["Foo@Example.com"], "foo@example.com", "Foo Bar"))
        self.assertFalse(ct.author_matches(["foo@example.com"], "notfoo@example.com", "Foo Bar"))

    def test_name_pattern_requires_exact_match_not_substring(self):
        self.assertTrue(ct.author_matches(["Ann"], "x@example.com", "Ann"))
        self.assertFalse(ct.author_matches(["Ann"], "x@example.com", "Joann Example"))

    def test_whitespace_and_case_insensitive(self):
        self.assertTrue(ct.author_matches([" ANN "], "x@example.com", "ann"))
        self.assertTrue(ct.author_matches(["  Foo@Example.com  "], "foo@example.com", "Foo"))

    def test_no_patterns_never_matches(self):
        self.assertFalse(ct.author_matches([], "x@example.com", "Ann"))

    def test_any_pattern_matching_is_enough(self):
        self.assertTrue(ct.author_matches(["nope@example.com", "Ann"], "x@example.com", "Ann"))


class LevelFunctionTests(unittest.TestCase):
    def test_zero_is_always_level_zero(self):
        self.assertEqual(ct.level_for_value(0, (1, 2, 4, 8)), 0)

    def test_default_commit_bounds_match_readme_buckets(self):
        # README.md: "none, 1, 2-3, 4-7, 8 or more".
        bounds = (1, 2, 4, 8)
        expectations = {0: 0, 1: 1, 2: 2, 3: 2, 4: 3, 7: 3, 8: 4, 1000: 4}
        for value, level in expectations.items():
            self.assertEqual(ct.level_for_value(value, bounds), level, f"value={value}")

    def test_compute_thresholds_default_mode_per_metric(self):
        mode, thresholds = ct.compute_thresholds("default", "commits", None)
        self.assertEqual((mode, thresholds), ("default", (1, 2, 4, 8)))
        mode, thresholds = ct.compute_thresholds("default", "lines", None)
        self.assertEqual((mode, thresholds), ("default", (1, 50, 200, 800)))

    def test_compute_thresholds_custom_mode_passthrough(self):
        mode, thresholds = ct.compute_thresholds("custom", "commits", (2, 5, 9, 15))
        self.assertEqual((mode, thresholds), ("custom", (2, 5, 9, 15)))


class ParseLevelsTests(unittest.TestCase):
    def test_auto_is_default_mode(self):
        self.assertEqual(ct.parse_levels("auto"), ("default", None))

    def test_default_keyword_is_default_mode(self):
        self.assertEqual(ct.parse_levels("default"), ("default", None))

    def test_valid_custom(self):
        self.assertEqual(ct.parse_levels("2,5,9,15"), ("custom", (2, 5, 9, 15)))

    def test_rejects_non_ascending(self):
        with self.assertRaises(ct.ArgError):
            ct.parse_levels("5,2,9,15")

    def test_rejects_non_positive(self):
        with self.assertRaises(ct.ArgError):
            ct.parse_levels("0,2,9,15")

    def test_rejects_wrong_count(self):
        with self.assertRaises(ct.ArgError):
            ct.parse_levels("1,2,3")

    def test_rejects_non_integer(self):
        with self.assertRaises(ct.ArgError):
            ct.parse_levels("a,b,c,d")


class ResolveWatchPathTests(unittest.TestCase):
    """Directly exercises the .git-file parsing (worktree/submodule) and the
    logs-vs-gitdir fallback used by the `watch` output key, without needing
    a full CLI round trip."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="resolve-watch-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_no_git_entry_at_all(self):
        os.makedirs(os.path.join(self.tmp, "plain"))
        self.assertIsNone(ct.resolve_watch_path(os.path.join(self.tmp, "plain")))

    def test_git_dir_without_logs_yet_falls_back_to_gitdir(self):
        # A brand new repo has no reflog until its first commit/ref update:
        # watch the gitdir itself so the widget sees "logs" appear later.
        repo = os.path.join(self.tmp, "fresh")
        os.makedirs(os.path.join(repo, ".git"))
        self.assertEqual(ct.resolve_watch_path(repo), os.path.join(repo, ".git"))

    def test_git_dir_with_logs(self):
        repo = os.path.join(self.tmp, "withlogs")
        os.makedirs(os.path.join(repo, ".git", "logs"))
        self.assertEqual(ct.resolve_watch_path(repo), os.path.join(repo, ".git", "logs"))

    def test_git_file_with_relative_gitdir_like_a_submodule(self):
        repo = os.path.join(self.tmp, "super", "sub")
        real_gitdir = os.path.join(self.tmp, "super", ".git", "modules", "sub")
        os.makedirs(repo)
        os.makedirs(os.path.join(real_gitdir, "logs"))
        with open(os.path.join(repo, ".git"), "w") as f:
            f.write("gitdir: ../.git/modules/sub\n")
        self.assertEqual(ct.resolve_watch_path(repo), os.path.join(real_gitdir, "logs"))

    def test_git_file_with_absolute_gitdir_like_a_worktree(self):
        repo = os.path.join(self.tmp, "wt")
        real_gitdir = os.path.join(self.tmp, "main", ".git", "worktrees", "wt")
        os.makedirs(repo)
        os.makedirs(os.path.join(real_gitdir, "logs"))
        with open(os.path.join(repo, ".git"), "w") as f:
            f.write(f"gitdir: {real_gitdir}\n")
        self.assertEqual(ct.resolve_watch_path(repo), os.path.join(real_gitdir, "logs"))

    def test_git_file_gitdir_without_logs_yet_falls_back_to_gitdir(self):
        repo = os.path.join(self.tmp, "wt2")
        real_gitdir = os.path.join(self.tmp, "main2", ".git", "worktrees", "wt2")
        os.makedirs(repo)
        os.makedirs(real_gitdir)  # gitdir exists, but no logs/ subdir yet
        with open(os.path.join(repo, ".git"), "w") as f:
            f.write(f"gitdir: {real_gitdir}\n")
        self.assertEqual(ct.resolve_watch_path(repo), real_gitdir)

    def test_git_file_pointing_nowhere_returns_none(self):
        repo = os.path.join(self.tmp, "broken")
        os.makedirs(repo)
        with open(os.path.join(repo, ".git"), "w") as f:
            f.write("gitdir: /nonexistent/path/at/all\n")
        self.assertIsNone(ct.resolve_watch_path(repo))


class RemoteToWebUrlTests(unittest.TestCase):
    """Table-driven: every input must drop credentials/ports and normalize
    to an https base, or return None. See remote_to_web_url's docstring --
    this is the only place a raw remote URL is read."""

    CASES = [
        ("git@github.com:owner/repo.git", "https://github.com/owner/repo"),
        ("git@github.com:owner/repo", "https://github.com/owner/repo"),
        ("ssh://git@github.com:22/owner/repo.git", "https://github.com/owner/repo"),
        ("ssh://github.com/owner/repo", "https://github.com/owner/repo"),
        ("https://user:pass@github.com:443/owner/repo.git", "https://github.com/owner/repo"),
        ("https://user:pass@github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("https://github.com/owner/repo/", "https://github.com/owner/repo"),
        ("https://github.com/owner/repo", "https://github.com/owner/repo"),
        ("git://github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("git@gitlab.com:group/subgroup/repo.git", "https://gitlab.com/group/subgroup/repo"),
        ("https://gitlab.example.com/group/sub/repo.git", "https://gitlab.example.com/group/sub/repo"),
        ("/home/user/bare-repo.git", None),
        ("file:///home/user/bare-repo.git", None),
        ("../sibling-repo", None),
        ("./sibling-repo", None),
        ("not a url at all", None),
        ("", None),
        (None, None),
    ]

    def test_table(self):
        for raw, expected in self.CASES:
            with self.subTest(raw=raw):
                self.assertEqual(ct.remote_to_web_url(raw), expected)

    def test_never_returns_the_raw_input_when_it_contains_credentials(self):
        result = ct.remote_to_web_url("https://user:secret-token@github.com/o/r.git")
        self.assertEqual(result, "https://github.com/o/r")
        self.assertNotIn("secret-token", result)
        self.assertNotIn("user", result)


class CommitUrlTests(unittest.TestCase):
    def test_default_pattern_for_github_and_unrecognized_hosts(self):
        self.assertEqual(ct.commit_url("https://github.com/o/r", "abc123"), "https://github.com/o/r/commit/abc123")
        self.assertEqual(ct.commit_url("https://codeberg.org/o/r", "abc123"), "https://codeberg.org/o/r/commit/abc123")
        self.assertEqual(ct.commit_url("https://git.example.com/o/r", "abc123"), "https://git.example.com/o/r/commit/abc123")

    def test_gitlab_pattern(self):
        self.assertEqual(ct.commit_url("https://gitlab.com/o/r", "abc123"), "https://gitlab.com/o/r/-/commit/abc123")
        self.assertEqual(ct.commit_url("https://gitlab.example.com/group/sub/r", "abc123"), "https://gitlab.example.com/group/sub/r/-/commit/abc123")

    def test_bitbucket_pattern(self):
        self.assertEqual(ct.commit_url("https://bitbucket.org/o/r", "abc123"), "https://bitbucket.org/o/r/commits/abc123")


class ComputeStreakTests(unittest.TestCase):
    def test_all_zero(self):
        self.assertEqual(ct.compute_streak([False] * 5), {"current": 0, "longest": 0})

    def test_run_through_today(self):
        self.assertEqual(ct.compute_streak([False, True, True, True]), {"current": 3, "longest": 3})

    def test_run_ending_yesterday_still_in_progress(self):
        self.assertEqual(ct.compute_streak([True, True, False]), {"current": 2, "longest": 2})

    def test_gap_of_two_or_more_breaks_current_but_not_longest(self):
        self.assertEqual(ct.compute_streak([True, True, False, False]), {"current": 0, "longest": 2})

    def test_longest_run_can_be_earlier_than_the_current_run(self):
        days = [True, True, True, True, False, True, True]
        self.assertEqual(ct.compute_streak(days), {"current": 2, "longest": 4})

    def test_single_day_window_active_and_inactive(self):
        self.assertEqual(ct.compute_streak([True]), {"current": 1, "longest": 1})
        self.assertEqual(ct.compute_streak([False]), {"current": 0, "longest": 0})

    def test_empty_window(self):
        self.assertEqual(ct.compute_streak([]), {"current": 0, "longest": 0})


# ---------------------------------------------------------------------------
# End-to-end CLI tests against synthetic repos.
# ---------------------------------------------------------------------------

class CommitTrackerCLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="commit-tracker-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        home = os.path.join(self.tmp, "home")
        os.makedirs(home, exist_ok=True)
        self.home = home
        self.base_env = dict(os.environ)
        self.base_env.update({
            "HOME": home,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.path.join(home, ".gitconfig"),
            "TZ": "UTC",
        })
        self.roots_dir = os.path.join(self.tmp, "roots")
        os.makedirs(self.roots_dir, exist_ok=True)

    # -- helpers ------------------------------------------------------

    def set_global_identity(self, email, name):
        subprocess.run(
            ["git", "config", "--global", "user.email", email],
            env=self.base_env, check=True, capture_output=True,
        )
        subprocess.run(
            ["git", "config", "--global", "user.name", name],
            env=self.base_env, check=True, capture_output=True,
        )

    def make_repo(self, relpath, local_email=None, local_name=None, bare=False):
        path = os.path.join(self.roots_dir, relpath)
        os.makedirs(path, exist_ok=True)
        cmd = ["git", "init", "-q"]
        if bare:
            cmd.append("--bare")
        subprocess.run(cmd, cwd=path, env=self.base_env, check=True, capture_output=True)
        if local_email:
            subprocess.run(["git", "config", "user.email", local_email], cwd=path, env=self.base_env, check=True, capture_output=True)
        if local_name:
            subprocess.run(["git", "config", "user.name", local_name], cwd=path, env=self.base_env, check=True, capture_output=True)
        return path

    def commit(self, repo, files=None, message="msg", adate=None, cdate=None,
               aemail=None, aname=None, cemail=None, cname=None,
               allow_empty=False, extra_env=None):
        env = dict(self.base_env)
        if adate:
            env["GIT_AUTHOR_DATE"] = adate
        if cdate or adate:
            env["GIT_COMMITTER_DATE"] = cdate or adate
        if aemail:
            env["GIT_AUTHOR_EMAIL"] = aemail
        if aname:
            env["GIT_AUTHOR_NAME"] = aname
        if cemail:
            env["GIT_COMMITTER_EMAIL"] = cemail
        if cname:
            env["GIT_COMMITTER_NAME"] = cname
        if extra_env:
            env.update(extra_env)
        if files:
            for relpath, content in files.items():
                full = os.path.join(repo, relpath)
                if content is None:
                    subprocess.run(["git", "rm", "-q", relpath], cwd=repo, env=env, check=True, capture_output=True)
                    continue
                parent = os.path.dirname(full)
                if parent:
                    os.makedirs(parent, exist_ok=True)
                mode = "wb" if isinstance(content, bytes) else "w"
                with open(full, mode) as f:
                    f.write(content)
                subprocess.run(["git", "add", "--", relpath], cwd=repo, env=env, check=True, capture_output=True)
        args = ["git", "commit", "-q", "-m", message]
        if allow_empty:
            args.append("--allow-empty")
        subprocess.run(args, cwd=repo, env=env, check=True, capture_output=True)
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, env=env, capture_output=True, text=True, check=True)
        return out.stdout.strip()

    def git(self, repo, *args, env=None):
        return subprocess.run(["git"] + list(args), cwd=repo, env=env or self.base_env, check=True, capture_output=True, text=True)

    def run_tool(self, args, env=None, timeout=30):
        full_env = dict(env if env is not None else self.base_env)
        cmd = [sys.executable, str(TOOL_PATH)] + list(args)
        return subprocess.run(cmd, env=full_env, capture_output=True, text=True, timeout=timeout)

    def run_tool_json(self, args, env=None, expect_exit=0):
        proc = self.run_tool(args, env=env)
        self.assertEqual(
            proc.returncode, expect_exit,
            f"exit={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}",
        )
        try:
            return json.loads(proc.stdout), proc
        except json.JSONDecodeError:
            self.fail(f"stdout was not valid JSON: {proc.stdout!r} (stderr={proc.stderr!r})")

    def default_args(self, now, days=5, roots=None, extra=None):
        roots = roots if roots is not None else [self.roots_dir]
        args = ["--now", str(now), "--days", str(days)]
        for r in roots:
            args += ["--root", r]
        if extra:
            args += extra
        return args

    # -- 1. per-day counts, other authors ignored, repo-local identity ----

    def test_01_per_day_counts_two_repos_repo_local_identity(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo1 = self.make_repo("repo1")
        self.commit(repo1, {"a.txt": "a\n"}, "commit r1a", adate=iso(2026, 3, 8, 10), aemail="owner@example.com", aname="Owner")
        self.commit(repo1, {"b.txt": "b\n"}, "commit r1b", adate=iso(2026, 3, 8, 11), aemail="owner@example.com", aname="Owner")
        self.commit(repo1, {"c.txt": "c\n"}, "commit r1c stranger", adate=iso(2026, 3, 9, 10), aemail="stranger@example.com", aname="Stranger")

        repo2 = self.make_repo("repo2", local_email="work@example.com", local_name="Work Person")
        self.commit(repo2, {"d.txt": "d\n"}, "commit r2a", adate=iso(2026, 3, 10, 9), aemail="work@example.com", aname="Work Person")
        self.commit(repo2, {"e.txt": "e\n"}, "commit r2b stranger", adate=iso(2026, 3, 10, 10), aemail="stranger2@example.com", aname="Stranger2")

        now = epoch(2026, 3, 10)
        data, _ = self.run_tool_json(self.default_args(now, days=5))

        d8 = find_day(data, "2026-03-08")
        d9 = find_day(data, "2026-03-09")
        d10 = find_day(data, "2026-03-10")
        self.assertEqual(d8["commits"], 2)
        self.assertEqual(d8["repos"], [{"name": "repo1", "commits": 2, "added": 2, "deleted": 0}])
        self.assertEqual(d9["commits"], 0)
        self.assertEqual(d10["commits"], 1)
        self.assertEqual(d10["repos"], [{"name": "repo2", "commits": 1, "added": 1, "deleted": 0}])
        self.assertEqual(data["totals"]["commits"], 3)
        self.assertEqual(data["repoCount"], 2)

    # -- 2. local-midnight bucketing + window edges -----------------------

    def test_02a_local_midnight_bucketing_sao_paulo(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        # 01:30 UTC = 22:30 the previous day in America/Sao_Paulo (fixed UTC-3).
        self.commit(repo, {"a.txt": "a\n"}, "late utc commit", adate=iso(2026, 4, 10, 1, 30), aemail="owner@example.com")

        now = epoch(2026, 4, 12)
        env = dict(self.base_env)
        env["TZ"] = "America/Sao_Paulo"
        data, _ = self.run_tool_json(self.default_args(now, days=5), env=env)

        d09 = find_day(data, "2026-04-09")
        d10 = find_day(data, "2026-04-10")
        self.assertEqual(d09["commits"], 1, f"expected the 01:30Z commit on 04-09 local; days={data['days']}")
        self.assertEqual(d10["commits"], 0)

    def test_02b_window_edges_inclusive_start_exclusive_before_future_excluded(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        # window = [2026-04-29, 2026-05-01] for --days 3, now on 2026-05-01.
        self.commit(repo, {"a.txt": "a\n"}, "exactly at window start", adate=iso(2026, 4, 29, 0, 0, 0), aemail="owner@example.com")
        self.commit(repo, {"b.txt": "b\n"}, "one second before window start", adate=iso(2026, 4, 28, 23, 59, 59), aemail="owner@example.com")
        self.commit(repo, {"c.txt": "c\n"}, "future dated", adate=iso(2026, 5, 2, 12, 0, 0), aemail="owner@example.com")

        now = epoch(2026, 5, 1, 15, 0, 0)
        data, _ = self.run_tool_json(self.default_args(now, days=3))

        dates = [d["date"] for d in data["days"]]
        self.assertEqual(dates, ["2026-04-29", "2026-04-30", "2026-05-01"])
        self.assertEqual(find_day(data, "2026-04-29")["commits"], 1)
        self.assertEqual(data["totals"]["commits"], 1, "only the exact-midnight commit should count; before-start and future-dated must be excluded")

    # -- 3. merges excluded by default, included with --include-merges ----

    def test_03_merges_excluded_by_default_included_with_flag_and_add_no_lines(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"base.txt": "base\n"}, "base", adate=iso(2026, 6, 1, 10), aemail="owner@example.com")
        self.git(repo, "branch", "feat")
        self.commit(repo, {"main1.txt": "m\n"}, "main1", adate=iso(2026, 6, 2, 10), aemail="owner@example.com")
        self.git(repo, "checkout", "-q", "feat")
        self.commit(repo, {"feat1.txt": "f\n"}, "feat1", adate=iso(2026, 6, 2, 11), aemail="owner@example.com")
        # switch back to the branch that isn't 'feat'
        branches = self.git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").stdout.split()
        main_branch = [b for b in branches if b != "feat"][0]
        self.git(repo, "checkout", "-q", main_branch)
        env = dict(self.base_env)
        env["GIT_AUTHOR_DATE"] = iso(2026, 6, 3, 10)
        env["GIT_COMMITTER_DATE"] = iso(2026, 6, 3, 10)
        env["GIT_AUTHOR_EMAIL"] = "owner@example.com"
        env["GIT_AUTHOR_NAME"] = "Owner"
        subprocess.run(["git", "merge", "feat", "-q", "-m", "merge feat", "--no-ff"], cwd=repo, env=env, check=True, capture_output=True)

        now = epoch(2026, 6, 3)
        data, _ = self.run_tool_json(self.default_args(now, days=5))
        self.assertEqual(find_day(data, "2026-06-03")["commits"], 0, "merge commit must be excluded by default")

        data2, _ = self.run_tool_json(self.default_args(now, days=5, extra=["--include-merges"]))
        merge_day = find_day(data2, "2026-06-03")
        self.assertEqual(merge_day["commits"], 1, "merge commit must be included with --include-merges")

        data3, _ = self.run_tool_json(self.default_args(now, days=5, extra=["--include-merges", "--metric", "lines"]))
        merge_day3 = find_day(data3, "2026-06-03")
        self.assertEqual(merge_day3["commits"], 1)
        self.assertEqual(merge_day3["added"], 0, "a merge commit must contribute 0 lines (no -m/-c, so git prints no diff for it)")
        self.assertEqual(merge_day3["deleted"], 0)

    # -- 4. stash and notes not counted -----------------------------------

    def test_04_stash_and_notes_not_counted(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "real commit", adate=iso(2026, 6, 10, 10), aemail="owner@example.com")
        with open(os.path.join(repo, "a.txt"), "w") as f:
            f.write("dirty\n")
        env = dict(self.base_env)
        env["GIT_AUTHOR_DATE"] = iso(2026, 6, 10, 11)
        env["GIT_COMMITTER_DATE"] = iso(2026, 6, 10, 11)
        subprocess.run(["git", "stash"], cwd=repo, env=env, check=True, capture_output=True)
        subprocess.run(["git", "notes", "add", "-m", "a note", "HEAD"], cwd=repo, env=env, check=True, capture_output=True)

        now = epoch(2026, 6, 10)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(data["totals"]["commits"], 1)

    # -- 5. clone scanned together with original -> counted once ----------

    def test_05_clone_counted_once(self):
        self.set_global_identity("owner@example.com", "Owner")
        original = self.make_repo("aaa_original")
        self.commit(original, {"a.txt": "a\n"}, "commit one", adate=iso(2026, 7, 1, 10), aemail="owner@example.com")
        self.commit(original, {"b.txt": "b\n"}, "commit two", adate=iso(2026, 7, 1, 11), aemail="owner@example.com")
        clone_path = os.path.join(self.roots_dir, "zzz_clone")
        shutil.copytree(original, clone_path)

        now = epoch(2026, 7, 1)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(data["totals"]["commits"], 2, "clone must not double-count identical (same-SHA) commits")
        self.assertEqual(data["repoCount"], 2, "both repo directories are still discovered/scanned")
        day = find_day(data, "2026-07-01")
        self.assertEqual(len(day["repos"]), 1, "all credit should go to a single repo (first in sorted path order)")
        self.assertEqual(day["repos"][0]["name"], "aaa_original", "sorted-path order: 'aaa_original' sorts before 'zzz_clone'")

    # -- 6. SHA-only dedupe: rebase/cherry-pick now counts separately -----

    def test_06a_rebased_or_cherry_picked_copy_counts_separately(self):
        # Post-amendment: dedupe is by SHA only. A rebased copy gets a new
        # SHA (different committer date here, as a real rebase would give
        # it) and is now intentionally counted again -- an accepted
        # tradeoff after the (author_ts, email, subject) key was found to
        # collide (see test_06b).
        self.set_global_identity("owner@example.com", "Owner")
        repo_a = self.make_repo("repo_a")
        self.commit(repo_a, {"base.txt": "base\n"}, "base", adate=iso(2026, 7, 10, 9), aemail="owner@example.com")
        self.commit(
            repo_a, {"feature.txt": "feature\n"}, "add feature",
            adate=iso(2026, 7, 10, 10), cdate=iso(2026, 7, 10, 10), aemail="owner@example.com",
        )

        repo_b = self.make_repo("repo_b")
        self.commit(repo_b, {"other.txt": "other\n"}, "unrelated base in repo_b", adate=iso(2026, 7, 10, 8), aemail="owner@example.com")
        # Same author date/email/subject as repo_a's "add feature" -- would
        # have deduped under the old key -- but a different committer date,
        # giving it a different SHA.
        rebased_hash = self.commit(
            repo_b, {"feature.txt": "feature\n"}, "add feature",
            adate=iso(2026, 7, 10, 10), cdate=iso(2026, 7, 11, 9), aemail="owner@example.com",
        )
        base_hash = self.git(repo_b, "rev-parse", "HEAD~1").stdout.strip()
        self.git(repo_b, "update-ref", "refs/remotes/origin/feature", rebased_hash)
        self.git(repo_b, "reset", "--hard", base_hash)  # local branch no longer reaches the rebased commit

        now = epoch(2026, 7, 11)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(
            data["totals"]["commits"], 4,
            "all 4 commits have distinct SHAs, so none are deduped under SHA-only dedupe",
        )

    def test_06b_sha_dedupe_does_not_collide_on_same_second_subject_and_email(self):
        # Regression guard for the bug that motivated dropping the old key:
        # two distinct commits sharing an author second, email and subject
        # must both count.
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        same_ts = iso(2026, 7, 15, 9, 0, 0)
        self.commit(repo, {"a.txt": "a\n"}, "same subject", adate=same_ts, aemail="owner@example.com")
        self.commit(repo, {"b.txt": "b\n"}, "same subject", adate=same_ts, aemail="owner@example.com")

        now = epoch(2026, 7, 15)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(data["totals"]["commits"], 2, "distinct commits sharing author-second+subject+email must both count")

    # -- 7. binary + lockfile excluded from lines; files correct -----------

    def test_07_binary_and_lockfile_excluded_from_lines(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(
            repo,
            {
                "code.txt": "line1\nline2\nline3\n",
                "package-lock.json": "\n".join(str(i) for i in range(5)) + "\n",
                "image.bin": bytes([0, 1, 2, 3, 0, 255, 254]),
            },
            "add mixed files",
            adate=iso(2026, 7, 20, 10), aemail="owner@example.com",
        )
        now = epoch(2026, 7, 20)
        data, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--metric", "lines"]))
        day = find_day(data, "2026-07-20")
        self.assertEqual(day["added"], 3, "only code.txt's 3 lines should count; lockfile and binary excluded")
        self.assertEqual(day["deleted"], 0)
        self.assertEqual(day["files"], 2, "code.txt + package-lock.json (non-binary); image.bin excluded")

    # -- 8. commits reachable only via refs/remotes/... ---------------------

    def test_08_commit_reachable_only_via_remote_tracking_ref(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "base", adate=iso(2026, 8, 1, 9), aemail="owner@example.com")
        orphan_hash = self.commit(repo, {"b.txt": "b\n"}, "only via remote ref", adate=iso(2026, 8, 1, 10), aemail="owner@example.com")
        base_hash = self.git(repo, "rev-parse", "HEAD~1").stdout.strip()
        self.git(repo, "update-ref", "refs/remotes/origin/feature", orphan_hash)
        self.git(repo, "reset", "--hard", base_hash)

        now = epoch(2026, 8, 1)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(data["totals"]["commits"], 2)

    # -- 9. empty, unborn, corrupt repo -> no crash, warning only ----------

    def test_09_empty_unborn_corrupt_repo_no_crash(self):
        self.set_global_identity("owner@example.com", "Owner")
        self.make_repo("empty_repo")  # git init, zero commits: unborn HEAD
        corrupt = self.make_repo("corrupt_repo")
        self.commit(corrupt, {"a.txt": "a\n"}, "will be corrupted after", adate=iso(2026, 8, 5, 9), aemail="owner@example.com")
        with open(os.path.join(corrupt, ".git", "HEAD"), "w") as f:
            f.write("garbage not a ref\n")

        now = epoch(2026, 8, 5)
        data, proc = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(data["totals"]["commits"], 0)
        self.assertTrue(any("corrupt_repo" in w for w in data["warnings"]), data["warnings"])

    # -- 10. levels: default bounds (per metric), custom, aliases ----------

    def test_10a_levels_default_mode_uses_fixed_bounds_regardless_of_history(self):
        # No more baseline/history dependency at all: "default" mode always
        # uses the metric's fixed bounds, even with very little activity.
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "c1", adate=iso(2026, 9, 1, 9), aemail="owner@example.com")
        self.commit(repo, {"b.txt": "b\n"}, "c2", adate=iso(2026, 9, 2, 9), aemail="owner@example.com")

        now = epoch(2026, 9, 2)
        data, _ = self.run_tool_json(self.default_args(now, days=5))
        self.assertEqual(data["levelMode"], "default")
        self.assertEqual(data["thresholds"], [1, 2, 4, 8])
        self.assertEqual(find_day(data, "2026-09-01")["level"], 1)
        self.assertEqual(find_day(data, "2026-09-02")["level"], 1)

    def test_10b_levels_explicit_custom(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        for c in range(5):
            self.commit(repo, {f"f{c}.txt": "x\n"}, f"c{c}", adate=iso(2026, 9, 20, 9 + c), aemail="owner@example.com")
        now = epoch(2026, 9, 20)
        data, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--levels", "2,4,6,8"]))
        self.assertEqual(data["levelMode"], "custom")
        self.assertEqual(data["thresholds"], [2, 4, 6, 8])
        self.assertEqual(find_day(data, "2026-09-20")["level"], 2)  # v=5: bounds<=5 -> {2,4} -> level2

    def test_10c_levels_metric_lines_default_bounds(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "one\n"}, "c1", adate=iso(2026, 9, 25, 9), aemail="owner@example.com")
        now = epoch(2026, 9, 25)
        data, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--metric", "lines"]))
        self.assertEqual(data["levelMode"], "default")
        self.assertEqual(data["thresholds"], [1, 50, 200, 800])

    def test_10d_levels_auto_and_default_are_aliases(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "c1", adate=iso(2026, 9, 28, 9), aemail="owner@example.com")
        now = epoch(2026, 9, 28)
        data_auto, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--levels", "auto"]))
        data_default, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--levels", "default"]))
        self.assertEqual(data_auto["levelMode"], "default")
        self.assertEqual(data_default["levelMode"], "default")
        self.assertEqual(data_auto["thresholds"], data_default["thresholds"])

    # -- 11. discovery: max-depth, pruning, symlinks, .git-file repos ------

    def test_11a_max_depth_clamped_discovery(self):
        # repo_shallow at depth 1, repo_deep at depth 3 under the scan root.
        shallow = os.path.join(self.roots_dir, "shallow_repo")
        os.makedirs(shallow, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=shallow, env=self.base_env, check=True, capture_output=True)
        deep_parent = os.path.join(self.roots_dir, "d1", "d2", "deep_repo")
        os.makedirs(deep_parent, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=deep_parent, env=self.base_env, check=True, capture_output=True)

        now = epoch(2026, 10, 1)
        data0, _ = self.run_tool_json(self.default_args(now, days=1, extra=["--max-depth", "0"]))
        self.assertEqual(data0["repoCount"], 0, "max-depth 0: the scan root itself isn't a repo, nothing found")

        data1, _ = self.run_tool_json(self.default_args(now, days=1, extra=["--max-depth", "1"]))
        self.assertEqual(data1["repoCount"], 1, "max-depth 1: only the depth-1 shallow repo")

        data4, _ = self.run_tool_json(self.default_args(now, days=1, extra=["--max-depth", "4"]))
        self.assertEqual(data4["repoCount"], 2, "max-depth 4 (default): both repos found")

    def test_11b_hidden_and_prune_dirs_and_symlinks_and_git_file_repo(self):
        self.set_global_identity("owner@example.com", "Owner")
        # Hidden dir pruned.
        hidden = os.path.join(self.roots_dir, ".hidden", "inner_repo")
        os.makedirs(hidden, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=hidden, env=self.base_env, check=True, capture_output=True)
        # node_modules pruned.
        nm = os.path.join(self.roots_dir, "proj", "node_modules", "some_pkg")
        os.makedirs(nm, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=nm, env=self.base_env, check=True, capture_output=True)
        # A real repo, plus a symlink to it elsewhere in the tree: must not
        # be double-discovered/followed via the symlink.
        real = os.path.join(self.roots_dir, "real_repo")
        os.makedirs(real, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=real, env=self.base_env, check=True, capture_output=True)
        link = os.path.join(self.roots_dir, "link_to_real_repo")
        os.symlink(real, link)
        # A worktree of `real`: uses a .git FILE, not a directory.
        worktree = os.path.join(self.roots_dir, "real_repo_worktree")
        self.commit(real, {"a.txt": "a\n"}, "seed", adate=iso(2026, 10, 5, 9), aemail="owner@example.com")
        subprocess.run(["git", "worktree", "add", "-q", worktree, "-b", "wt-branch"], cwd=real, env=self.base_env, check=True, capture_output=True)
        self.assertTrue(os.path.isfile(os.path.join(worktree, ".git")), "sanity: worktree uses a .git file")

        now = epoch(2026, 10, 5)
        data, _ = self.run_tool_json(self.default_args(now, days=1))
        # Expect exactly: real_repo + real_repo_worktree. .hidden and
        # node_modules pruned; the symlink never followed/counted.
        self.assertEqual(data["repoCount"], 2, "expected only real_repo + its worktree to be discovered")

    # -- 12. output schema/ordering; exact case-insensitive author match ---

    def test_12a_output_schema_and_ordering(self):
        self.set_global_identity("owner@example.com", "Owner")
        repoA = self.make_repo("repoA")
        repoB = self.make_repo("repoB")
        repoC = self.make_repo("repoC")
        # Same day: repoA gets 3 commits, repoB gets 3 (tie -> name order),
        # repoC gets 1. Expected repos order: repoA, repoB (tie, name asc), repoC.
        for i in range(3):
            self.commit(repoA, {f"a{i}.txt": "x\n"}, f"a{i}", adate=iso(2026, 11, 1, 9 + i), aemail="owner@example.com")
        for i in range(3):
            self.commit(repoB, {f"b{i}.txt": "x\n"}, f"b{i}", adate=iso(2026, 11, 1, 9 + i), aemail="owner@example.com")
        self.commit(repoC, {"c.txt": "x\n"}, "c0", adate=iso(2026, 11, 1, 9), aemail="owner@example.com")

        now = epoch(2026, 11, 1)
        data, proc = self.run_tool_json(self.default_args(now, days=4))

        self.assertEqual(list(data.keys()), [
            "version", "generatedAt", "timezone", "metric", "levelMode",
            "thresholds", "days", "totals", "repoCount", "unpushed", "watch", "warnings",
        ])
        self.assertEqual(data["version"], 1)
        self.assertIsInstance(data["generatedAt"], int)
        self.assertEqual(len(data["thresholds"]), 4)
        self.assertEqual(len(data["days"]), 4)
        dates = [d["date"] for d in data["days"]]
        self.assertEqual(dates, sorted(dates))
        self.assertEqual(dates[-1], "2026-11-01")
        for d in data["days"]:
            self.assertEqual(list(d.keys()), ["date", "commits", "added", "deleted", "files", "level", "repos"])
            for r in d["repos"]:
                self.assertEqual(list(r.keys()), ["name", "commits", "added", "deleted"])
        self.assertEqual(list(data["totals"].keys()), ["commits", "added", "deleted"])
        self.assertIsInstance(data["watch"], list)
        self.assertEqual(data["watch"], sorted(data["watch"]))

        day = find_day(data, "2026-11-01")
        self.assertEqual(day["repos"], [
            {"name": "repoA", "commits": 3, "added": 3, "deleted": 0},
            {"name": "repoB", "commits": 3, "added": 3, "deleted": 0},
            {"name": "repoC", "commits": 1, "added": 1, "deleted": 0},
        ])
        # Nothing but the JSON object on stdout.
        json.loads(proc.stdout)

    def test_12b_case_insensitive_fixed_string_author_match(self):
        # Email deliberately contains '.' and '+' -- if -F (fixed-strings)
        # weren't actually applied, these would be interpreted as regex
        # metacharacters (". " = any char, "+" = quantifier).
        self.set_global_identity("John.Doe+work@example.com", "John Doe")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "real", adate=iso(2026, 11, 10, 9),
                    aemail="John.Doe+work@example.com", aname="John Doe")
        # Trap commit: email with '.' and '+' replaced by arbitrary chars.
        # Would match if '.'/'+' were live regex metacharacters against the
        # pattern; must NOT match under a true fixed-string comparison.
        self.commit(repo, {"b.txt": "b\n"}, "trap", adate=iso(2026, 11, 10, 10),
                    aemail="JohnXDoeYwork@example.com", aname="Trap")

        now = epoch(2026, 11, 10)
        # Explicit --author with different case than the commit's actual email.
        data, _ = self.run_tool_json(self.default_args(
            now, days=3, extra=["--author", "JOHN.DOE+WORK@EXAMPLE.COM"],
        ))
        self.assertEqual(data["totals"]["commits"], 1, "case-insensitive fixed-string match on '.'+'+' email failed")

    def test_12c_exact_author_name_match_excludes_substring_collision(self):
        # git's own -F -i --author=Ann pre-filter is a substring match and
        # would also match "Joann Example" (contains "ann"); the Python
        # post-filter (author_matches) must require an exact name match.
        self.set_global_identity("owner@example.com", "Ann")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "real", adate=iso(2026, 12, 1, 9), aemail="owner@example.com", aname="Ann")
        self.commit(repo, {"b.txt": "b\n"}, "trap", adate=iso(2026, 12, 1, 10), aemail="joann@example.com", aname="Joann Example")

        now = epoch(2026, 12, 1)
        data, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--author", "Ann"]))
        self.assertEqual(data["totals"]["commits"], 1, "--author=Ann must not match 'Joann Example'")

    # -- 13. bad arguments -> JSON error + exit 1 ---------------------------

    def test_13_bad_arguments_produce_error_json_exit_1(self):
        for args in (
            ["--metric", "bogus"],
            ["--levels", "not,valid,levels,x"],
            ["--levels", "5,2,9,15"],
            ["--days", "not-a-number"],
            ["--unknown-flag"],
            ["--baseline-days", "90"],  # removed in the levels amendment
        ):
            proc = self.run_tool(args)
            self.assertEqual(proc.returncode, 1, f"args={args} stdout={proc.stdout!r} stderr={proc.stderr!r}")
            payload = json.loads(proc.stdout)
            self.assertEqual(set(payload.keys()), {"version", "error"})
            self.assertEqual(payload["version"], 1)
            self.assertIsInstance(payload["error"], str)
            self.assertTrue(payload["error"])

    # -- 14. new `watch` output key -----------------------------------------

    def test_14_watch_key_unborn_repo_gitdir_then_logs_after_commit_plus_worktree(self):
        # Post-review: a brand new (unborn) repo has no reflog directory
        # yet, so its watch entry must be its gitdir instead -- the widget
        # watches for a `create` event there and switches once "logs"
        # appears. After the first commit, the logs dir takes over.
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo_watch")
        now = epoch(2026, 10, 20)

        data1, _ = self.run_tool_json(self.default_args(now, days=3))
        expected_gitdir = os.path.realpath(os.path.join(repo, ".git"))
        self.assertIn(expected_gitdir, data1["watch"], "unborn repo: gitdir itself must be watched")

        self.commit(repo, {"a.txt": "a\n"}, "seed", adate=iso(2026, 10, 20, 9), aemail="owner@example.com")
        worktree = os.path.join(self.roots_dir, "repo_watch_worktree")
        subprocess.run(
            ["git", "worktree", "add", "-q", worktree, "-b", "wt-branch"],
            cwd=repo, env=self.base_env, check=True, capture_output=True,
        )

        data2, _ = self.run_tool_json(self.default_args(now, days=3))
        expected_logs = os.path.realpath(os.path.join(repo, ".git", "logs"))
        self.assertIn(expected_logs, data2["watch"], "after the first commit, the logs dir now exists and is watched")
        self.assertNotIn(expected_gitdir, data2["watch"], "logs dir takes precedence once it exists")
        self.assertTrue(
            any("worktrees" in p and p.endswith("logs") for p in data2["watch"]),
            f"expected a worktree logs dir in {data2['watch']}",
        )
        self.assertEqual(data2["watch"], sorted(data2["watch"]))

    # -- 15. --history-days 0 omits the history block ----------------------

    def test_15_history_days_zero_omits_history_block(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "c1", adate=iso(2026, 4, 1, 9), aemail="owner@example.com")
        now = epoch(2026, 4, 1)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertNotIn("history", data, "history-days defaults to 0, so the block must be absent, not null")

    # -- 16. history shape/order/cap ----------------------------------------

    def test_16_history_shape_order_and_cap(self):
        self.set_global_identity("owner@example.com", "Owner")
        repoA = self.make_repo("repoA")
        repoB = self.make_repo("repoB")
        # 5 commits over 3 days; --commits caps the list to 3.
        self.commit(repoA, {"a1.txt": "x\n"}, "a1", adate=iso(2026, 5, 1, 9), aemail="owner@example.com")
        self.commit(repoB, {"b1.txt": "x\n"}, "b1", adate=iso(2026, 5, 1, 9), aemail="owner@example.com")  # ts tie -> repo name breaks it
        self.commit(repoA, {"a2.txt": "x\n"}, "a2", adate=iso(2026, 5, 2, 9), aemail="owner@example.com")
        self.commit(repoB, {"b2.txt": "x\n"}, "b2", adate=iso(2026, 5, 3, 9), aemail="owner@example.com")
        self.commit(repoA, {"a3.txt": "x\n"}, "a3", adate=iso(2026, 5, 3, 10), aemail="owner@example.com")

        now = epoch(2026, 5, 3)
        data, _ = self.run_tool_json(self.default_args(now, days=2, extra=["--history-days", "5", "--commits", "3"]))
        h = data["history"]

        self.assertEqual(list(h.keys()), ["days", "commits", "repos", "streak", "totals"])
        self.assertEqual(len(h["days"]), 5)
        self.assertEqual(h["days"][-1]["date"], "2026-05-03")
        self.assertEqual([d["date"] for d in h["days"]], sorted(d["date"] for d in h["days"]))
        for d in h["days"]:
            self.assertEqual(list(d.keys()), ["date", "commits", "added", "deleted", "level", "repos"], "no 'files' key in history days")
            for r in d["repos"]:
                self.assertEqual(list(r.keys()), ["name", "commits", "added", "deleted"])

        may3 = next(d for d in h["days"] if d["date"] == "2026-05-03")
        self.assertEqual(may3["repos"], [
            {"name": "repoA", "commits": 1, "added": 1, "deleted": 0},
            {"name": "repoB", "commits": 1, "added": 1, "deleted": 0},
        ], "tied on commits -> name order")

        self.assertEqual(len(h["commits"]), 3, "capped at --commits")
        subjects = [c["subject"] for c in h["commits"]]
        self.assertEqual(subjects, ["a3", "b2", "a2"], "newest first by ts; a1/b1 (tied, oldest) lost to the cap")

        self.assertEqual(h["totals"], {"commits": 5, "added": 5, "deleted": 0, "activeDays": 3})

        repo_names = [r["name"] for r in h["repos"]]
        self.assertEqual(set(repo_names), {"repoA", "repoB"})

    # -- 17. unpushed: pushed vs unpushed, other authors ignored, no remote -

    def test_17_unpushed_pushed_vs_unpushed_other_authors_ignored_no_remote_excluded(self):
        self.set_global_identity("owner@example.com", "Owner")
        bare = os.path.join(self.roots_dir, "origin_bare")
        subprocess.run(["git", "init", "-q", "--bare", bare], env=self.base_env, check=True, capture_output=True)

        work = self.make_repo("work")
        self.git(work, "remote", "add", "origin", bare)
        self.commit(work, {"a.txt": "a\n"}, "pushed commit", adate=iso(2026, 2, 1, 9), aemail="owner@example.com")
        self.git(work, "branch", "-M", "main")
        self.git(work, "push", "-q", "origin", "main")
        self.commit(work, {"b.txt": "b\n"}, "unpushed by owner", adate=iso(2026, 2, 2, 9), aemail="owner@example.com")
        self.commit(work, {"c.txt": "c\n"}, "unpushed by stranger", adate=iso(2026, 2, 2, 10), aemail="stranger@example.com", aname="Stranger")

        no_remote = self.make_repo("no_remote_repo")
        self.commit(no_remote, {"d.txt": "d\n"}, "local only, no remote configured", adate=iso(2026, 2, 2, 9), aemail="owner@example.com")

        now = epoch(2026, 2, 2)
        data, _ = self.run_tool_json(self.default_args(now, days=3))

        self.assertEqual(data["unpushed"]["commits"], 1, "only owner's unpushed commit in 'work' should count")
        self.assertEqual(data["unpushed"]["repos"], [{"name": "work", "commits": 1}])

    # -- 18. credential never reaches the output, end to end ----------------

    def test_18_credential_never_in_output_end_to_end(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.git(repo, "remote", "add", "origin", "https://user:secret-token@github.com/o/r.git")
        self.commit(repo, {"a.txt": "a\n"}, "c1", adate=iso(2026, 6, 1, 9), aemail="owner@example.com")

        now = epoch(2026, 6, 1)
        proc = self.run_tool(self.default_args(now, days=3, extra=["--history-days", "5", "--commits", "10"]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("secret-token", proc.stdout)
        self.assertNotIn("user:secret-token", proc.stdout)

        data = json.loads(proc.stdout)
        repo_entry = next(r for r in data["history"]["repos"] if r["name"] == "repo")
        self.assertEqual(repo_entry["url"], "https://github.com/o/r")
        # The remote is a fake/unreachable URL, so no real push ever
        # happened and no refs/remotes/origin/* ref exists -- the commit is
        # genuinely unpushed (exercised together with a real, reachable
        # push in test_19). The point of this test is purely that the
        # credential never appears anywhere in the output, checked above
        # against the full raw stdout.
        commit_entry = data["history"]["commits"][0]
        self.assertFalse(commit_entry["pushed"])
        self.assertIsNone(commit_entry["url"])
        self.assertEqual(data["unpushed"]["commits"], 1)

    # -- 19. pushed/url fields, including the "remote with no web base" case

    def test_19_pushed_and_url_fields(self):
        self.set_global_identity("owner@example.com", "Owner")
        bare = os.path.join(self.roots_dir, "bare2")
        subprocess.run(["git", "init", "-q", "--bare", bare], env=self.base_env, check=True, capture_output=True)
        work = self.make_repo("work2")
        self.git(work, "remote", "add", "origin", bare)
        self.commit(work, {"a.txt": "a\n"}, "pushed", adate=iso(2026, 8, 10, 9), aemail="owner@example.com")
        self.git(work, "branch", "-M", "main")
        self.git(work, "push", "-q", "origin", "main")
        self.commit(work, {"b.txt": "b\n"}, "unpushed", adate=iso(2026, 8, 10, 10), aemail="owner@example.com")

        no_remote = self.make_repo("no_remote2")
        self.commit(no_remote, {"c.txt": "c\n"}, "local only", adate=iso(2026, 8, 10, 11), aemail="owner@example.com")

        now = epoch(2026, 8, 10)
        data, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--history-days", "3", "--commits", "10"]))
        by_subject = {c["subject"]: c for c in data["history"]["commits"]}

        self.assertTrue(by_subject["pushed"]["pushed"])
        self.assertIsNone(by_subject["pushed"]["url"], "pushed to a bare local path: pushed=true but no web base exists")

        self.assertFalse(by_subject["unpushed"]["pushed"])
        self.assertIsNone(by_subject["unpushed"]["url"])

        self.assertFalse(by_subject["local only"]["pushed"], "no remote at all -> pushed is always false")
        self.assertIsNone(by_subject["local only"]["url"])

    # -- 20. no identity anywhere -> contributes nothing, not everyone -----

    def test_20_no_identity_contributes_nothing_not_all_authors(self):
        # Post-review: silently counting every author when no identity is
        # configured was wrong data, not a safe default. No set_global_
        # identity() call here at all, and no repo-local identity either.
        repo = self.make_repo("no_identity_repo")
        bare = os.path.join(self.roots_dir, "no_identity_bare")
        subprocess.run(["git", "init", "-q", "--bare", bare], env=self.base_env, check=True, capture_output=True)
        self.git(repo, "remote", "add", "origin", bare)
        # Explicit author/committer env vars mean git needs no configured
        # identity at all to create the commit.
        self.commit(
            repo, {"a.txt": "a\n"}, "commit with no configured identity",
            adate=iso(2026, 3, 25, 9),
            aemail="whoever@example.com", aname="Whoever",
            cemail="whoever@example.com", cname="Whoever",
        )
        # Deliberately never pushed -- if identity resolution fell through
        # to "count everyone", this would also wrongly show up as unpushed.

        now = epoch(2026, 3, 25)
        data, _ = self.run_tool_json(self.default_args(now, days=3))
        self.assertEqual(data["totals"]["commits"], 0, "no identity anywhere -> contribute nothing, not everyone")
        self.assertEqual(data["unpushed"]["commits"], 0, "no identity -> no unpushed count either")
        self.assertTrue(
            any("no git identity for" in w and "no_identity_repo" in w for w in data["warnings"]),
            data["warnings"],
        )
        self.assertFalse(
            any("counting all authors" in w for w in data["warnings"]),
            "the old wrong-data fallback message must be gone",
        )

    # -- 21. per-repo added/deleted in day entries (strip and history) -----

    def test_21_per_repo_added_deleted_in_day_entries(self):
        self.set_global_identity("owner@example.com", "Owner")
        repoA = self.make_repo("repoA21")
        repoB = self.make_repo("repoB21")
        self.commit(repoA, {"a.txt": "l1\nl2\nl3\n"}, "3 new lines", adate=iso(2026, 3, 20, 9), aemail="owner@example.com")
        self.commit(repoA, {"a.txt": "l1\n"}, "delete 2 lines", adate=iso(2026, 3, 20, 10), aemail="owner@example.com")
        self.commit(repoB, {"b.txt": "x\ny\n"}, "2 new lines", adate=iso(2026, 3, 20, 11), aemail="owner@example.com")

        now = epoch(2026, 3, 20)
        data, _ = self.run_tool_json(self.default_args(now, days=3, extra=["--history-days", "3", "--commits", "10"]))

        day = find_day(data, "2026-03-20")
        repos_by_name = {r["name"]: r for r in day["repos"]}
        self.assertEqual(repos_by_name["repoA21"], {"name": "repoA21", "commits": 2, "added": 3, "deleted": 2})
        self.assertEqual(repos_by_name["repoB21"], {"name": "repoB21", "commits": 1, "added": 2, "deleted": 0})

        h_day = find_day(data["history"], "2026-03-20")
        h_repos_by_name = {r["name"]: r for r in h_day["repos"]}
        self.assertEqual(h_repos_by_name["repoA21"], {"name": "repoA21", "commits": 2, "added": 3, "deleted": 2})
        self.assertEqual(h_repos_by_name["repoB21"], {"name": "repoB21", "commits": 1, "added": 2, "deleted": 0})


    # -- 22-24. hardening: forged separators, clone credit, names -----------

    def test_22_forged_record_separator_in_a_subject_invents_nothing(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        forged = ("real\x1e" + "a" * 40 + "\x1f1789300000\x1fowner@example.com\x1fOwner\x1f\x1finvented"
                  "\x1e" + "b" * 40 + "\x1f1789300000\x1fowner@example.com\x1fOwner\x1f\x1finvented too")
        self.commit(repo, message=forged, adate=iso(2026, 9, 1, 10), aemail="owner@example.com",
                    aname="Owner", allow_empty=True)
        data, _ = self.run_tool_json(self.default_args(epoch(2026, 9, 1), days=3,
                                                       extra=["--history-days", "3", "--commits", "10"]))
        self.assertEqual(data["totals"]["commits"], 1)
        commits = data["history"]["commits"]
        self.assertEqual(len(commits), 1)
        self.assertTrue(commits[0]["subject"].startswith("real"))
        self.assertRegex(commits[0]["hash"], r"^[0-9a-f]{40}$")

    def test_23_clone_credit_goes_to_the_least_nested_copy_with_the_plain_name(self):
        self.set_global_identity("owner@example.com", "Owner")
        main = self.make_repo("proj")
        self.commit(main, {"a.txt": "a\n"}, "shared", adate=iso(2026, 9, 1, 10), aemail="owner@example.com")
        # "_audit" sorts before "proj", so plain path order would credit the copy.
        copy = os.path.join(self.roots_dir, "_audit", "proj")
        shutil.copytree(main, copy)
        self.commit(copy, {"b.txt": "b\n"}, "only in the copy", adate=iso(2026, 9, 1, 11), aemail="owner@example.com")
        data, _ = self.run_tool_json(self.default_args(epoch(2026, 9, 1), days=3))
        day = find_day(data, "2026-09-01")
        self.assertEqual({r["name"]: r["commits"] for r in day["repos"]}, {"proj": 1, "_audit/proj": 1})

    def test_24_a_name_clash_at_the_same_depth_prefixes_both(self):
        self.set_global_identity("owner@example.com", "Owner")
        a = self.make_repo(os.path.join("a", "proj"))
        b = self.make_repo(os.path.join("b", "proj"))
        self.commit(a, {"a.txt": "a\n"}, "in a", adate=iso(2026, 9, 1, 10), aemail="owner@example.com")
        self.commit(b, {"b.txt": "b\n"}, "in b", adate=iso(2026, 9, 1, 11), aemail="owner@example.com")
        data, _ = self.run_tool_json(self.default_args(epoch(2026, 9, 1), days=3))
        self.assertEqual({r["name"] for r in find_day(data, "2026-09-01")["repos"]}, {"a/proj", "b/proj"})


    # -- 25-27. second-opinion fixes -----------------------------------------

    def test_25_a_malformed_remote_url_costs_the_link_not_the_commits(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        self.commit(repo, {"a.txt": "a\n"}, "one", adate=iso(2026, 9, 1, 10), aemail="owner@example.com")
        self.git(repo, "config", "remote.origin.url", "https://[::1/repo.git")
        data, _ = self.run_tool_json(self.default_args(epoch(2026, 9, 1), days=3,
                                                       extra=["--history-days", "3", "--commits", "10"]))
        self.assertEqual(data["totals"]["commits"], 1)
        self.assertIsNone(data["history"]["commits"][0]["url"])
        self.assertFalse(any("unexpected error" in w for w in data["warnings"]), data["warnings"])

    def test_26_push_evidence_from_any_clone_marks_the_commit_pushed(self):
        self.set_global_identity("owner@example.com", "Owner")
        main = self.make_repo("repo")  # least nested, so credited -- but it has no remote
        sha = self.commit(main, {"a.txt": "a\n"}, "shared", adate=iso(2026, 9, 1, 10), aemail="owner@example.com")
        nested = os.path.join(self.roots_dir, "nested", "repo")
        self.git(self.roots_dir, "clone", "-q", main, nested)
        self.git(nested, "remote", "set-url", "origin", "https://github.com/me/repo.git")
        data, _ = self.run_tool_json(self.default_args(epoch(2026, 9, 1), days=3,
                                                       extra=["--history-days", "3", "--commits", "10"]))
        row = data["history"]["commits"][0]
        self.assertEqual(row["repo"], "repo")
        self.assertTrue(row["pushed"])
        self.assertEqual(row["url"], f"https://github.com/me/repo/commit/{sha}")
        self.assertEqual(data["unpushed"]["commits"], 0)

    def test_27_a_commit_on_a_detached_head_counts_and_is_unpushed(self):
        self.set_global_identity("owner@example.com", "Owner")
        repo = self.make_repo("repo")
        base = self.commit(repo, {"a.txt": "a\n"}, "base", adate=iso(2026, 9, 1, 9), aemail="owner@example.com")
        self.git(repo, "remote", "add", "origin", "https://github.com/me/r.git")
        self.git(repo, "update-ref", "refs/remotes/origin/main", base)
        self.git(repo, "checkout", "-q", "--detach")
        self.commit(repo, {"b.txt": "b\n"}, "detached", adate=iso(2026, 9, 1, 10), aemail="owner@example.com")
        data, _ = self.run_tool_json(self.default_args(epoch(2026, 9, 1), days=3,
                                                       extra=["--history-days", "3", "--commits", "10"]))
        self.assertEqual(data["totals"]["commits"], 2)
        self.assertEqual(data["unpushed"]["commits"], 1)
        rows = {c["subject"]: c for c in data["history"]["commits"]}
        self.assertFalse(rows["detached"]["pushed"])
        self.assertTrue(rows["base"]["pushed"])


class RemoteUrlHardeningTests(unittest.TestCase):
    """Remote URLs come from repository config, which a cloned repository's
    author controls, and the result is opened in a browser."""

    CASES = [
        ("https://github.com/o/r?access_token=secret-token", "https://github.com/o/r"),
        ("https://github.com/o/r.git#secret-fragment", "https://github.com/o/r"),
        ("git@secret-token@github.com:o/r.git", "https://github.com/o/r"),
        ("HTTPS://GitHub.COM/Owner/Repo.git", "https://github.com/Owner/Repo"),
        ("https://github.com/o/r/../../evil", None),
        ("https://github.com/o/r%2F..%2Fevil", None),
        ("https://github.com/o/r with space", None),
        ("git@github-work:o/r.git", None),
        ("https://[::1]/o/r", None),
        ("https://[::1/repo.git", None),
        ("javascript:alert(1)", None),
        ("C:/Users/me/repo", None),
    ]

    def test_table(self):
        for raw, expected in self.CASES:
            with self.subTest(raw=raw):
                self.assertEqual(ct.remote_to_web_url(raw), expected)

    def test_no_secret_survives_any_form(self):
        for raw in ("https://u:secret-token@github.com/o/r?t=secret-token#secret-token",
                    "git@secret-token@github.com:o/r.git",
                    "ssh://secret-token@github.com:2222/o/r.git"):
            with self.subTest(raw=raw):
                self.assertNotIn("secret-token", ct.remote_to_web_url(raw) or "")


if __name__ == "__main__":
    unittest.main()
