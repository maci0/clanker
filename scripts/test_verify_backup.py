"""Drill tests for scripts/verify-backup.sh.

A restore drill is only worth its exit code if the things it is supposed to
catch actually fail it, so these drive the shipped script against real
snapshot trees: a healthy snapshot, a snapshot whose wal was never
checkpointed (byte-identical, does not load), a backup root that stopped
being written, and a deliberately chosen old snapshot.
"""

import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify-backup.sh")
DAY = 86400


class VerifyBackupTest(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.backup_root = self.root / "backups"
        self.addCleanup(self._tmp.cleanup)

    def snapshot(self, name: str, db: bytes | None = None) -> Path:
        snap = self.backup_root / name
        (snap / "state" / "sessions").mkdir(parents=True)
        (snap / "state" / "sessions" / "s1.db").write_bytes(db if db is not None else b"")
        latest = self.backup_root / "latest"
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(name)
        return snap

    def healthy_db(self) -> bytes:
        path = self.root / "seed.db"
        connection = sqlite3.connect(path)
        connection.execute("create table messages (id integer primary key, body text)")
        connection.execute("insert into messages (body) values ('hello')")
        connection.commit()
        connection.close()
        return path.read_bytes()

    @unittest.skipIf(shutil.which("sqlite3") is None, "sqlite3 CLI not installed")
    def test_healthy_snapshot_reports_ok_with_its_size(self) -> None:
        self.snapshot("20260901T120000Z", self.healthy_db())
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok: 20260901T120000Z", result.stdout)
        self.assertIn("databases load", result.stdout)

    @unittest.skipIf(shutil.which("sqlite3") is None, "sqlite3 CLI not installed")
    def test_restored_database_that_does_not_load_fails_the_drill(self) -> None:
        # Bytes that are not a database at all: the copy is faithful, so only
        # opening the restored file can tell the operator it is unrestorable.
        self.snapshot("20260901T120000Z", b"this is not a sqlite database")
        result = self.run_verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not load", result.stderr)

    def snapshot_with(self, name: str, files: dict[str, bytes]) -> Path:
        """Build a snapshot holding arbitrary `relpath -> bytes` under state/."""
        snap = self.backup_root / name
        for rel, data in files.items():
            path = snap / "state" / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        latest = self.backup_root / "latest"
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(name)
        return snap

    def test_replicated_conversation_that_does_not_load_fails_the_drill(self) -> None:
        # A peer's conversations are held here and no longer re-syncable from
        # a live peer, so a replica that does not open is as unrestorable as
        # a local session database.
        self.snapshot_with(
            "20260901T120000Z", {"mesh/peer/sessions/s9.db": b"not a sqlite database"}
        )
        result = self.run_verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not load", result.stderr)
        self.assertIn("mesh/peer/sessions/s9.db", result.stderr)

    @unittest.skipIf(shutil.which("sqlite3") is None, "sqlite3 CLI not installed")
    def test_corrupt_derived_search_index_does_not_fail_the_drill(self) -> None:
        # The search index rebuilds from the session databases and is read
        # fail-open, so it must not declare the rest of the store unrestorable.
        self.snapshot_with(
            "20260901T120000Z",
            {"session_fts.db": b"not a sqlite database", "sessions/s1.db": self.healthy_db()},
        )
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("search index is derived", result.stderr)

    def test_stale_newest_snapshot_fails_the_drill(self) -> None:
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        old = time.time() - 3 * DAY
        os.utime(snap, (old, old))
        result = self.run_verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn("backups are not running", result.stderr)

    def test_fresh_newest_snapshot_passes_the_age_bound(self) -> None:
        self.snapshot("20260901T120000Z", self.healthy_db())
        result = self.run_verify(env_extra={"CLANKER_BACKUP_MAX_AGE_SECONDS": str(DAY)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is 0m old", result.stdout)

    def test_chosen_old_snapshot_skips_the_age_check(self) -> None:
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        old = time.time() - 3 * DAY
        os.utime(snap, (old, old))
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_root_reports_the_backup_has_never_run(self) -> None:
        result = self.run_verify()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no snapshot has ever been promoted", result.stderr)

    def test_device_global_rules_entry_is_restored_and_compared(self) -> None:
        # `~/.agents/AGENTS.md` is a snapshot entry of its own, and the drill
        # has to carry it: an entry the backup writes but the drill skips is a
        # file whose restorability nobody ever checks.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        (snap / "home-agents").mkdir()
        (snap / "home-agents" / "AGENTS.md").write_text("device rules\n")
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("home-agents", result.stdout)

    def test_unreadable_device_global_rules_fail_the_drill(self) -> None:
        # A `home-agents` entry that is a dangling symlink: the directory
        # cannot be copied out, so the drill must fail rather than report the
        # snapshot as restorable.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        (snap / "home-agents").mkdir()
        (snap / "home-agents" / "AGENTS.md").symlink_to("nowhere.md")
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 1)
        self.assertIn("differs from the snapshot", result.stderr)

    def test_empty_offsite_mirror_fails_the_drill(self) -> None:
        # A configured second failure domain holding no `latest` is exactly
        # what the drill exists to catch, and it used to warn and exit 0.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        mirror = self.root / "mirror"
        mirror.mkdir()
        result = self.run_verify(str(snap), env_extra={"CLANKER_BACKUP_OFFSITE_DEST": str(mirror)})
        self.assertEqual(result.returncode, 1)
        self.assertIn("second failure domain is empty or stale", result.stderr)

    def test_populated_offsite_mirror_passes_the_drill(self) -> None:
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        mirror = self.root / "mirror"
        mirror.mkdir()
        # The mirror carries the whole backup root, so `latest` resolves to a
        # directory there, as it does after a successful mirror run.
        (mirror / "20260901T120000Z").mkdir()
        (mirror / "latest").symlink_to("20260901T120000Z")
        result = self.run_verify(str(snap), env_extra={"CLANKER_BACKUP_OFFSITE_DEST": str(mirror)})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checkout_data_entry_is_restored_and_compared(self) -> None:
        # An entry the backup writes but the drill skips is a file whose
        # restorability nobody ever checks; the drill has to carry the
        # checkout-side data entry for the same reason it carries home-agents.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        (snap / "checkout-data" / "ui" / "plugins" / "timer").mkdir(parents=True)
        (snap / "checkout-data" / "ui" / "plugins" / "timer" / "app.js").write_text("// timer\n")
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("checkout-data", result.stdout)

    def run_verify(
        self, *args: str, env_extra: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess:
        """Run the shipped drill; `env_extra` overrides one variable per call."""
        env = dict(os.environ, CLANKER_BACKUP_ROOT=str(self.backup_root), **(env_extra or {}))
        return subprocess.run(
            [str(SCRIPT), *args],
            env=env, capture_output=True, text=True,
        )


if __name__ == "__main__":
    unittest.main()
