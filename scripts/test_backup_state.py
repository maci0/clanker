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
import time
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

    def test_local_config_and_env_are_in_the_snapshot(self) -> None:
        # These three exist nowhere but the checkout: they are gitignored, so a
        # lost checkout or volume takes them with it and a restored store has
        # no provider to call.
        for name, body in (
            ("config.local.toml", 'default_provider = "anthropic"\n'),
            (".env", "ANTHROPIC_API_KEY=secret\n"),
        ):
            path = self.repo / name
            path.write_text(body)
            path.chmod(0o600)
        connection = self.open_db(self.session_db("s1"))
        connection.close()

        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = self.latest()
        self.assertEqual(
            (snapshot / "config" / "config.local.toml").read_text(),
            'default_provider = "anthropic"\n',
        )
        self.assertEqual(
            (snapshot / "config" / ".env").read_text(), "ANTHROPIC_API_KEY=secret\n"
        )
        # Credentials ride along, so neither the entry nor the root may be
        # readable by anyone else.
        self.assertEqual((snapshot / "config" / ".env").stat().st_mode & 0o777, 0o600)
        self.assertEqual(snapshot.joinpath("config").stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.backups.stat().st_mode & 0o777, 0o700)
        self.assertFalse((snapshot / "config" / "config.toml").exists())

    def test_absent_local_config_adds_no_config_entry(self) -> None:
        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.latest() / "config").exists())

    def test_a_fresh_staging_directory_is_not_pruned(self) -> None:
        # A staging dir can only be another run's while that run is copying,
        # and a run used to delete every one it found. That run then promoted
        # a half-copied tree. Age is what separates garbage from work in
        # progress, so a fresh dir survives this run and an hour-old one does
        # not.
        self.backups.mkdir(parents=True)
        live = self.backups / ".20260101T000000Z.incomplete.LIVEONE"
        dead = self.backups / ".20260101T000000Z.incomplete.DEADONE"
        for path in (live, dead):
            (path / "state").mkdir(parents=True)
        old = time.time() - 7200
        os.utime(dead, (old, old))

        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(live.is_dir(), "pruned a staging directory a live run owns")
        self.assertFalse(dead.exists(), "left abandoned staging garbage behind")
        self.assertTrue((self.latest() / "state" / self.session_db("s1")).exists())

    def test_a_snapshot_promoted_in_the_same_second_is_not_overwritten(self) -> None:
        # The snapshot name is second-granular, so a manual run landing in the
        # same second as the timer's would `mv` its staging tree *into* the
        # snapshot already there, report success, and leave the copy
        # unreachable.
        self.backups.mkdir(parents=True)
        occupied = self.backups / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        (occupied / "state").mkdir(parents=True)
        (occupied / "marker").write_text("first run\n")

        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertTrue(self.latest().is_dir())
        self.assertNotEqual(
            self.latest().resolve(), occupied.resolve(), "second run reused the name"
        )
        self.assertEqual((occupied / "marker").read_text(), "first run\n")
        self.assertEqual(sorted(p.name for p in occupied.iterdir()), ["marker", "state"])
        self.assertTrue(
            (self.latest() / "state" / self.session_db("s1")).exists(),
            "the second run's own copy is not reachable from latest",
        )

    def test_device_global_agent_rules_are_snapshotted(self) -> None:
        # `~/.agents/AGENTS.md` is the first instruction layer of every system
        # prompt and lives in no repository. The checkout's own `.agents` is a
        # different, per-project directory, so covering only that left the
        # device-wide rules with no copy anywhere.
        home_agents = self.root / ".agents"
        home_agents.mkdir()
        (home_agents / "AGENTS.md").write_text("device rules\n")
        project_agents = self.repo / ".agents"
        project_agents.mkdir()
        (project_agents / "AGENTS.md").write_text("project rules\n")

        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)

        latest = self.latest()
        self.assertEqual(
            (latest / "home-agents" / "AGENTS.md").read_text(), "device rules\n"
        )
        self.assertEqual((latest / "agents" / "AGENTS.md").read_text(), "project rules\n")

    def test_absent_home_agents_directory_is_a_soft_skip(self) -> None:
        # A device with no `~/.agents` (the harness reads it fail-open) must
        # still snapshot the store; the entry is skipped, not fatal.
        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.latest() / "home-agents").exists())
        self.assertTrue((self.latest() / "state" / self.session_db("s1")).exists())

    def test_profile_local_overlays_travel_with_the_local_config(self) -> None:
        # `profiles/<name>.local.toml` is the checkout-private half of a named
        # profile, gitignored exactly like `config.local.toml`, so it was as
        # absent from a re-clone as the files beside it.
        profiles = self.repo / "profiles"
        profiles.mkdir()
        (profiles / "web.local.toml").write_text("base_url = \"http://localhost:1234\"\n")
        (profiles / "web.toml").write_text("name = \"web\"\n")
        (self.repo / ".env").write_text("TOKEN=abc\n")

        connection = self.open_db(self.session_db("s1"))
        connection.close()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)

        config = self.latest() / "config"
        self.assertEqual(
            (config / "profiles" / "web.local.toml").read_text(),
            "base_url = \"http://localhost:1234\"\n",
        )
        self.assertEqual((config / ".env").read_text(), "TOKEN=abc\n")
        self.assertFalse(
            (config / "profiles" / "web.toml").exists(),
            "the committed half of the profile is git's backup, not this one's",
        )

    def test_installed_symlink_launcher_resolves_the_checkout(self) -> None:
        # What the systemd unit runs: `~/.local/bin/clanker-state-backup` is a
        # symlink to the script in the checkout. Both links matter -- the
        # launcher and the `state` link -- and resolving only the directory
        # part of either put the backup root inside the checkout, which the
        # script then refused. That is every timer run, so the store was never
        # actually being snapshotted.
        launcher_dir = self.root / "bin"
        launcher_dir.mkdir()
        launcher = launcher_dir / "clanker-state-backup"
        launcher.symlink_to(self.script)
        connection = self.open_db(self.session_db("s1"))
        connection.close()

        result = subprocess.run(
            [str(launcher)],
            cwd=self.repo,
            env=dict(os.environ, HOME=str(self.root)),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.backups.is_dir(), "no snapshot root beside the storage root")
        self.assertTrue((self.latest() / "state" / self.session_db("s1")).exists())
        self.assertFalse(
            (self.repo / "backups").exists(), "snapshot landed inside the checkout"
        )


if __name__ == "__main__":
    unittest.main()
