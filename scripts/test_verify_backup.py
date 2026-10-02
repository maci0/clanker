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

    def test_home_config_entry_is_restored_and_compared(self) -> None:
        # The drill named the extra entries in its own literal list, so an
        # entry the backup started writing was copied by nobody and compared
        # by nobody: `home-config` (the backup unit's own `backup.env`) was
        # exactly that until the list was derived from the snapshot instead.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        env_dir = snap / "home-config" / "clanker"
        env_dir.mkdir(parents=True)
        (env_dir / "backup.env").write_text("CLANKER_BACKUP_RETENTION_DAYS=30\n")
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("home-config", result.stdout)

    def test_an_entry_the_backup_has_not_written_yet_is_simply_absent(self) -> None:
        # The entry set is derived from the snapshot, so a snapshot carrying
        # only `state/` drills exactly that, and no hollow `home-config/` or
        # `home-agents/` is invented for a host that has neither. Deriving it
        # is what keeps the drill from drifting behind the backup's list.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("restored state", result.stdout)
        self.assertNotIn("home-config", result.stdout)
        self.assertNotIn("home-agents", result.stdout)

    def test_unreadable_home_config_entry_fails_the_drill(self) -> None:
        # The half of "the drill covers every entry the snapshot holds" that
        # matters: an entry outside the old literal list was never copied, so
        # a broken copy of it passed green. Here the entry cannot be copied out
        # at all, so the drill has to fail.
        snap = self.snapshot("20260901T120000Z", self.healthy_db())
        env_dir = snap / "home-config" / "clanker"
        env_dir.mkdir(parents=True)
        (env_dir / "backup.env").symlink_to("nowhere.env")
        result = self.run_verify(str(snap))
        self.assertEqual(result.returncode, 1)
        self.assertIn("differs from the snapshot", result.stderr)

    def test_sigterm_during_the_restore_removes_the_store_sized_copy(self) -> None:
        # The unit that runs this drill sets TimeoutStartSec, and systemd
        # answers a run that exceeds it with SIGTERM. An EXIT trap does not
        # fire for that, so the restore's copy of the store was left on the
        # volume every time the timer cut a drill off, forever.
        self.snapshot("20260901T120000Z", self.healthy_db())
        scratch_parent = self.root / "restore-verify"
        scratch_parent.mkdir()
        env = dict(
            os.environ,
            CLANKER_BACKUP_ROOT=str(self.backup_root),
            CLANKER_VERIFY_SCRATCH_DIR=str(scratch_parent),
        )
        process = subprocess.Popen(
            [str(SCRIPT)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertTrue(self.wait_for_scratch(scratch_parent), "drill never staged a copy")
            process.terminate()
            process.communicate(timeout=30)
        finally:
            if process.poll() is None:  # pragma: no cover - only on a hung kill
                process.kill()
                process.communicate()
        self.assertEqual(sorted(p.name for p in scratch_parent.iterdir()), [])

    def test_stale_drill_copies_are_swept_and_a_fresh_one_is_kept(self) -> None:
        # What a SIGKILLed drill (or one from before the signal trap) leaves:
        # a full copy of the store under the scratch parent, which nothing else
        # reclaims. A copy still younger than the bound may belong to a drill
        # running right now, so it stays.
        self.snapshot("20260901T120000Z", self.healthy_db())
        scratch_parent = self.root / "restore-verify"
        stale = scratch_parent / "clanker-restore-verify.stale00"
        fresh = scratch_parent / "clanker-restore-verify.fresh00"
        for leftover, age_days in ((stale, 3), (fresh, 0)):
            (leftover / "state" / "sessions").mkdir(parents=True)
            mtime = time.time() - age_days * DAY
            os.utime(leftover, (mtime, mtime))
        result = self.run_verify(env_extra={"CLANKER_VERIFY_SCRATCH_DIR": str(scratch_parent)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists(), "a three-day-old drill copy was not swept")
        self.assertTrue(fresh.exists(), "a live drill's copy was swept out from under it")
        self.assertEqual(
            sorted(p.name for p in scratch_parent.iterdir()),
            ["clanker-restore-verify.fresh00"],
        )

    def test_unparseable_stale_bound_still_sweeps_and_only_warns(self) -> None:
        # `$(( ... ))` on a non-numeric string is an expansion error, not an
        # assignment error, so `set -e` does not catch it: an unvalidated bound
        # would not fail the drill either, it would skip the sweep and let the
        # garbage grow unbounded. So an unparseable bound warns and then
        # behaves like the default. Zero is a different case, pinned next.
        self.snapshot("20260901T120000Z", self.healthy_db())
        scratch_parent = self.root / "restore-verify"
        stale = scratch_parent / "clanker-restore-verify.stale00"
        (stale / "state" / "sessions").mkdir(parents=True)
        old = time.time() - 3 * DAY
        os.utime(stale, (old, old))
        result = self.run_verify(
            env_extra={
                "CLANKER_VERIFY_SCRATCH_DIR": str(scratch_parent),
                "CLANKER_VERIFY_SCRATCH_STALE_HOURS": "not-a-number",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is not an hour count", result.stderr)
        self.assertFalse(stale.exists(), "an unparseable bound skipped the sweep")

    def test_zero_stale_bound_keeps_every_leftover_copy(self) -> None:
        # CLANKER_BACKUP_RETENTION_DAYS=0 keeps every snapshot, so 0 means keep
        # every copy here. It cannot be a bound of zero seconds: a leftover
        # created a moment ago is younger than the cutoff then, and the sweep
        # would delete a live drill's staging tree out from under it.
        self.snapshot("20260901T120000Z", self.healthy_db())
        scratch_parent = self.root / "restore-verify"
        stale = scratch_parent / "clanker-restore-verify.stale00"
        (stale / "state" / "sessions").mkdir(parents=True)
        old = time.time() - 3 * DAY
        os.utime(stale, (old, old))
        result = self.run_verify(
            env_extra={
                "CLANKER_VERIFY_SCRATCH_DIR": str(scratch_parent),
                "CLANKER_VERIFY_SCRATCH_STALE_HOURS": "0",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in scratch_parent.iterdir()), [stale.name])

    def path_without_rsync(self) -> str:
        """A PATH holding every ordinary tool but no rsync.

        macOS ships no rsync by default, so the drill's only copy has no
        meaning without one. The script used to discover that at the first
        `rsync`, which under `set -euo pipefail` is a bare 127 that reads like
        a broken interpreter rather than a missing dependency; it now refuses
        before staging anything and names the tool. Symlinks, not a copy, so the
        directory still holds the real binaries.
        """
        if shutil.which("rsync") is None:
            self.skipTest("rsync is not installed on this host")
        stub_dir = self.root / "path-no-rsync"
        stub_dir.mkdir()
        for name in ("bash", "sh", "dirname", "basename", "readlink", "pwd", "rm",
                     "mkdir", "mktemp", "chmod", "sort", "find", "date", "du",
                     "ls", "sqlite3", "cmp", "diff", "sleep", "stat"):
            found = shutil.which(name)
            if found is not None:
                (stub_dir / name).symlink_to(found)
        self.assertIsNone(shutil.which("rsync", path=str(stub_dir)))
        return str(stub_dir)

    def test_a_host_without_rsync_says_so_instead_of_exiting_127(self) -> None:
        self.snapshot("20260901T120000Z", self.healthy_db())
        result = self.run_verify(env_extra={"PATH": self.path_without_rsync()})
        self.assertEqual(result.returncode, 1)
        self.assertIn("rsync is required", result.stderr)
        # The drill's own answers must not appear: nothing was restored, so
        # there is no elapsed time, no entry count and no ok line to report.
        self.assertNotIn("ok: ", result.stdout)
        # Nothing may be staged either, or a refusal would still cost a full
        # copy of the store on disk before it stopped.
        self.assertFalse((self.root / "restore-verify").exists())

    def wait_for_scratch(self, scratch_parent: Path) -> bool:
        deadline = time.time() + 20
        while time.time() < deadline:
            if any(scratch_parent.glob("clanker-restore-verify.*")):
                return True
            time.sleep(0.05)
        return False

    def run_verify(
        self, *args: str, env_extra: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess:
        """Run the shipped drill; `env_extra` overrides one variable per call."""
        env = dict(os.environ, CLANKER_BACKUP_ROOT=str(self.backup_root), **(env_extra or {}))
        return subprocess.run(
            [str(SCRIPT), *args],
            env=env, capture_output=True, text=True, check=False,
        )


if __name__ == "__main__":
    unittest.main()
