import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import activate_next_release as rollout


@unittest.skipUnless(rollout.UNIT_PATH.is_file(), "needs the installed unit file to copy as a fixture")
class CurrentAttemptPathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.lock = self.root / "production-rollout.lock"
        self.lock.mkdir(mode=0o700)
        self.before = self.root / "production-before.json"
        self.before.write_text('{"sourceCommit":"test"}\n', encoding="utf-8")
        os.chmod(self.before, 0o600)
        self.backup = self.root / "backup-before-activation"
        self.backup.mkdir(mode=0o700)
        shutil_unit = self.backup / "clutch-chat-bridge.service.before"
        shutil_unit.write_bytes(rollout.UNIT_PATH.read_bytes())
        self.dropin_dir = self.backup / "dropins"
        self.dropin_dir.mkdir(mode=0o700)
        self.dropin_name = "50-fixture.conf"
        self.dropin_file = self.dropin_dir / self.dropin_name
        self.dropin_file.write_text("[Service]\nFixture=yes\n", encoding="utf-8")
        self.dropin_hash = hashlib.sha256(self.dropin_file.read_bytes()).hexdigest()
        self.receipt = self.root / "production-receipt.json"
        self.failure = self.root / "production-failure.json"
        self.config = (self.root, self.root, self.root / "candidate.conf", self.lock, self.before, self.receipt, self.failure, self.backup)
        lock_stat = os.stat(self.lock, follow_symlinks=False)
        self.attempt = {
            "lockIdentity": (lock_stat.st_dev, lock_stat.st_ino),
            "beforeSha256": hashlib.sha256(self.before.read_bytes()).hexdigest(),
            "unitSha256": hashlib.sha256(rollout.UNIT_PATH.read_bytes()).hexdigest(),
            "dropInBackups": [{"path": "/etc/systemd/system.control/50-fixture.conf", "sha256": self.dropin_hash}],
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_current_invocation_artifacts_pass_exact_last_moment_check(self):
        rollout.verify_current_attempt_paths(self.config, self.attempt)

    def test_unrelated_lock_identity_is_not_accepted_as_current_attempt(self):
        self.attempt["lockIdentity"] = (0, 0)
        with self.assertRaises(rollout.base.RolloutStop):
            rollout.verify_current_attempt_paths(self.config, self.attempt)

    def test_modified_before_receipt_is_not_accepted_as_current_attempt(self):
        self.before.write_text('{"sourceCommit":"changed"}\n', encoding="utf-8")
        with self.assertRaises(rollout.base.RolloutStop):
            rollout.verify_current_attempt_paths(self.config, self.attempt)


class ReadinessRetryTests(unittest.TestCase):
    def test_exact_active_count_failure_remains_hard_failure_after_wrapping(self):
        active_turns_error = rollout.base.RolloutStop("postflight-active-turns", {"activeTurnsReported": True, "activeTurns": 1})
        with patch.object(rollout.base, "health", side_effect=active_turns_error):
            with self.assertRaises(rollout.base.RolloutStop) as caught:
                rollout.exact_health("unused", "post-restart-health")
        self.assertEqual(caught.exception.step, "post-restart-health")
        self.assertFalse(rollout.retryable_health_failure(caught.exception))

    def test_turn_count_mismatch_is_never_retryable(self):
        for reported, count in ((True, 1), (False, None)):
            error = rollout.base.RolloutStop("post-restart-health", {"activeTurnsReported": reported, "activeTurns": count})
            self.assertFalse(rollout.retryable_health_failure(error))

    def test_only_transient_connection_and_gateway_errors_retry(self):
        self.assertTrue(rollout.retryable_health_failure(rollout.base.RolloutStop("authenticated-health", {"errorType": "URLError"})))
        self.assertTrue(rollout.retryable_health_failure(rollout.base.RolloutStop("authenticated-health", {"httpStatus": 503})))
        self.assertFalse(rollout.retryable_health_failure(rollout.base.RolloutStop("authenticated-health", {"httpStatus": 401})))
        self.assertFalse(rollout.retryable_health_failure(rollout.base.RolloutStop("other-stage", {"errorType": "URLError"})))


if __name__ == "__main__":
    unittest.main()
