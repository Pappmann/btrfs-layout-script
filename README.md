# btrfs-layout

Three scripts that turn a Debian, Ubuntu, or other Debian-based server into a well-organized, snapshot-ready Btrfs system:

- **`setup-btrfs.sh`** — migrates a single Btrfs root partition into a clean subvolume layout, ready for Timeshift and container workloads.
- **`setup-timeshift.sh`** — installs and connects Timeshift with `grub-btrfs`, including automatic GRUB regeneration after a GUI comment is saved.
- **`setup-snapper.sh`** — once root runs from a named subvolume, adds a SUSE-style Snapper setup on top: timeline snapshots, snapshots around every `apt` change, and GRUB-bootable snapshots via `grub-btrfs`.

Run `setup-btrfs.sh` first; `setup-timeshift.sh` and `setup-snapper.sh` both require a named root subvolume and will tell you to run it first if that's not the case yet.

## Languages

- English (this file)
- [Deutsch](README.de.md)
- [Español](README.es.md)

## setup-btrfs.sh

`setup-btrfs.sh` turns a **Debian, Ubuntu, or other Debian-based server with a single Btrfs root partition** into a system with a clean subvolume layout, ready for Timeshift and container workloads. Works both for the one-time switch on a fresh install and afterwards on an already-running, migrated system, to add subvolumes that are still missing (no reboot needed).

### What it does

On a Debian (or Debian-based) system with a Btrfs root filesystem, the script:

- Detects the current root device via `findmnt` (e.g. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mounts the Btrfs top-level (`subvolid=5`) under `/mnt/btrfs-root`.
- Checks available disk space upfront (every byte on `/` is briefly duplicated during migration) and aborts if it's too tight.
- Detects a migration that's already (partly) done and automatically switches to an **incremental mode**: if `/` is already running from a named subvolume, root, GRUB, and the default subvolume are left untouched — only subvolumes for target paths that aren't separately mounted yet get added, active immediately, no reboot needed. Each target path is classified individually: already set up correctly (skipped, doesn't even show up in the selection dialog), occupied by something else (skipped with a warning, never overwritten), or still open (candidate for selection).
- Explicitly asks for confirmation in an interactive terminal (type "ja") before changing anything, with a warning about what the script does and that a failure can leave the system unbootable. Skipped without a terminal (automated runs).
- Shows an interactive selection dialog (`whiptail`) when run in a terminal: universally sensible subvolumes (`@root`, `@home`, `@log`, `@cache`, `@tmp_var`, `@tmp`) are pre-selected, everything that depends on the software stack (databases, ClamAV, Docker/Podman, web server docroot) starts deselected — both freely adjustable. Deselected paths simply stay part of `@` without their own subvolume. Without an interactive terminal (e.g. automated runs), only the universally sensible subvolumes are created without prompting.
- Stops known database, datastore, and container services before copying their data if they're currently running. In incremental mode they're restarted after the new mounts are active; in initial migration mode they stay stopped until the reboot — for a consistent copy instead of half-written files.
- Offers an optional interactive APT-only tool selection, with short descriptions, for:
  - `timeshift`: simple system restore snapshots.
  - `snapper`: server/CLI snapshot management for Btrfs.
  - `btrbk`: Btrfs backups and replication over SSH.
  - `btrfsmaintenance`: scheduled scrub, balance, trim, and defrag tasks.
  - `duperemove`: deduplication of matching Btrfs extents.
  - `grub-btrfs`: makes Btrfs snapshots bootable from the GRUB menu — **advanced**: requires an already-configured snapshot manager (Timeshift/Snapper). Use `setup-timeshift.sh` or `setup-snapper.sh` afterwards for the complete integration.

  The tools are only installed — not configured automatically.
- Creates the following subvolumes (idempotent; if they already exist, they are reused):

  - `@` (new root)
  - `@root`
  - `@home`
  - `@spool`
  - `@log`
  - `@cache`
  - `@tmp_var`
  - `@srv`
  - `@tmp`
  - `@opt`
  - `@containers`
  - `@docker`
  - `@mongodb`
  - `@mysql`
  - `@postgresql`
  - `@chroma`
  - `@clamav`
  - `@stalwart`
  - `@elasticsearch`
  - `@opensearch`
  - `@clickhouse`
  - `@cassandra`
  - `@couchdb`
  - `@neo4j`
  - `@rabbitmq`
  - `@docker-volumes`
  - `@containers-volumes`
  - `@www`

- Copies the current root filesystem to `@` (excluding `/dev`, `/proc`, `/sys`, `/run`, `/mnt`, `/media`, `/lost+found`, plus — derived automatically from the mapping below — every path that gets its own subvolume).
- Copies the content of these directories into their matching subvolumes:

  - `/root` → `@root`
  - `/home` → `@home`
  - `/var/spool` → `@spool`
  - `/var/log` → `@log`
  - `/var/cache` → `@cache`
  - `/var/tmp` → `@tmp_var`
  - `/srv` → `@srv`
  - `/tmp` → `@tmp`
  - `/opt` → `@opt`
  - `/var/lib/containers` → `@containers`
  - `/var/lib/docker` → `@docker`
  - `/var/lib/mongodb` → `@mongodb`
  - `/var/lib/mysql` → `@mysql`
  - `/var/lib/postgresql` → `@postgresql`
  - `/var/lib/chroma` → `@chroma`
  - `/var/lib/clamav` → `@clamav`
  - `/var/lib/stalwart` → `@stalwart`
  - `/var/lib/elasticsearch` → `@elasticsearch`
  - `/var/lib/opensearch` → `@opensearch`
  - `/var/lib/clickhouse` → `@clickhouse`
  - `/var/lib/cassandra` → `@cassandra`
  - `/var/lib/couchdb` → `@couchdb`
  - `/var/lib/neo4j` → `@neo4j`
  - `/var/lib/rabbitmq` → `@rabbitmq`
  - `/var/lib/docker/volumes` → `@docker-volumes`
  - `/var/lib/containers/storage/volumes` → `@containers-volumes`
  - `/var/www` → `@www`

  Database and datastore subvolumes (`@mongodb`, `@mysql`, `@postgresql`, `@chroma`, `@clamav`, `@stalwart`, `@elasticsearch`, `@opensearch`, `@clickhouse`, `@cassandra`, `@couchdb`, `@neo4j`, `@rabbitmq`) as well as named Docker/Podman volumes (`@docker-volumes`, `@containers-volumes`) keep normal Btrfs mounts with CoW and checksums, but get `btrfs property set ... compression no` before data is copied. This avoids relying on per-subvolume `compress`/`nodatacow` fstab options, which Btrfs does not support reliably for mounts of the same filesystem. Image layers and metadata in `@docker`/`@containers` themselves stay on the normal compressed policy.

- Prepares empty mountpoints inside the new root (`@`) so that the subvolumes can be mounted there.
- Updates `/etc/fstab` in the running system:

  - Backs up the old file as `fstab.backup-YYYY-MM-DD-HHMMSS`.
  - Comments old Btrfs root lines as `#OLD-ROOT ...`.
  - Appends new Btrfs entries for `/`, `/home`, `/var/log`, `/var/lib/docker`, etc., pointing to the corresponding subvolumes.

- Adjusts GRUB (if present):

  - Replaces `@rootfs` with `@` in `/etc/default/grub` if needed.
  - Runs `update-grub` or `grub-mkconfig -o /boot/grub/grub.cfg` if available.

- Sets the Btrfs default subvolume to `@`, so the system boots from `@`.
- Ensures required mountpoints also exist in the current root (`/home`, `/var/lib/docker`, …).
- Validates the new `/etc/fstab` automatically with `findmnt --verify` (read-only, doesn't remount anything live) and aborts before you accidentally reboot into a broken fstab.

The end result:

- Root runs from `@` (Timeshift-compatible).
- Important paths like `/home`, `/var/log`, `/var/lib/docker`, `/var/www` live on their own subvolumes.

### Requirements

- Debian or Debian-based system using:
  - `apt`
  - `systemd`
- Root filesystem on **Btrfs** (single device), e.g. a single Btrfs partition like `/dev/vda2`; do **not** enable LVM for the root filesystem.
- Run the script as **root**.

The script will install the following packages if missing:

- `rsync`
- `btrfs-progs`

In an interactive run, the script can also offer optional APT packages (`timeshift`, `snapper`, `btrbk`, `btrfsmaintenance`, `duperemove`) if they are available in the configured package repositories. These are skipped in automated/non-interactive runs.

> Simplest on a **fresh server installation**, since every directory is small/empty there. The script also works on already-running systems, **provided there's enough free disk space** (checked automatically — every byte on `/` is briefly duplicated during migration). For a consistent copy, known database, datastore, and container services are automatically stopped before their respective data copy; in incremental mode they're restarted after `mount -a`, and in initial migration mode they stay stopped until the reboot.
>
> Still, on a running system: take a backup first, plan a maintenance window for the final reboot, and keep in mind that applications **outside** this list (e.g. a custom web server process with open files under `/srv` or `/var/www`) keep running during the copy and could in theory end up with an inconsistent snapshot in their subvolume.

### Usage

1. Install Debian with:
   - a small EFI partition (e.g. `/dev/vda1`)
   - one large Btrfs partition as root (e.g. `/dev/vda2`)
   - LVM disabled/not selected for the root filesystem

2. Log in as root (or use `sudo`).

3. Clone this repository:

   ```bash
   git clone https://github.com/debian-btrfs/layout-script.git
   cd btrfs-layout
   ```

4. Make the script executable:

   ```bash
   chmod +x setup-btrfs.sh
   ```

5. Run it:

   ```bash
   sudo ./setup-btrfs.sh
   ```

6. Check `/etc/fstab` and verify that:

   - `/` uses `subvol=@`
   - the extra paths (`/home`, `/var/log`, `/var/lib/docker`, `/var/www`, …) have Btrfs entries with the expected `@…` subvolumes.

7. Apply and test mounts:

   ```bash
   systemctl daemon-reload
   mount -a
   ```

   There should be no errors.

8. Reboot:

   ```bash
   reboot
   ```

9. After reboot, verify:

   ```bash
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /home /var/log /var/lib/docker /var/www
   ```

   You should see:

   - `/` from `...[/@]` with `subvol=@`
   - `/home` from `...[/@home]`, etc.

At this point, Timeshift can use `@` as the root subvolume and your layout is ready for snapshots and container workloads.

## setup-timeshift.sh

`setup-timeshift.sh` connects an existing Timeshift Btrfs configuration to `grub-btrfs`. It does not guess or overwrite the configured backup device or snapshot schedules.

### What it does

- Verifies that `/` runs from a named Btrfs subvolume and that Timeshift is configured in Btrfs mode with a backup device.
- Creates a read-only guard snapshot before changing the system.
- Installs `timeshift` and `inotify-tools` when needed, and reuses a complete manual `grub-btrfs` installation when the package is not available through APT.
- Patches the known `grub-btrfs` parser behavior that strips commas from Timeshift comments; the original generator is backed up under `/var/lib/btrfs-layout/`.
- Enables `grub-btrfsd` where the package provides the service and creates the initial GRUB configuration.
- Installs `timeshift-grub-btrfs-sync.service`. The watcher detects new and deleted snapshots as well as `info.json` writes and renames, so a comment saved after a Timeshift GUI snapshot triggers another GRUB update.
- Keeps the setup idempotent and does not reboot the machine automatically.

### Requirements

- Debian or Debian-based system using `apt` and `systemd`.
- Root filesystem already on a **named** Btrfs subvolume.
- Timeshift already configured for Btrfs with a backup device selected.
- Run the script as **root**.

### Usage

```bash
chmod +x setup-timeshift.sh
sudo ./setup-timeshift.sh
```

For an automated run without a terminal:

```bash
sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-timeshift.sh
```

Verify the integration with:

```bash
systemctl status grub-btrfsd timeshift-grub-btrfs-sync.service
grub-script-check /boot/grub/grub.cfg
grep -n 'Description' /boot/grub/grub-btrfs.cfg
```

Create a snapshot with `timeshift --create --comments "after update"`, or create one in the GUI and save a comment afterwards. The watcher regenerates the GRUB snapshot menu after the metadata change. GRUB boots snapshots read-only; this setup is not an automatic system rollback mechanism.

## setup-snapper.sh

`setup-snapper.sh` turns a Debian, Ubuntu, or other Debian-based server that already runs its root filesystem from a named Btrfs subvolume (e.g. via `setup-btrfs.sh` above) into a SUSE-style Snapper setup: automatic timeline snapshots, snapshots around every `apt` package change, and snapshots bootable straight from the GRUB menu via `grub-btrfs`.

### What it does

On a Debian (or Debian-based) system with `/` already on a named Btrfs subvolume, the script:

- Verifies `/` is Btrfs and running from a named subvolume (e.g. `@`); aborts with a pointer to `setup-btrfs.sh` if not.
- Creates a read-only Btrfs guard snapshot of the current root subvolume before the first change (e.g. `@.before-snapper-setup-...`) as a manual recovery point if setup fails.
- Installs `snapper` and `inotify-tools` (needed by `grub-btrfsd` to watch for new snapshots) if missing.
- Explicitly asks for confirmation in an interactive terminal (type "ja") before changing anything. Without a terminal, the script aborts unless `LAYOUT_SCRIPT_ASSUME_YES=1` is set.
- Creates the `root` Snapper configuration (idempotent — skipped if it already exists), which creates `.snapshots` as a nested Btrfs subvolume.
- Adds `.snapshots` as its own `/etc/fstab` entry and mounts it. The old `fstab` is backed up first and restored automatically if `findmnt --verify` or `mount -a` fails.
- Sets a SUSE-like timeline policy in `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP`, and conservative `TIMELINE_LIMIT_*` values for hourly/daily/weekly/monthly/yearly).
- Installs custom `apt` hooks (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`) that create a paired pre/post snapshot around every package change — Debian/Ubuntu, unlike openSUSE's `zypp` plugin, doesn't ship this integration, so the script writes small wrapper scripts for it.
- Enables the `snapper-timeline.timer` and `snapper-cleanup.timer` systemd timers.
- Installs `grub-btrfs` if it is available from the configured APT repositories, configures `grub-btrfsd` to watch Snapper's `/.snapshots` directory, and runs `update-grub` (or `grub-mkconfig`) so snapshots show up as bootable, read-only entries in the GRUB menu. Timeshift is not required for this path. If the package is unavailable, Snapper setup continues without GRUB menu integration.

### Limitations

Snapshot browsing, diffing individual files, and read-only booting a snapshot via the GRUB menu (`grub-btrfs`) work with this setup if `grub-btrfs` is available. The guard snapshot is intentionally read-only and is a manual recovery point: boot a rescue system, mount the Btrfs top level, create a new writable root snapshot from the guard snapshot, and point the bootloader/fstab back to that restored state. A full bootable **system rollback** the way openSUSE's `snapper rollback` does it additionally requires root to run from inside a `.snapshots/<N>/snapshot` subvolume — that is not automatically the case with a plain `@` layout.

### Requirements

- Debian or Debian-based system using `apt` and `systemd`.
- Root filesystem already on a **named** Btrfs subvolume (run `setup-btrfs.sh` above first if it isn't).
- Run the script as **root**.

The script will install the following packages if missing: `snapper`, `inotify-tools`, optionally `grub-btrfs`.

### Usage

1. Make sure `/` already runs from a named Btrfs subvolume (see `setup-btrfs.sh` above).

2. Make the script executable and run it:

   ```bash
   chmod +x setup-snapper.sh
   sudo ./setup-snapper.sh
   ```

   For automated runs without a terminal:

   ```bash
   sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-snapper.sh
   ```

3. Verify:

   ```bash
   snapper list-configs
   snapper create -d test && snapper list && snapper delete <number>
   systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd
   systemctl cat grub-btrfsd.service
   ```

   For a Snapper-only setup, the effective `ExecStart` must contain `grub-btrfsd --syslog /.snapshots` and must not contain `--timeshift-auto`. `setup-snapper.sh` and `setup-timeshift.sh` manage the same drop-in; run the setup script for the snapshot manager you selected.

   Install/remove a small package to confirm the `apt` hooks create a pre/post snapshot pair, and reboot to confirm the GRUB menu shows a snapshot submenu.

## License

This project is licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.

See the `LICENSE` file for full details.
