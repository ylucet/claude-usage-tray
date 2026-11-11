"""Fast tests for statusline-share.py (bucket: fast, < 1 s).

Run: python -m unittest discover -s tests
"""
import importlib.util
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "statusline_share", os.path.join(_HERE, "..", "statusline-share.py"))
sl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sl)


def _rl(p5, r5, p7, r7):
    return {"rate_limits": {
        "five_hour": {"used_percentage": p5, "resets_at": r5},
        "seven_day": {"used_percentage": p7, "resets_at": r7}}}


class ShareUsage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "root")
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(self.root)
        os.makedirs(os.path.join(self.home, ".claude"))

    def tearDown(self):
        self.tmp.cleanup()

    def login(self, email, plan="team"):
        # Same layout Claude Code writes; /login rewrites both files.
        with open(os.path.join(self.home, ".claude.json"), "w", encoding="utf-8") as f:
            json.dump({"oauthAccount": {"emailAddress": email}}, f)
        with open(os.path.join(self.home, ".claude", ".credentials.json"), "w", encoding="utf-8") as f:
            json.dump({"claudeAiOauth": {"subscriptionType": plan}}, f)

    def share(self, data, api=None, now=None):
        self.fetches = getattr(self, "fetches", 0)

        def fetch(home):
            self.fetches += 1
            return api
        sl.share_usage(data, root=self.root, home=self.home, fetch=fetch, now=now)

    def account(self, email):
        path = os.path.join(self.root, ".claude-usage", "accounts", sl.account_file_name(email))
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def legacy(self):
        with open(os.path.join(self.root, ".claude-usage", "usage.json"), encoding="utf-8") as f:
            return json.load(f)

    def test_each_account_keeps_its_own_file_across_a_switch(self):
        self.login("a@x.ca")
        self.share(_rl(90, 1000, 40, 9000))
        self.login("b@y.ca", plan="max")
        self.share(_rl(5, 2000, 10, 8000))
        a, b = self.account("a@x.ca"), self.account("b@y.ca")
        self.assertEqual(a["five_hour"]["used_percentage"], 90)
        self.assertEqual(a["email"], "a@x.ca")
        self.assertEqual(b["five_hour"]["used_percentage"], 5)
        self.assertEqual(b["plan"], "max")
        # usage.json follows the account in use, for older trays.
        self.assertEqual(self.legacy()["email"], "b@y.ca")

    def test_previous_accounts_limits_right_after_switch_are_not_filed_under_new_account(self):
        self.login("a@x.ca")
        self.share(_rl(90, 1000, 40, 9000))
        self.login("b@y.ca")
        self.share(_rl(91, 1000, 40, 9000))   # still a@x.ca's windows
        self.assertIsNone(self.account("b@y.ca"))
        self.assertEqual(self.legacy()["email"], "a@x.ca")
        self.assertEqual(self.account("a@x.ca")["five_hour"]["used_percentage"], 90)

    def test_same_account_updates_its_own_file(self):
        self.login("a@x.ca")
        self.share(_rl(10, 1000, 40, 9000))
        self.share(_rl(20, 1000, 41, 9000))
        self.assertEqual(self.account("a@x.ca")["five_hour"]["used_percentage"], 20)

    def test_no_rate_limits_writes_nothing(self):
        self.login("a@x.ca")
        self.share({"context_window": {"used_percentage": 3}})
        self.assertFalse(os.path.exists(os.path.join(self.root, ".claude-usage")))

    def test_unknown_email_still_writes_legacy_file_only(self):
        self.share(_rl(10, 1000, 40, 9000))
        self.assertIsNone(self.legacy()["email"])
        self.assertFalse(os.path.exists(os.path.join(self.root, ".claude-usage", "accounts")))

    # --- official usage check (Claude Code's rate_limits can lag) ---------

    def test_reported_bug_stale_100_after_reset_replaced_by_official_0(self):
        # Observed 2026-11-11: after a limit reset, status line still said 100%
        # (old window ending 1794432000) while the API said 0%, window ending
        # 1794445200.
        self.login("b@y.ca")
        now = 1794427377
        self.share(_rl(100, 1794432000, 39, 1794697200), now=now, api={
            "five_hour": {"used_percentage": 0.0, "resets_at": 1794445200},
            "seven_day": {"used_percentage": 0.0, "resets_at": 1794697200 + 3600}})
        b = self.account("b@y.ca")
        self.assertEqual(b["five_hour"]["used_percentage"], 0)
        self.assertEqual(b["five_hour"]["resets_at"], 1794445200)
        self.assertEqual(b["seven_day"]["used_percentage"], 0)
        self.assertEqual(self.legacy()["five_hour"]["used_percentage"], 0)

    def test_window_not_started_beats_stale_window(self):
        self.login("b@y.ca")
        now = 10_000_000
        self.share(_rl(100, now + 3000, 39, now + 90000), now=now, api={
            "five_hour": {"used_percentage": 0, "resets_at": None},
            "seven_day": {"used_percentage": 39, "resets_at": now + 90000}})
        b = self.account("b@y.ca")
        self.assertEqual(b["five_hour"]["used_percentage"], 0)
        self.assertEqual(b["seven_day"]["used_percentage"], 39)

    def test_same_window_takes_the_larger_usage(self):
        self.login("a@x.ca")
        now = 10_000_000
        self.share(_rl(42, now + 3000, 10, now + 90000), now=now, api={
            "five_hour": {"used_percentage": 40, "resets_at": now + 3010},
            "seven_day": {"used_percentage": 11, "resets_at": now + 90000}})
        a = self.account("a@x.ca")
        self.assertEqual(a["five_hour"]["used_percentage"], 42)
        self.assertEqual(a["seven_day"]["used_percentage"], 11)

    def test_new_window_after_the_last_check_follows_the_status_line(self):
        self.login("a@x.ca")
        t0 = 10_000_000
        self.share(_rl(90, t0 + 100, 10, t0 + 90000), now=t0, api={
            "five_hour": {"used_percentage": 90, "resets_at": t0 + 100},
            "seven_day": {"used_percentage": 10, "resets_at": t0 + 90000}})
        # 200 s later (no new check yet): the old window ended, a new one began.
        self.share(_rl(2, t0 + 200 + 18000, 11, t0 + 90000), now=t0 + 200, api=None)
        a = self.account("a@x.ca")
        self.assertEqual(a["five_hour"]["used_percentage"], 2)
        self.assertEqual(a["seven_day"]["used_percentage"], 11)

    def test_official_check_at_most_every_five_minutes_per_account(self):
        self.login("a@x.ca")
        t0 = 10_000_000
        api = {"five_hour": {"used_percentage": 1, "resets_at": t0 + 100}}
        self.share(_rl(1, t0 + 100, 1, t0 + 90000), now=t0, api=api)
        self.share(_rl(1, t0 + 100, 1, t0 + 90000), now=t0 + sl.API_EVERY - 1, api=api)
        self.assertEqual(self.fetches, 1)
        self.share(_rl(1, t0 + 100, 1, t0 + 90000), now=t0 + sl.API_EVERY, api=api)
        self.assertEqual(self.fetches, 2)

    def test_failed_check_falls_back_to_status_line(self):
        self.login("a@x.ca")
        self.share(_rl(33, 10_000_100, 20, 10_090_000), now=10_000_000, api=None)
        self.assertEqual(self.account("a@x.ca")["five_hour"]["used_percentage"], 33)

    def test_fetch_without_token_returns_none_without_network(self):
        # setUp's credentials hold no accessToken.
        self.login("a@x.ca")
        self.assertIsNone(sl.fetch_usage(self.home))

    def test_file_name_is_case_insensitive_and_path_safe(self):
        self.assertEqual(sl.account_file_name("Yves.Lucet@UBC.ca"), "yves.lucet@ubc.ca.json")
        self.assertNotIn("\\", sl.account_file_name("a\\..\\b@c"))
        self.assertNotIn("/", sl.account_file_name("a/../b@c"))


if __name__ == "__main__":
    unittest.main()
