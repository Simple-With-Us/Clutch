import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import activate_next_release as rollout


# The unit file is committed at scripts/systemd/clutch-chat-bridge.service, so these
# tests run on any host instead of skipping when the service is not installed locally.
REPO_UNIT = Path(__file__).resolve().parents[1] / "clutch-chat-bridge.service"


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
        shutil_unit.write_bytes(REPO_UNIT.read_bytes())
        self.dropin_dir = self.backup / "dropins"
        self.dropin_dir.mkdir(mode=0o700)
        self.dropin_name = "50-fixture.conf"
        self.dropin_file = self.dropin_dir / self.dropin_name
        self.dropin_file.write_text("[Service]\nFixture=yes\n", encoding="utf-8")
        self.dropin_hash = hashlib.sha256(self.dropin_file.read_bytes()).hexdigest()
        self.receipt = self.root / "production-receipt.json"
        self.failure = self.root / "production-failure.json"
        self.config = (self.root, self.root, self.root / "candidate.conf", self.lock, self.before, self.receipt, self.failure, self.backup)
        # verify_current_attempt_paths reads the live unit path; point it at the committed fixture.
        self.unit_patcher = patch.object(rollout, "UNIT_PATH", REPO_UNIT)
        self.unit_patcher.start()
        lock_stat = os.stat(self.lock, follow_symlinks=False)
        self.attempt = {
            "lockIdentity": (lock_stat.st_dev, lock_stat.st_ino),
            "beforeSha256": hashlib.sha256(self.before.read_bytes()).hexdigest(),
            "unitSha256": hashlib.sha256(REPO_UNIT.read_bytes()).hexdigest(),
            "dropInBackups": [{"path": "/etc/systemd/system.control/50-fixture.conf", "backup": str(self.dropin_file), "sha256": self.dropin_hash}],
        }

    def tearDown(self):
        self.unit_patcher.stop()
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


class AbortArtifactOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.lock = root / "production-rollout.lock"
        self.backup = root / "backup-before-activation"
        self.before = root / "production-before.json"
        # A prior attempt failed after mutating, so these are its recovery material.
        self.backup.mkdir(mode=0o700)
        (self.backup / "clutch-chat-bridge.service.before").write_text("unit\n", encoding="utf-8")
        self.before.write_text("{}\n", encoding="utf-8")
        base = rollout.base
        for name, value in (("LOCK", self.lock), ("BACKUP", self.backup), ("BEFORE_RECEIPT", self.before)):
            patcher = patch.object(base, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_activate(self, validate):
        with patch.object(rollout.base.sys, "argv", ["activate_release.py", "--activate"]):
            with patch.object(rollout.base, "validate_release", validate):
                with patch("builtins.print"):
                    with self.assertRaises(SystemExit):
                        rollout.base.main()

    def assert_recovery_material_kept(self):
        self.assertTrue((self.backup / "clutch-chat-bridge.service.before").is_file())
        self.assertTrue(self.before.is_file())

    def test_stop_before_lock_keeps_prior_attempt_artifacts(self):
        self.run_activate(lambda: rollout.base.stop("release-validation", valid=False))
        self.assert_recovery_material_kept()

    def test_lock_held_by_prior_attempt_keeps_its_artifacts(self):
        self.lock.mkdir(mode=0o700)
        self.run_activate(lambda: {"sourceCommit": "test"})
        self.assert_recovery_material_kept()
        self.assertTrue(self.lock.is_dir())

    def test_unexpected_error_before_lock_keeps_prior_attempt_artifacts(self):
        def explode():
            raise OSError("unreadable release")
        self.run_activate(explode)
        self.assert_recovery_material_kept()

    def test_reclaim_removes_this_attempts_artifacts(self):
        self.assertTrue(rollout.base.reclaim_attempt_artifacts())
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.before.exists())


if __name__ == "__main__":
    unittest.main()
