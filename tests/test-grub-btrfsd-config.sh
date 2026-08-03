#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SNAPPER_SCRIPT="$REPO_DIR/setup-snapper.sh"
TIMESHIFT_SCRIPT="$REPO_DIR/setup-timeshift.sh"
TIMESHIFT_LAUNCHER="$REPO_DIR/timeshift-launcher"
TIMESHIFT_POLICY="$REPO_DIR/org.debian-btrfs.timeshift-grub-btrfs.policy"

grep -Fq 'GRUB_BTRFSD_DROPIN=/etc/systemd/system/grub-btrfsd.service.d/90-layout-script.conf' "$SNAPPER_SCRIPT"
grep -Fq 'GRUB_BTRFSD_DROPIN=/etc/systemd/system/grub-btrfsd.service.d/90-layout-script.conf' "$TIMESHIFT_SCRIPT"
grep -Fq 'GRUB_BTRFS_GENERATOR_BACKUP=/var/lib/btrfs-layout/41_snapshots-btrfs.before-comments-patch' "$TIMESHIFT_SCRIPT"
grep -Fq 'TIMESHIFT_LAUNCHER=/usr/local/bin/timeshift-launcher' "$TIMESHIFT_SCRIPT"
grep -Fq 'LEGACY_SYNC_UNIT=timeshift-grub-btrfs-sync.service' "$TIMESHIFT_SCRIPT"
grep -Fq 'grub_btrfs_present()' "$TIMESHIFT_SCRIPT"
grep -Fq "[[ \"\$package_name\" == \"grub-btrfs\" ]] && grub_btrfs_present" "$TIMESHIFT_SCRIPT"
grep -Fq 'gsub(/"|,/,"")' "$TIMESHIFT_SCRIPT"
# shellcheck disable=SC2016
grep -Fq 'sub(/,[[:space:]]*$/, "", $2)' "$TIMESHIFT_SCRIPT"
grep -Fq "ExecStart=\$grub_btrfsd_bin --syslog /.snapshots" "$SNAPPER_SCRIPT"
grep -Fq "ExecStart=\$grub_btrfsd_bin --syslog --timeshift-auto" "$TIMESHIFT_SCRIPT"
grep -Fq 'ExecStart=' "$SNAPPER_SCRIPT"
grep -Fq 'ExecStart=' "$TIMESHIFT_SCRIPT"
grep -Fq 'install_timeshift_launcher' "$TIMESHIFT_SCRIPT"
grep -Fq 'disable_legacy_sync_watcher' "$TIMESHIFT_SCRIPT"
# shellcheck disable=SC2016
grep -Fq 'systemctl show "$LEGACY_SYNC_UNIT" -p LoadState --value' "$TIMESHIFT_SCRIPT"
# shellcheck disable=SC2016
grep -Fq 'systemctl disable "$LEGACY_SYNC_UNIT"' "$TIMESHIFT_SCRIPT"
# shellcheck disable=SC2016
grep -Fq 'systemctl stop "$LEGACY_SYNC_UNIT"' "$TIMESHIFT_SCRIPT"
grep -Fq '/etc/grub.d/41_snapshots-btrfs' "$TIMESHIFT_LAUNCHER"
grep -Fq '/usr/local/bin/timeshift-launcher' "$TIMESHIFT_POLICY"

if grep -Fq -- '--timeshift-auto' "$SNAPPER_SCRIPT"; then
  echo "FEHLER: setup-snapper.sh enthält einen Timeshift-Modus." >&2
  exit 1
fi
if ! grep -Fq -- '--timeshift-auto' "$TIMESHIFT_SCRIPT"; then
  echo "FEHLER: setup-timeshift.sh enthält keinen Timeshift-Modus." >&2
  exit 1
fi

echo "OK: Snapper und Timeshift konfigurieren grub-btrfsd mit getrennten Modi."
