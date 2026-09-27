"""Drill tests for scripts/backup-state.sh.

The backup script's exit code is the only signal systemd ever sees, so these
drive the shipped script against a real checkout layout (with `state` linked
to an external storage root, which is the arrangement the script insists on)
and assert the properties a snapshot has to have: every database in the store
is checkpointed into something loadable, a corrupt conversation store refuses
promotion, and the derived search index does not take the backup down with it.
"""

import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("backup-state.sh")
HAVE_SQLITE3_CLI = subprocess.run(
    ["sh", "-c", "command -v sqlite3"], capture_output=True
).returncode == 0


class BackupStateTest(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.repo = self.root / "checkout"
        self.storage = self.root / "storage"
        self.state = self.storage / "state"
        self.state.mkdir(parents=True)
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "state").symlink_to(self.state, target_is_directory=True)
        self.backups = self.storage / "backups"
        # The script derives the checkout from its own path, so the drill runs
        # a copy placed inside the fake checkout rather than the repo's own.
        self.script = self.repo / "scripts" / "backup-state.sh"
        self.script.write_bytes(SCRIPT.read_bytes())
        self.script.chmod(0o755)

    def run_backup(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(self.script)],
            cwd=self.repo,
            env=dict(os.environ, HOME=str(self.root)),
            capture_output=True,
            text=True,
        )

    def open_db(self, rel: str) -> sqlite3.Connection:
        path = self.state / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(path)
        connection.execute("PRAGMA journal_mode=WAL;")
        connection.execute(
            "create table if not exists messages (id integer primary key, body text)"
        )
        connection.commit()
        return connection

    def latest(self) -> Path:
        return (self.backups / "latest").resolve()

    def session_db(self, session_id: str) -> str:
        return f"sessions/{session_id}.db"

    def mesh_db(self, owner: str, session_id: str) -> str:
        return f"mesh/{owner}/sessions/{session_id}.db"

    @unittest.skipUnless(HAVE_SQLITE3_CLI, "sqlite3 CLI not installed")
    def test_hot_wal_databases_are_checkpointed_into_the_snapshot(self) -> None:
        # A live writer with an uncheckpointed wal is the case the checkpoint
        # exists for: the snapshot has to carry the committed row as a single
        # loadable file, for a conversation and for a replicated peer
        # conversation alike.
        handles = []
        try:
            for rel, body in (
                (self.session_db("s1"), "own turn"),
                (self.mesh_db("peer", "s9"), "replicated turn"),
            ):
                connection = self.open_db(rel)
                connection.execute("insert into messages (body) values (?)", (body,))
                connection.commit()
                handles.append(connection)
            self.assertTrue((self.state / "sessions/s1.db-wal").exists(), "writer left no wal")

            result = self.run_backup()
            self.assertEqual(result.returncode, 0, result.stderr)
            snapshot = self.latest()
            for rel, body in (
                (self.session_db("s1"), "own turn"),
                (self.mesh_db("peer", "s9"), "replicated turn"),
            ):
                copied = snapshot / "state" / rel
                self.assertTrue(copied.exists(), f"{rel} missing from snapshot")
                rows = sqlite3.connect(copied).execute("select body from messages").fetchall()
                self.assertEqual(rows, [(body,)], f"{rel} lost its committed row")
            # A wal left carrying committed rows in the snapshot is a database
            # whose main file and sidecar never existed together on disk, so a
            # copy of one without the other is unrestorable.
            uncheckpointed = [
                p.name for p in (snapshot / "state").rglob("*-wal") if p.stat().st_size
            ]
            self.assertEqual(uncheckpointed, [], "snapshot carries a live wal")
        finally:
            for connection in handles:
                connection.close()

    @unittest.skipUnless(HAVE_SQLITE3_CLI, "sqlite3 CLI not installed")
    def test_corrupt_replicated_conversation_refuses_promotion(self) -> None:
        # A peer's conversations are the ones this instance has no live peer
        # left to re-sync from, so a replica that does not load is as fatal to
        # the snapshot as a local one.
        healthy = self.open_db(self.session_db("s1"))
        healthy.close()
        good = self.run_backup()
        self.assertEqual(good.returncode, 0, good.stderr)
        promoted = self.latest()

        (self.state / self.mesh_db("peer", "s9")).parent.mkdir(parents=True, exist_ok=True)
        (self.state / self.mesh_db("peer", "s9")).write_bytes(b"not a sqlite database at all")
        result = self.run_backup()
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to promote a corrupt snapshot", result.stderr)
        self.assertEqual(self.latest(), promoted, "latest moved onto a corrupt snapshot")

    @unittest.skipUnless(HAVE_SQLITE3_CLI, "sqlite3 CLI not installed")
    def test_corrupt_conversation_database_refuses_promotion(self) -> None:
        healthy = self.open_db(self.session_db("good"))
        healthy.execute("insert into messages (body) values ('keep')")
        healthy.commit()
        healthy.close()
        good = self.run_backup()
        self.assertEqual(good.returncode, 0, good.stderr)
        promoted = self.latest()

        broken = self.state / self.session_db("bad")
        broken.write_bytes(b"not a sqlite database at all")
        result = self.run_backup()
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to promote a corrupt snapshot", result.stderr)
        self.assertEqual(self.latest(), promoted, "latest moved onto a corrupt snapshot")

    @unittest.skipUnless(HAVE_SQLITE3_CLI, "sqlite3 CLI not installed")
    def test_derived_search_index_does_not_fail_the_backup(self) -> None:
        # The FTS index is rebuilt from the session databases and read
        # fail-open, so a corrupt one is reported and the snapshot is kept.
        healthy = self.open_db(self.session_db("s1"))
        healthy.close()
        (self.state / "session_fts.db").write_bytes(b"not a sqlite database at all")
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("search index is derived", result.stderr)
        self.assertTrue(self.latest().exists())

    @unittest.skipUnless(HAVE_SQLITE3_CLI, "sqlite3 CLI not installed")
    def test_backup_root_inside_the_checkout_is_refused(self) -> None:
        # A real (unsymlinked) `state` in the checkout would snapshot onto the
        # same disk as the data; that must fail, not exit 0.
        (self.repo / "state").unlink()
        (self.repo / "state").mkdir()
        result = self.run_backup()
        self.assertEqual(result.returncode, 1)
        self.assertIn("is inside the checkout", result.stderr)

    def test_absent_agents_and_local_directories_do_not_block_state(self) -> None:
        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is absent; skipping", result.stderr)
        self.assertTrue((self.latest() / "state" / self.session_db("s1")).exists())


if __name__ == "__main__":
    unittest.main()
