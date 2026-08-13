# Scripts

## Quick start

After `state`, `.agents`, and `.local` point to sibling directories in one
external storage root, install the user-level backup timer:

```bash
./scripts/install-state-backup.sh
```

Run one backup immediately:

```bash
./scripts/backup-state.sh
```

## State backup

The repository holds only three symlinks. Their external targets hold the
runtime state, private agent instructions, and local machine data. The backup
script resolves those links from its own checkout, verifies that they share one
storage root, and writes snapshots under that root's `backups/` directory.

Each snapshot is timestamped. `rsync --link-dest` hard-links unchanged files
to the preceding snapshot, so snapshots are incremental while each one remains
a complete directory tree. Transient `*.lock` files are excluded.

`clanker-state-backup.timer` runs at `:00` and `:30`. Its persistent setting
runs one catch-up backup when the user systemd manager returns after downtime.
The installed launcher lives at `~/.local/bin/clanker-state-backup`; it is
local configuration and is not committed.
