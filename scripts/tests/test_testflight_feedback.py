import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[2] / ".codex/skills/testflight-feedback/scripts/fetch_feedback.py"
SPEC = importlib.util.spec_from_file_location("fetch_feedback", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TestFlightFeedbackHelpers(unittest.TestCase):
    def test_repository_root_is_the_skill_repository(self):
        self.assertEqual(MODULE.REPOSITORY_ROOT, SCRIPT_PATH.parents[4])

    def test_email_matching_is_exact_and_case_insensitive(self):
        email = MODULE.normalize_email("  Tester@Example.com ")
        self.assertEqual(email, "tester@example.com")
        allowed = {MODULE.fingerprint("tester@example.com")}
        record = {
            "id": "submission-1",
            "attributes": {"email": "Tester@Example.com"},
        }
        self.assertTrue(MODULE.is_eligible(record, allowed))
        record["attributes"]["email"] = "other@example.com"
        self.assertFalse(MODULE.is_eligible(record, allowed))

    def test_settings_reject_placeholders(self):
        with tempfile.TemporaryDirectory() as directory:
            settings_path = Path(directory) / "settings.json"
            settings_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "app_id": "<APP_STORE_CONNECT_APP_ID>",
                        "read_profile": "read",
                        "delete_profile": "delete",
                        "github_repository": "owner/repository",
                        "base_branch": "main",
                        "github_host": "github.com",
                    }
                ),
                encoding="utf-8",
            )
            original = MODULE.SETTINGS_PATH
            MODULE.SETTINGS_PATH = settings_path
            try:
                with self.assertRaises(ValueError):
                    MODULE.load_settings()
            finally:
                MODULE.SETTINGS_PATH = original

    def test_submission_fingerprint_is_opaque(self):
        value = MODULE.fingerprint("submission-1")
        self.assertRegex(value, r"^[0-9a-f]{64}$")
        self.assertNotIn("submission-1", value)


if __name__ == "__main__":
    unittest.main()
