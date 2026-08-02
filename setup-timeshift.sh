#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASSUME_YES=${LAYOUT_SCRIPT_ASSUME_YES:-0}
TOPLEVEL_MNT=""
GUARD_SNAPSHOT=""
APT_UPDATED=0
TIMESHIFT_CONFIG=/etc/timeshift/timeshift.json
SYNC_CONFIG=/etc/default/timeshift-grub-btrfs-sync
SYNC_UNIT=/etc/systemd/system/timeshift-grub-btrfs-sync.service
SYNC_HELPER=/usr/local/sbin/timeshift-grub-btrfs-sync.sh

usage() {
  cat <<'EOF'
Usage: setup-timeshift.sh

Installiert und verbindet Timeshift im Btrfs-Modus mit grub-btrfs.
Die vorhandene Timeshift-Konfiguration sowie Zeitpläne und Backup-Geräte
werden übernommen und nicht automatisch überschrieben.

Für automatisierte Läufe ohne Terminal:
  LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-timeshift.sh
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

cleanup() {
  if [[ -n "$TOPLEVEL_MNT" && -d "$TOPLEVEL_MNT" ]]; then
    umount "$TOPLEVEL_MNT" 2>/dev/null || true
    rmdir "$TOPLEVEL_MNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_command() {
  local command_name="$1" hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "FEHLER: Benötigtes Kommando '$command_name' fehlt. $hint" >&2
    exit 1
  fi
}

for command_name in apt-get apt-cache awk blkid btrfs findmnt grep mount mktemp sed systemctl umount; do
  require_command "$command_name" "Bitte die passenden Debian-Systemwerkzeuge installieren."
done

apt_package_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

ensure_apt_updated() {
  if [[ "$APT_UPDATED" != "1" ]]; then
    echo ">>> Aktualisiere APT-Paketindex"
    apt-get update
    APT_UPDATED=1
  fi
}

need_pkg() {
  local command_name="$1" package_name="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    echo ">>> Abhängigkeit $package_name ($command_name) ist bereits vorhanden."
    return 0
  fi

  if ! apt_package_available "$package_name"; then
    echo "FEHLER: Paket '$package_name' ist in den konfigurierten APT-Quellen nicht verfügbar." >&2
    exit 1
  fi

  echo ">>> Installiere benötigtes Paket: $package_name"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"
}

confirm_or_abort() {
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo ">>> LAYOUT_SCRIPT_ASSUME_YES=1 gesetzt, Bestätigung übersprungen."
  elif [[ -t 0 ]]; then
    read -r -p "Guard-Snapshot erstellen und Timeshift/grub-btrfs einrichten? Exakt 'ja' eingeben: " confirm
    if [[ "$confirm" != "ja" ]]; then
      echo "Abgebrochen." >&2
      exit 1
    fi
  else
    echo "FEHLER: Kein interaktives Terminal. Setze LAYOUT_SCRIPT_ASSUME_YES=1 für automatisierte Läufe." >&2
    exit 1
  fi
}

ROOT_SRC=$(findmnt -no SOURCE / || true)
FSTYPE=$(findmnt -no FSTYPE / || true)
if [[ "$FSTYPE" != "btrfs" ]]; then
  echo "/ ist kein Btrfs-Dateisystem (FSTYPE=${FSTYPE:-unbekannt}). Abbruch." >&2
  exit 1
fi
if [[ -z "$ROOT_SRC" || "$ROOT_SRC" != *"["* ]]; then
  echo "FEHLER: / läuft nicht von einem benannten Btrfs-Subvolume (aktuell: ${ROOT_SRC:-unbekannt})." >&2
  echo "Bitte zuerst setup-btrfs.sh ausführen." >&2
  exit 1
fi

ROOT_DEV=${ROOT_SRC%%[*}
ROOT_SUBVOL=${ROOT_SRC#*[/}
ROOT_SUBVOL=${ROOT_SUBVOL%]}
UUID=$(blkid -s UUID -o value "$ROOT_DEV" || true)
if [[ -z "$UUID" || -z "$ROOT_SUBVOL" || "$ROOT_SUBVOL" == "$ROOT_SRC" ]]; then
  echo "FEHLER: Btrfs-Root-Device, UUID oder Subvolume konnte nicht ermittelt werden." >&2
  exit 1
fi

echo ">>> Root-Device: $ROOT_DEV"
echo ">>> Root-Subvolume: $ROOT_SUBVOL"
echo ">>> Timeshift-Konfiguration: $TIMESHIFT_CONFIG"

ensure_apt_updated
for package_name in timeshift grub-btrfs inotify-tools; do
  if ! package_installed "$package_name" && ! apt_package_available "$package_name"; then
    echo "FEHLER: Paket '$package_name' ist nicht installiert und nicht verfügbar." >&2
    exit 1
  fi
done

echo
echo "!!! ACHTUNG !!!"
echo "Dieses Skript erstellt einen read-only Guard-Snapshot und installiert"
echo "Timeshift/grub-btrfs samt einem systemd-Watcher für nachträgliche"
echo "Timeshift-Kommentaränderungen. Vorhandene Timeshift-Geräte und Zeitpläne"
echo "werden nicht überschrieben; ein Neustart wird nicht automatisch ausgelöst."
echo
confirm_or_abort

create_guard_snapshot() {
  local timestamp src parent base dest existing_guards

  timestamp=$(date +%F-%H%M%S)
  mkdir -p /mnt
  TOPLEVEL_MNT=$(mktemp -d /mnt/btrfs-toplevel.XXXXXX)
  echo ">>> Mounte Btrfs-Top-Level nach $TOPLEVEL_MNT"
  mount -o subvolid=5 "$ROOT_DEV" "$TOPLEVEL_MNT"

  src="$TOPLEVEL_MNT/$ROOT_SUBVOL"
  if [[ ! -d "$src" ]]; then
    echo "FEHLER: Root-Subvolume wurde unter $src nicht gefunden." >&2
    exit 1
  fi

  existing_guards=$(btrfs subvolume list "$TOPLEVEL_MNT" | awk '{print $NF}' | grep -- '\.before-timeshift-setup-' || true)
  if [[ -n "$existing_guards" ]]; then
    echo ">>> Hinweis: Guard-Snapshot(s) aus früheren Läufen gefunden (werden nicht automatisch gelöscht):"
    while IFS= read -r guard; do
      printf '    %s\n' "$guard"
    done <<< "$existing_guards"
  fi

  parent=$(dirname "$ROOT_SUBVOL")
  base=$(basename "$ROOT_SUBVOL")
  if [[ "$parent" == "." ]]; then
    dest="$TOPLEVEL_MNT/${base}.before-timeshift-setup-${timestamp}"
    GUARD_SNAPSHOT="${base}.before-timeshift-setup-${timestamp}"
  else
    dest="$TOPLEVEL_MNT/${parent}/${base}.before-timeshift-setup-${timestamp}"
    GUARD_SNAPSHOT="${parent}/${base}.before-timeshift-setup-${timestamp}"
  fi

  if [[ -e "$dest" ]]; then
    echo "FEHLER: Guard-Snapshot-Ziel existiert bereits: $dest" >&2
    exit 1
  fi

  echo ">>> Erzeuge read-only Guard-Snapshot: $GUARD_SNAPSHOT"
  btrfs subvolume snapshot -r "$src" "$dest"
  umount "$TOPLEVEL_MNT"
  rmdir "$TOPLEVEL_MNT"
  TOPLEVEL_MNT=""
}

create_guard_snapshot

need_pkg timeshift timeshift
need_pkg grub-btrfsd grub-btrfs
need_pkg inotifywait inotify-tools
if ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-mkconfig >/dev/null 2>&1; then
  need_pkg grub-mkconfig grub-common
fi

if [[ ! -f "$TIMESHIFT_CONFIG" ]]; then
  echo "FEHLER: $TIMESHIFT_CONFIG fehlt." >&2
  echo "Timeshift einmalig im Btrfs-Modus konfigurieren und das Skript danach erneut ausführen." >&2
  exit 1
fi
if ! grep -Eq '"btrfs_mode"[[:space:]]*:[[:space:]]*(true|"true")' "$TIMESHIFT_CONFIG"; then
  echo "FEHLER: Timeshift ist laut $TIMESHIFT_CONFIG nicht im Btrfs-Modus." >&2
  echo "Bitte in Timeshift Btrfs als Snapshot-Modus wählen und anschließend erneut ausführen." >&2
  exit 1
fi
if ! grep -Eq '"backup_device_uuid"[[:space:]]*:[[:space:]]*"[^"]+"' "$TIMESHIFT_CONFIG"; then
  echo "FEHLER: Timeshift hat noch kein Backup-Gerät konfiguriert." >&2
  echo "Bitte das Btrfs-Backup-Gerät in Timeshift auswählen und anschließend erneut ausführen." >&2
  exit 1
fi

install -D -m 0755 "$SCRIPT_DIR/timeshift-grub-btrfs-sync.sh" "$SYNC_HELPER"
install -D -m 0644 "$SCRIPT_DIR/timeshift-grub-btrfs-sync.service" "$SYNC_UNIT"

if [[ ! -e "$SYNC_CONFIG" ]]; then
  install -D -m 0644 /dev/null "$SYNC_CONFIG"
  printf '%s\n%s\n%s\n' \
    '# Managed by debian-btrfs/layout-script setup-timeshift.sh' \
    'TIMESHIFT_WATCH_ROOT=/run/timeshift' \
    'TIMESHIFT_EVENT_DELAY=3' > "$SYNC_CONFIG"
else
  echo ">>> Bewahre vorhandene Watcher-Konfiguration $SYNC_CONFIG auf."
fi

systemctl daemon-reload
if systemctl list-unit-files grub-btrfsd.service 2>/dev/null | grep -q '^grub-btrfsd\.service'; then
  echo ">>> Aktiviere grub-btrfsd"
  systemctl enable --now grub-btrfsd.service
else
  echo "WARNUNG: Keine grub-btrfsd.service-Unit gefunden; der Timeshift-Watcher übernimmt Snapshot-Ereignisse selbst." >&2
fi

echo ">>> Erzeuge initiale GRUB-Konfiguration"
if command -v update-grub >/dev/null 2>&1; then
  update-grub
else
  grub_dir=/boot/grub
  if [[ -r /etc/default/grub-btrfs/config ]]; then
    # shellcheck disable=SC1091
    . /etc/default/grub-btrfs/config
    grub_dir=${GRUB_BTRFS_GRUB_DIRNAME:-$grub_dir}
  fi
  grub-mkconfig -o "$grub_dir/grub.cfg"
fi

systemctl enable --now timeshift-grub-btrfs-sync.service

grub_dir=/boot/grub
if [[ -r /etc/default/grub-btrfs/config ]]; then
  # shellcheck disable=SC1091
  . /etc/default/grub-btrfs/config
  grub_dir=${GRUB_BTRFS_GRUB_DIRNAME:-$grub_dir}
fi
grub_config="$grub_dir/grub.cfg"

if command -v grub-script-check >/dev/null 2>&1 && [[ -f "$grub_config" ]]; then
  grub-script-check "$grub_config"
fi
if [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
  echo ">>> /etc/grub.d/41_snapshots-btrfs ist ausführbar."
else
  echo "WARNUNG: /etc/grub.d/41_snapshots-btrfs fehlt oder ist nicht ausführbar." >&2
fi
if [[ -f "$grub_config" ]] && ! grep -Fq 'snapshots-btrfs' "$grub_config"; then
  echo "WARNUNG: $grub_config enthält noch keinen snapshots-btrfs-Eintrag." >&2
fi

echo
echo ">>> FERTIG."
echo "Guard-Snapshot: $GUARD_SNAPSHOT"
echo "Watcher: systemctl status timeshift-grub-btrfs-sync.service"
echo "GRUB-Prüfung: grep -n 'Description' $grub_dir/grub-btrfs.cfg"
echo "Der nächste Timeshift-Snapshot sowie nachträglich gespeicherte Kommentare"
echo "lösen automatisch eine neue grub-btrfs-Konfiguration aus."
