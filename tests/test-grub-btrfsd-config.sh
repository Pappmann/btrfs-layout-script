#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SNAPPER_SCRIPT="$REPO_DIR/setup-snapper.sh"
TIMESHIFT_SCRIPT="$REPO_DIR/setup-timeshift.sh"

grep -Fq 'GRUB_BTRFSD_DROPIN=/etc/systemd/system/grub-btrfsd.service.d/90-layout-script.conf' "$SNAPPER_SCRIPT"
grep -Fq 'GRUB_BTRFSD_DROPIN=/etc/systemd/system/grub-btrfsd.service.d/90-layout-script.conf' "$TIMESHIFT_SCRIPT"
grep -Fq 'grub_btrfs_present()' "$TIMESHIFT_SCRIPT"
grep -Fq "[[ \"\$package_name\" == \"grub-btrfs\" ]] && grub_btrfs_present" "$TIMESHIFT_SCRIPT"
grep -Fq "ExecStart=\$grub_btrfsd_bin --syslog /.snapshots" "$SNAPPER_SCRIPT"
grep -Fq "ExecStart=\$grub_btrfsd_bin --syslog --timeshift-auto" "$TIMESHIFT_SCRIPT"
grep -Fq 'ExecStart=' "$SNAPPER_SCRIPT"
grep -Fq 'ExecStart=' "$TIMESHIFT_SCRIPT"

if grep -Fq -- '--timeshift-auto' "$SNAPPER_SCRIPT"; then
  echo "FEHLER: setup-snapper.sh enthält einen Timeshift-Modus." >&2
  exit 1
fi
if ! grep -Fq -- '--timeshift-auto' "$TIMESHIFT_SCRIPT"; then
  echo "FEHLER: setup-timeshift.sh enthält keinen Timeshift-Modus." >&2
  exit 1
fi

echo "OK: Snapper und Timeshift konfigurieren grub-btrfsd mit getrennten Modi."
