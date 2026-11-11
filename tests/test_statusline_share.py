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

    def share(self, data):
        sl.share_usage(data, root=self.root, home=self.home)

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

    def test_file_name_is_case_insensitive_and_path_safe(self):
        self.assertEqual(sl.account_file_name("Yves.Lucet@UBC.ca"), "yves.lucet@ubc.ca.json")
        self.assertNotIn("\\", sl.account_file_name("a\\..\\b@c"))
        self.assertNotIn("/", sl.account_file_name("a/../b@c"))


if __name__ == "__main__":
    unittest.main()
