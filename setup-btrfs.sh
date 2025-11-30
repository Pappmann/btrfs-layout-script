#!/usr/bin/env bash
set -euo pipefail

echo ">>> Btrfs-Setup: Root auf @ + alle Subvolumes/Mounts (final)"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen." >&2
  exit 1
fi

# --- Abhängigkeiten sicherstellen (Debian/apt) ---
need_pkg() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo ">>> Installiere benötigtes Paket: $pkg"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    echo ">>> Abhängigkeit $pkg ($cmd) ist bereits vorhanden."
  fi
}

need_pkg rsync rsync
need_pkg btrfs btrfs-progs

# --- Root-Quelle ermitteln, z.B. /dev/vda2[/@rootfs] ---
ROOT_SRC=$(findmnt -no SOURCE / || true)
if [[ -z "$ROOT_SRC" ]]; then
  echo "Konnte Root-Quelle nicht ermitteln." >&2
  exit 1
fi

ROOT_DEV=${ROOT_SRC%%[*}

FSTYPE=$(findmnt -no FSTYPE / || true)
if [[ "$FSTYPE" != "btrfs" ]]; then
  echo "/ ist kein Btrfs-Dateisystem (FSTYPE=$FSTYPE). Abbruch." >&2
  exit 1
fi

UUID=$(blkid -s UUID -o value "$ROOT_DEV" || true)
if [[ -z "$UUID" ]]; then
  echo "Konnte UUID von $ROOT_DEV nicht ermitteln. Abbruch." >&2
  exit 1
fi

MNT=/mnt/btrfs-root
if mount | grep -q " on $MNT "; then
  echo "$MNT ist bereits gemountet, bitte zuerst aushängen." >&2
  exit 1
fi
mkdir -p "$MNT"

echo ">>> Mount Top-Level (subvolid=5) von $ROOT_DEV nach $MNT"
mount -o subvolid=5 "$ROOT_DEV" "$MNT"

echo ">>> Vorhandene Subvolumes:"
btrfs subvolume list "$MNT" || true

create_subvol() {
  local name="$1"
  if btrfs subvolume list "$MNT" | awk '{print $NF}' | grep -qx "$name"; then
    echo "Subvolume $name existiert bereits – ok."
  else
    echo "Erzeuge Subvolume $name"
    btrfs subvolume create "$MNT/$name"
  fi
}

# --- alle Subvolumes anlegen (Root @ wird später befüllt) ---
for name in @ @root @home @spool @log @cache @tmp_var @srv @tmp @opt @containers @docker @www; do
  create_subvol "$name"
done

# --- Mapping Quelle -> Subvolume (für Daten) ---
declare -a MAPS=(
"/root:@root"
"/home:@home"
"/var/spool:@spool"
"/var/log:@log"
"/var/cache:@cache"
"/var/tmp:@tmp_var"
"/srv:@srv"
"/tmp:@tmp"
"/opt:@opt"
"/var/lib/containers:@containers"
"/var/lib/docker:@docker"
"/var/www:@www"
)

sync_dir() {
  local src="$1"    # z.B. /home
  local subvol="$2" # z.B. @home

  if [[ ! -d "$src" ]]; then
    echo "Quelle $src existiert nicht, überspringe."
    return
  fi

  echo ">>> Übertrage $src nach $subvol (überschreibend)"
  rsync -axHAX --delete "$src"/ "$MNT/$subvol"/
}

echo ">>> Übertrage /root, /home, /var/... in ihre Subvolumes"
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  sync_dir "$src" "$sub"
done

# --- fstab im laufenden System anpassen ---
FSTAB="/etc/fstab"
backup="${FSTAB}.backup-$(date +%F-%H%M%S)"
echo ">>> Sicherung der aktuellen fstab nach $backup"
cp "$FSTAB" "$backup"

tmp="${FSTAB}.new"
echo ">>> Kommentiere alte Btrfs-Root-Zeile(n) aus"

awk '
  $0 !~ /^[[:space:]]*#/ && $2 == "/" && $3 == "btrfs" {
    print "#OLD-ROOT " $0
    next
  }
  { print }
' "$backup" > "$tmp"
mv "$tmp" "$FSTAB"

add_fstab_entry() {
  local mp="$1" sub="$2" opts="$3" pass="$4"
  if grep -Eq "^[^#[:space:]]+[[:space:]]+${mp}[[:space:]]+btrfs" "$FSTAB"; then
    echo ">>> fstab: Eintrag für ${mp} existiert bereits, überspringe."
  else
    echo "UUID=${UUID} ${mp} btrfs ${opts},subvol=${sub} 0 ${pass}" >> "$FSTAB"
    echo ">>> fstab: Eintrag für ${mp} hinzugefügt."
  fi
}



# Root mit subvol=@
add_fstab_entry / @ "noatime,compress=zstd,space_cache=v2" 1

# weitere Mounts (pass=2)
add_fstab_entry /root @root "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /home @home "noatime,compress=zstd,space_cache=v2,autodefrag" 2
add_fstab_entry /var/spool @spool "noatime,compress=zstd,space_cache=v2,autodefrag" 2
add_fstab_entry /var/log @log "noatime,compress=zstd,space_cache=v2,autodefrag" 2
add_fstab_entry /var/cache @cache "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /var/tmp @tmp_var "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /srv @srv "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /tmp @tmp "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /opt @opt "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /var/lib/containers @containers "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /var/lib/docker @docker "noatime,compress=zstd,space_cache=v2" 2
add_fstab_entry /var/www @www "noatime,compress=zstd,space_cache=v2" 2

# --- GRUB-Konfiguration im laufenden System anpassen ---
if [[ -f /etc/default/grub ]]; then
  if grep -q "@rootfs" /etc/default/grub; then
    echo ">>> Ersetze @rootfs durch @ in /etc/default/grub"
    sed -i 's/@rootfs/@/g' /etc/default/grub
  else
    echo ">>> In /etc/default/grub kein @rootfs gefunden – ok."
  fi

  if command -v update-grub >/dev/null 2>&1; then
    echo ">>> update-grub ausführen"
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    echo ">>> grub-mkconfig -o /boot/grub/grub.cfg ausführen"
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo ">>> Hinweis: Weder update-grub noch grub-mkconfig gefunden – bitte ggf. manuell GRUB-Konfiguration aktualisieren."
  fi
else
  echo "WARNUNG: /etc/default/grub nicht gefunden – GRUB nicht angepasst." >&2
fi

# --- Root nach @ kopieren (JETZT, damit neue fstab & grub darin landen) ---
echo ">>> Kopiere aktuelles Root-Dateisystem nach @ (überschreibend)"
rsync -axHAX --delete \
  --exclude="$MNT/*" \
  --exclude="/dev/*" \
  --exclude="/proc/*" \
  --exclude="/sys/*" \
  --exclude="/run/*" \
  --exclude="/tmp/*" \
  --exclude="/mnt/*" \
  --exclude="/media/*" \
  --exclude="/lost+found" \
  / "$MNT/@"

# --- Mountpoints im neuen Root (@) leeren, damit Subvolumes dort einhängen können ---
prepare_mp() {
  local mp="$1"             # z.B. /home
  local target="$MNT/@$mp"  # /mnt/btrfs-root/@/home
  mkdir -p "$target"
  rm -rf "$target"/* 2>/dev/null || true
}

echo ">>> Mountpoints im neuen Root (@) vorbereiten"
for mp in /root /home /var/spool /var/log /var/cache /var/tmp /srv /tmp /opt /var/lib/containers /var/lib/docker /var/www; do
  prepare_mp "$mp"
done

# --- Default-Subvolume auf @ setzen ---
echo ">>> Setze Default-Subvolume auf @"
set +e
SUBVOL_ID=$(btrfs subvolume list "$MNT" | awk '$NF=="@" {print $2}')
RET_LIST=$?
if [[ $RET_LIST -ne 0 ]]; then
  echo "WARNUNG: btrfs subvolume list hat einen Fehler geliefert (Code $RET_LIST). Default-Subvolume wird NICHT geändert."
else
  if [[ -n "$SUBVOL_ID" ]]; then
    if ! btrfs subvolume set-default "$SUBVOL_ID" "$MNT"; then
      echo "WARNUNG: btrfs subvolume set-default ist fehlgeschlagen – bitte manuell prüfen."
    fi
  else
    echo "WARNUNG: Konnte Subvolume-ID für @ nicht ermitteln – Default-Subvolume NICHT gesetzt."
  fi
fi
set -e

echo ">>> Erzeuge Mountpoints im laufenden System (falls noch nicht vorhanden)"
mkdir -p /root /home /srv /opt /tmp
mkdir -p /var/spool /var/log /var/cache /var/tmp
mkdir -p /var/lib/containers /var/lib/docker
mkdir -p /var/www

umount "$MNT"

echo
echo ">>> FERTIG."
echo "Kontrolliere kurz mit:  cat /etc/fstab"
echo "Wenn dort die neuen Btrfs-Zeilen stehen, dann:"
echo "  mount -a"
echo "Wenn keine Fehler kommen:"
echo "  reboot"
echo
echo "Nach dem Reboot sollte / von subvol=@ und /home, /var/log, /var/lib/docker usw. von den jeweiligen Subvolumes kommen."
echo "Die alte fstab liegt gesichert unter ${FSTAB}.backup-<Datum>."
