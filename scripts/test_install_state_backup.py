"""Drill tests for scripts/install-state-backup.sh.

The installer writes the one file both systemd units read, so where it puts
that file decides whether the settings in it configure anything at all. The
units name `EnvironmentFile=-%h/.config/clanker/backup.env` literally, because
a unit expands no variable there, so an installer that wrote it under
`$XDG_CONFIG_HOME` configured nothing on a host with a custom one, and the
`-` prefix meant nothing said so. These drive the shipped installer with a
stubbed `systemctl` and assert the file lands where the units read it.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("install-state-backup.sh")


class InstallStateBackupTest(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.xdg = self.root / "xdg"
        # The script derives the checkout from its own path, so the drill runs
        # a copy placed inside a fake checkout rather than the repo's own.
        self.repo = self.root / "checkout"
        (self.repo / "scripts" / "systemd").mkdir(parents=True)
        self.script = self.repo / "scripts" / "install-state-backup.sh"
        self.script.write_bytes(SCRIPT.read_bytes())
        self.script.chmod(0o755)
        for unit in ("clanker-state-backup.service", "clanker-state-verify.service"):
            (self.repo / "scripts" / "systemd" / unit).write_text("[Service]\n")
        # A `systemctl` that succeeds for everything, so the run reaches the
        # configuration file on a machine with a real user manager. Its log
        # also shows which units the run would have installed.
        self.bin = self.root / "bin"
        self.bin.mkdir()
        log = self.root / "systemctl.log"
        stub = self.bin / "systemctl"
        stub.write_text(f'#!/bin/sh\necho "$@" >> "{log}"\nexit 0\n')
        stub.chmod(0o755)
        self.log = log

    def run_install(self, xdg_config_home: str | None) -> subprocess.CompletedProcess:
        env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}")
        if xdg_config_home is not None:
            env["XDG_CONFIG_HOME"] = xdg_config_home
        else:
            env.pop("XDG_CONFIG_HOME", None)
        return subprocess.run(
            [str(self.script)],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_config_file_lands_where_the_units_read_it(self) -> None:
        result = self.run_install(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        env_file = self.home / ".config" / "clanker" / "backup.env"
        self.assertTrue(env_file.is_file(), f"missing {env_file}")
        # Owner-only: the destination it carries names a host and a user.
        self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
        # Every setting ships commented, so a commented key reads as unset
        # rather than as an empty off-site destination.
        self.assertIn("#CLANKER_BACKUP_OFFSITE_DEST=", env_file.read_text())

    def test_custom_xdg_config_home_does_not_move_the_file_the_units_read(self) -> None:
        result = self.run_install(str(self.xdg))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".config" / "clanker" / "backup.env").is_file())
        # A file the installer used to write there was read by no unit and by
        # no `clanker doctor`, so a destination in it configured a second
        # failure domain the scheduled run never wrote to.
        self.assertFalse((self.xdg / "clanker" / "backup.env").exists())

    def test_stale_xdg_config_file_is_reported_not_deleted(self) -> None:
        stale = self.xdg / "clanker" / "backup.env"
        stale.parent.mkdir(parents=True)
        stale.write_text("CLANKER_BACKUP_OFFSITE_DEST=/mnt/old\n")
        result = self.run_install(str(self.xdg))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(stale), result.stderr)
        self.assertIn("not read by any unit", result.stderr)
        # It may hold the only copy of a destination the operator set.
        self.assertTrue(stale.is_file())

    def test_a_reinstall_keeps_settings_the_operator_wrote(self) -> None:
        first = self.run_install(None)
        self.assertEqual(first.returncode, 0, first.stderr)
        env_file = self.home / ".config" / "clanker" / "backup.env"
        env_file.write_text("CLANKER_BACKUP_OFFSITE_DEST=/mnt/second-disk\n")
        second = self.run_install(None)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(
            env_file.read_text(), "CLANKER_BACKUP_OFFSITE_DEST=/mnt/second-disk\n"
        )

    def test_the_backup_and_drill_timers_are_enabled(self) -> None:
        result = self.run_install(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text()
        self.assertIn("--user enable --now clanker-state-backup.timer", log)
        self.assertIn("--user enable --now clanker-state-verify.timer", log)


if __name__ == "__main__":
    unittest.main()
