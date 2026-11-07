"""Tests for SSH host-alias resolution in bin/commit-tracker.

The script has no .py suffix, so it is loaded from its file path with
importlib exactly the way tests/test_commit_tracker.py does.
"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL_PATH = os.path.join(REPO_ROOT, "bin", "commit-tracker")


def _load_tool_module():
    loader = importlib.machinery.SourceFileLoader("commit_tracker_under_test", TOOL_PATH)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


ct = _load_tool_module()


class SshAliasHostTests(unittest.TestCase):

    def test_hostname_equals_form_lowercase(self):
        self.assertEqual(
            ct.ssh_alias_host("work", "Host work\n  HostName=GitHub.COM\n"),
            "github.com",
        )

    def test_hostname_equals_whitespace_form(self):
        self.assertEqual(
            ct.ssh_alias_host("work", "Host work\n  HostName github.com\n"),
            "github.com",
        )

    def test_first_applicable_block_wins(self):
        config = (
            "Host work other\n HostName gitlab.com\n"
            "Host work\n HostName example.org\n"
        )
        self.assertEqual(ct.ssh_alias_host("WORK", config), "gitlab.com")

    def test_match_pattern_is_case_insensitive(self):
        self.assertEqual(
            ct.ssh_alias_host("work", "Host work\n HostName=bitbucket.org\n"),
            "bitbucket.org",
        )

    def test_comment_and_blank_lines_ignored(self):
        config = (
            "# a comment\n"
            "\n"
            "Host work # inline comment\n"
            "HostName github.com\n"
            "\n"
        )
        self.assertEqual(ct.ssh_alias_host("work", config), "github.com")

    def test_multiple_patterns_match(self):
        self.assertEqual(
            ct.ssh_alias_host("work", "Host work staging\n HostName github.com\n"),
            "github.com",
        )

    def test_no_matching_block_returns_none(self):
        self.assertIsNone(ct.ssh_alias_host("work", "Host home\n HostName github.com\n"))

    def test_block_without_host_name_returns_none(self):
        self.assertIsNone(ct.ssh_alias_host("work", "Host work\n Port 22\n"))

    def test_host_name_after_match_is_ignored(self):
        # A Match line ends the current block, so a HostName below it is not
        # consulted unless a Host line matches (which there is none here).
        config = (
            "Host work\n Port 22\n"
            "Match host work\n HostName github.com\n"
        )
        self.assertIsNone(ct.ssh_alias_host("work", config))

    def test_invalid_host_is_rejected(self):
        # "github-work" is an alias, not a real dotted host name.
        self.assertIsNone(ct.ssh_alias_host("work", "Host work\n HostName github-work\n"))

    def test_empty_alias_returns_none(self):
        self.assertIsNone(ct.ssh_alias_host("", "Host work\n HostName github.com\n"))

    def test_empty_config_returns_none(self):
        self.assertIsNone(ct.ssh_alias_host("work", ""))

    def test_hostname_equals_syntax(self):
        self.assertEqual(
            ct.ssh_alias_host("work", "Host work\n HostName=github.com\n"),
            "github.com",
        )


class RemoteToWebUrlWithAliasTests(unittest.TestCase):
    def test_only_ssh_remotes_use_an_alias(self):
        cfg = "Host work\n    HostName github.com\n"
        self.assertEqual(ct.remote_to_web_url("git@work:o/r.git", cfg), "https://github.com/o/r")
        self.assertEqual(ct.remote_to_web_url("ssh://git@work/o/r.git", cfg), "https://github.com/o/r")
        self.assertIsNone(ct.remote_to_web_url("https://work/o/r.git", cfg))
        self.assertIsNone(ct.remote_to_web_url("git://work/o/r.git", cfg))
        self.assertIsNone(ct.remote_to_web_url("http://work/o/r.git", cfg))


    def test_scp_like_alias_resolved(self):
        self.assertEqual(
            ct.remote_to_web_url("git@work:me/repo.git", "Host work\n HostName github.com\n"),
            "https://github.com/me/repo",
        )

    def test_ssh_form_alias_resolved(self):
        self.assertEqual(
            ct.remote_to_web_url("ssh://git@work/repo.git", "Host work\n HostName github.com\n"),
            "https://github.com/repo",
        )

    def test_ssh_form_alias_resolved_with_subgroup(self):
        self.assertEqual(
            ct.remote_to_web_url("ssh://git@work/group/subgroup/repo.git", "Host work\n HostName gitlab.com\n"),
            "https://gitlab.com/group/subgroup/repo",
        )

    def test_no_ssh_config_leaves_alias_unresolved(self):
        # With ssh_config=None the behaviour is exactly the current one.
        self.assertIsNone(ct.remote_to_web_url("git@work:me/repo.git"))

    def test_unknown_alias_with_config_returns_none(self):
        self.assertIsNone(
            ct.remote_to_web_url("git@work:me/repo.git", "Host home\n HostName github.com\n")
        )

    def test_non_alias_host_unchanged(self):
        self.assertEqual(
            ct.remote_to_web_url("git@github.com:me/repo.git", "Host work\n HostName github.com\n"),
            "https://github.com/me/repo",
        )

    def test_http_url_ignores_ssh_config(self):
        self.assertEqual(
            ct.remote_to_web_url("https://github.com/me/repo.git", "Host work\n HostName github.com\n"),
            "https://github.com/me/repo",
        )

    def test_alias_but_invalid_host_name(self):
        # The resolved HostName is itself an alias, so it is rejected.
        self.assertIsNone(
            ct.remote_to_web_url("git@work:me/repo.git", "Host work\n HostName gitlab-work\n")
        )

    def test_non_ssh_url_still_drops_credentials(self):
        self.assertEqual(
            ct.remote_to_web_url("https://user:secret-token@github.com/o/r.git"),
            "https://github.com/o/r",
        )


if __name__ == "__main__":
    unittest.main()
