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

# --- Modus erkennen: erstmaliger Umstieg oder nachtraegliches Ergaenzen? ---
# Wenn / schon von einem benannten Subvolume laeuft, wurde dieses Skript (oder
# eine gleichwertige Migration) bereits erfolgreich durchgefuehrt. Root, GRUB
# und das Default-Subvolume bleiben dann unangetastet; es werden nur noch
# fehlende Subvolumes fuer noch nicht separat gemountete Pfade ergaenzt - ohne
# Neustart, da kein Root-Wechsel mehr noetig ist.
INCREMENTAL=0
if [[ "$ROOT_SRC" == *"["* ]]; then
  INCREMENTAL=1
  echo ">>> / läuft bereits von einem benannten Subvolume (${ROOT_SRC})."
  echo ">>> Inkrementeller Modus: nur fehlende Subvolumes werden ergänzt."
  echo ">>> Root, GRUB und Default-Subvolume bleiben unangetastet, kein Neustart nötig."
fi

# --- Ausdrückliche Bestätigung, bevor irgendetwas verändert wird ---
echo
echo "!!! ACHTUNG !!!"
if [[ $INCREMENTAL -eq 1 ]]; then
  echo "Dieses Skript legt zusätzliche Subvolumes für noch nicht separat"
  echo "gemountete Pfade an und kopiert deren aktuelle Daten hinein."
  echo "Root, /etc/default/grub und das Default-Subvolume werden NICHT verändert;"
  echo "ein Neustart ist nicht nötig."
else
  echo "Dieses Skript modifiziert /etc/fstab und /etc/default/grub und kopiert das"
  echo "komplette Root-Dateisystem in neue Subvolumes. Der eigentliche Root-Wechsel"
  echo "wird erst mit einem Neustart wirksam. Ein Fehlschlag kann das System"
  echo "unbootbar machen; ein Rollback ist dann nur manuell über eine Rescue-Konsole"
  echo "möglich (die alte fstab wird zwar gesichert, aber nicht automatisch"
  echo "zurückgespielt)."
fi
echo
if [[ -t 0 ]]; then
  read -r -p "Backup vorhanden? Zum Fortfahren exakt 'ja' eingeben: " CONFIRM
  if [[ "$CONFIRM" != "ja" ]]; then
    echo "Abgebrochen." >&2
    exit 1
  fi
else
  echo ">>> Kein interaktives Terminal erkannt – Bestätigung übersprungen (automatisierter Lauf)."
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

apt_package_available() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

offer_optional_btrfs_tools() {
  [[ -t 0 && -t 1 ]] || return 0

  local -a tools=(
    "timeshift:Einfache System-Restore-Snapshots"
    "snapper:Server/CLI-Snapshotverwaltung für Btrfs"
    "btrbk:Btrfs-Backups und Replikation per SSH"
    "btrfsmaintenance:Scrub, Balance, Trim und Defrag planen"
    "duperemove:Deduplizierung gleicher Btrfs-Extents"
    "grub-btrfs:Btrfs-Snapshots im GRUB-Bootmenü bootbar machen"
  )
  local -a checklist_args=()
  local -a selected_tools=()
  local entry pkg desc selected

  for entry in "${tools[@]}"; do
    pkg="${entry%%:*}"
    desc="${entry#*:}"
    if apt_package_available "$pkg"; then
      checklist_args+=("$pkg" "$desc" "OFF")
    else
      echo ">>> Optionales APT-Paket $pkg ist nicht verfügbar, überspringe."
    fi
  done

  [[ ${#checklist_args[@]} -gt 0 ]] || return 0

  need_pkg whiptail whiptail
  if ! selected=$(whiptail --title "Optionale Btrfs-/Snapshot-Tools" \
    --checklist "Diese Auswahl installiert nur normale APT-Pakete, keine Snap- oder Flatpak-Pakete. Alle Tools bleiben unkonfiguriert; Timeshift, Snapper, btrbk und Wartungsjobs müssen danach manuell eingerichtet werden.\nLeertaste = an-/abwählen, Enter = bestätigen." \
    22 92 10 \
    "${checklist_args[@]}" \
    3>&1 1>&2 2>&3); then
    echo ">>> Optionale Tool-Installation übersprungen."
    return 0
  fi

  eval "selected_tools=($selected)"
  [[ ${#selected_tools[@]} -gt 0 ]] || { echo ">>> Keine optionalen Tools ausgewählt."; return 0; }

  echo ">>> Installiere optionale APT-Pakete: ${selected_tools[*]}"
  if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${selected_tools[@]}"; then
    echo ">>> Optionale Tools installiert. Bitte Timeshift/Snapper/btrbk/btrfsmaintenance bei Bedarf manuell konfigurieren."
    echo ">>> Hinweis grub-btrfs: für die vollständige Timeshift-Integration danach setup-timeshift.sh ausführen; für Snapper setup-snapper.sh verwenden."
  else
    echo "WARNUNG: Optionale Tool-Installation ist fehlgeschlagen. Das Btrfs-Setup wird fortgesetzt." >&2
  fi
}

# --- Mapping Quelle -> Subvolume (für Daten); einzige Quelle der Wahrheit für
# Subvolume-Namen, Rsync-Ausschlüsse, Mountpoint-Vorbereitung, -Erzeugung und
# fstab-Einträge (siehe SUBVOL_OPTS weiter unten) ---
declare -a ALL_MAPS=(
# Allgemeine Systempfade: sinnvoll auf so gut wie jedem Server, unabhaengig
# vom installierten Software-Stack. Stehen deshalb im Auswahldialog oben.
"/root:@root"
"/home:@home"
"/var/spool:@spool"
"/var/log:@log"
"/var/cache:@cache"
"/var/tmp:@tmp_var"
"/srv:@srv"
"/tmp:@tmp"
"/opt:@opt"
"/var/www:@www"
# Container-Engines und ihre benannten Volumes. Volume-Subvolumes stehen
# direkt hinter ihrem Eltern-Subvolume (Zugehoerigkeit im Dialog erkennbar)
# und sind getrennt von @docker/@containers, damit Volume-Daten gezielt von
# Kompression ausgenommen werden koennen, waehrend Image-Layer/Metadaten
# weiterhin von compress=zstd profitieren.
"/var/lib/containers:@containers"
"/var/lib/containers/storage/volumes:@containers-volumes"
"/var/lib/docker:@docker"
"/var/lib/docker/volumes:@docker-volumes"
# Datenbank-/Datastore-Pfade: stark vom konkreten Software-Stack abhaengig,
# deshalb im Auswahldialog ganz unten.
"/var/lib/mongodb:@mongodb"
"/var/lib/mysql:@mysql"
"/var/lib/postgresql:@postgresql"
"/var/lib/chroma:@chroma"
"/var/lib/clamav:@clamav"
"/var/lib/stalwart:@stalwart"
"/var/lib/elasticsearch:@elasticsearch"
"/var/lib/opensearch:@opensearch"
"/var/lib/clickhouse:@clickhouse"
"/var/lib/cassandra:@cassandra"
"/var/lib/couchdb:@couchdb"
"/var/lib/neo4j:@neo4j"
"/var/lib/rabbitmq:@rabbitmq"
)

# fstab-Mount-Optionen je Subvolume. Btrfs-Mountoptionen wie compress,
# nodatacow und autodefrag sind nicht verlaesslich pro Subvolume steuerbar;
# Datenbank-/Volume-Subvolumes bekommen deshalb unten per Inode-Property
# "compression no" statt eigener fstab-Kompressionsoptionen.
declare -A SUBVOL_OPTS=(
  [@root]="noatime,compress=zstd,space_cache=v2"
  [@home]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@spool]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@log]="noatime,compress=zstd,space_cache=v2,autodefrag"
  [@cache]="noatime,compress=zstd,space_cache=v2"
  [@tmp_var]="noatime,compress=zstd,space_cache=v2"
  [@srv]="noatime,compress=zstd,space_cache=v2"
  [@tmp]="noatime,compress=zstd,space_cache=v2"
  [@opt]="noatime,compress=zstd,space_cache=v2"
  [@containers]="noatime,compress=zstd,space_cache=v2"
  [@docker]="noatime,compress=zstd,space_cache=v2"
  [@www]="noatime,compress=zstd,space_cache=v2"
  [@mongodb]="noatime,compress=zstd,space_cache=v2"
  [@mysql]="noatime,compress=zstd,space_cache=v2"
  [@postgresql]="noatime,compress=zstd,space_cache=v2"
  [@chroma]="noatime,compress=zstd,space_cache=v2"
  [@clamav]="noatime,compress=zstd,space_cache=v2"
  [@stalwart]="noatime,compress=zstd,space_cache=v2"
  [@elasticsearch]="noatime,compress=zstd,space_cache=v2"
  [@opensearch]="noatime,compress=zstd,space_cache=v2"
  [@clickhouse]="noatime,compress=zstd,space_cache=v2"
  [@cassandra]="noatime,compress=zstd,space_cache=v2"
  [@couchdb]="noatime,compress=zstd,space_cache=v2"
  [@neo4j]="noatime,compress=zstd,space_cache=v2"
  [@rabbitmq]="noatime,compress=zstd,space_cache=v2"
  [@docker-volumes]="noatime,compress=zstd,space_cache=v2"
  [@containers-volumes]="noatime,compress=zstd,space_cache=v2"
)

# Diese Subvolumes behalten CoW und Checksums, werden aber per
# btrfs-property von der Kompression ausgenommen. Die Property muss vor dem
# Kopieren der Daten gesetzt werden, damit neue Dateien darunter sie erben.
declare -A NO_COMPRESSION_SUBVOLS=(
  [@mongodb]=1
  [@mysql]=1
  [@postgresql]=1
  [@chroma]=1
  [@clamav]=1
  [@stalwart]=1
  [@elasticsearch]=1
  [@opensearch]=1
  [@clickhouse]=1
  [@cassandra]=1
  [@couchdb]=1
  [@neo4j]=1
  [@rabbitmq]=1
  [@docker-volumes]=1
  [@containers-volumes]=1
)

# Volume-Subvolumes liegen INNERHALB ihres Eltern-Subvolumes und brauchen es
# als eigenes Subvolume (sonst legt prepare_mp verwaiste Verzeichnisse unter
# einem nie erzeugten Eltern-Subvolume an).
declare -A VOLUME_PARENT=(
  [@docker-volumes]=@docker
  [@containers-volumes]=@containers
)

# --- Bereits erledigte bzw. anderweitig belegte Zielpfade aussortieren ---
# Drei Kategorien statt eines Alles-oder-nichts-Abbruchs:
#   - schon korrekt eingerichtet (genau das erwartete Subvolume gemountet)
#     -> wird uebersprungen, taucht im Auswahldialog gar nicht erst auf.
#   - anderweitig belegt (gemountet, aber nicht vom erwarteten Subvolume)
#     -> wird uebersprungen und gewarnt, statt blind drueberzuschreiben.
#   - noch offen (kein eigener Mount) -> Kandidat fuer die Auswahl.
declare -a MAPS=()
declare -a ALREADY_DONE=()
declare -a CONFLICTS=()
for entry in "${ALL_MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  this_src=$(findmnt -no SOURCE "$src" 2>/dev/null || true)
  if [[ -z "$this_src" ]]; then
    MAPS+=("$entry")
  elif [[ "$this_src" == *"[/${sub}]"* ]]; then
    ALREADY_DONE+=("$entry")
  else
    CONFLICTS+=("$entry ($this_src)")
  fi
done

if [[ ${#ALREADY_DONE[@]} -gt 0 ]]; then
  echo ">>> Bereits eingerichtet (übersprungen):"
  for entry in "${ALREADY_DONE[@]}"; do
    echo "    ${entry%%:*} -> ${entry##*:}"
  done
fi
if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
  echo ">>> WARNUNG: anderweitig belegt, wird übersprungen (bitte manuell prüfen):" >&2
  for c in "${CONFLICTS[@]}"; do
    echo "    $c" >&2
  done
fi
if [[ ${#MAPS[@]} -eq 0 ]]; then
  echo ">>> Nichts zu tun - alle Subvolumes sind bereits eingerichtet oder anderweitig belegt."
  umount "$MNT"
  exit 0
fi

# --- Interaktive Auswahl: welche der noch offenen Subvolumes anlegen? ---
# Universell sinnvolle Subvolumes sind vorausgewählt (klein/leer auf so gut
# wie jedem Debian-Server, so gut wie nie schaedlich). Alles, was von der
# konkreten Serverrolle oder dem installierten Software-Stack abhaengt
# (Mail-Spool, Webserver-Docroot, Container-Engines, Datenbanken), startet
# abgewaehlt, bleibt aber frei anwaehlbar. Abgewaehlte Pfade bekommen kein
# eigenes Subvolume und bleiben einfach Teil von @ (Root) - das Skript
# braucht dafuer keine Sonderbehandlung, da alles Weitere aus MAPS
# abgeleitet wird.
declare -A DEFAULT_ON=(
  [@root]=1
  [@home]=1
  [@log]=1
  [@cache]=1
  [@tmp_var]=1
  [@tmp]=1
)

checklist_desc_for() {
  local src="$1" sub="$2" category compression
  if [[ -n "${DEFAULT_ON[$sub]:-}" ]]; then
    category="default"
  else
    category="optional"
  fi
  if [[ -n "${NO_COMPRESSION_SUBVOLS[$sub]:-}" ]]; then
    compression="no-compress"
  else
    compression="compress"
  fi
  echo "${category}, ${compression}: $src"
}

echo ">>> Noch offene Subvolumes:"
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  echo "    $sub ($(checklist_desc_for "$src" "$sub"))"
done

if [[ -t 0 && -t 1 ]]; then
  need_pkg whiptail whiptail
  CHECKLIST_ARGS=()
  for entry in "${MAPS[@]}"; do
    src="${entry%%:*}"
    sub="${entry##*:}"
    state="OFF"
    [[ -n "${DEFAULT_ON[$sub]:-}" ]] && state="ON"
    CHECKLIST_ARGS+=("$sub" "$(checklist_desc_for "$src" "$sub")" "$state")
  done
  SELECTED=$(whiptail --title "Btrfs-Subvolumes auswählen" \
    --checklist "Universell sinnvolle Subvolumes sind vorausgewählt. Einträge mit 'no-compress' behalten CoW/Prüfsummen, bekommen aber per Btrfs-Property compression=no vor der Datenkopie. Volume-Subvolumes (*-volumes) aktivieren automatisch ihr Eltern-Subvolume. Leertaste = ab-/anwählen, Enter = bestätigen.\nAbgewählte Pfade bleiben einfach Teil von @ (Root)." \
    24 78 14 \
    "${CHECKLIST_ARGS[@]}" \
    3>&1 1>&2 2>&3) || { echo "Abgebrochen." >&2; umount "$MNT"; exit 1; }
  eval "SELECTED_ARR=($SELECTED)"

  # Volume-Subvolumes brauchen ihr Eltern-Subvolume (siehe VOLUME_PARENT
  # oben); wird nur das Volume gewaehlt, muss das Elternteil automatisch
  # ergaenzt werden - sonst legt prepare_mp spaeter verwaiste Verzeichnisse
  # unter einem nie erzeugten Eltern-Subvolume an.
  for sel in "${SELECTED_ARR[@]}"; do
    parent="${VOLUME_PARENT[$sel]:-}"
    [[ -n "$parent" ]] || continue

    already=0
    for s in "${SELECTED_ARR[@]}"; do
      [[ "$s" == "$parent" ]] && { already=1; break; }
    done
    [[ $already -eq 1 ]] && continue

    candidate=0
    for entry in "${MAPS[@]}"; do
      [[ "${entry##*:}" == "$parent" ]] && { candidate=1; break; }
    done
    if [[ $candidate -eq 1 ]]; then
      echo ">>> $sel gewählt -> $parent automatisch mitausgewählt (Volume liegt darin)."
      SELECTED_ARR+=("$parent")
    fi
  done

  FILTERED_MAPS=()
  for entry in "${MAPS[@]}"; do
    sub="${entry##*:}"
    for sel in "${SELECTED_ARR[@]}"; do
      if [[ "$sub" == "$sel" ]]; then
        FILTERED_MAPS+=("$entry")
        break
      fi
    done
  done
  MAPS=("${FILTERED_MAPS[@]}")
  echo ">>> Ausgewählt: ${#MAPS[@]} Subvolumes."
else
  echo ">>> Kein interaktives Terminal erkannt - nur die universell sinnvollen Subvolumes werden angelegt (kein Auswahldialog)."
  FILTERED_MAPS=()
  for entry in "${MAPS[@]}"; do
    sub="${entry##*:}"
    [[ -n "${DEFAULT_ON[$sub]:-}" ]] && FILTERED_MAPS+=("$entry")
  done
  MAPS=("${FILTERED_MAPS[@]}")
  echo ">>> Ausgewählt: ${#MAPS[@]} Subvolumes."
fi

if [[ ${#MAPS[@]} -eq 0 ]]; then
  echo ">>> Nichts ausgewählt - nichts zu tun."
  umount "$MNT"
  exit 0
fi

# --- Speicherplatz-Check ---
# Initial-Modus: jedes Byte auf / wird einmal dupliziert (landet in @ oder
# einem eigenen Subvolume), der Gesamtbedarf entspricht also ungefaehr der
# aktuell belegten Menge auf /. Inkrementeller Modus: es wird nur das kopiert,
# was tatsaechlich ausgewaehlt wurde, also die Summe genau dieser Verzeichnisse.
echo ">>> Prüfe verfügbaren Speicherplatz"
if [[ $INCREMENTAL -eq 1 ]]; then
  NEEDED_BYTES=0
  for entry in "${MAPS[@]}"; do
    src="${entry%%:*}"
    if [[ -d "$src" ]]; then
      size=$(du -sb --one-file-system "$src" 2>/dev/null | awk '{print $1}')
      NEEDED_BYTES=$(( NEEDED_BYTES + ${size:-0} ))
    fi
  done
else
  NEEDED_BYTES=$(df --output=used -B1 / | tail -1 | tr -d '[:space:]')
fi
AVAIL_BYTES=$(df --output=avail -B1 / | tail -1 | tr -d '[:space:]')
REQUIRED_WITH_MARGIN=$(( NEEDED_BYTES * 110 / 100 ))
if (( AVAIL_BYTES < REQUIRED_WITH_MARGIN )); then
  echo "FEHLER: Nicht genug freier Speicherplatz." >&2
  echo "Benötigt (mit 10% Marge): ca. $(( REQUIRED_WITH_MARGIN / 1024 / 1024 )) MiB, verfügbar: $(( AVAIL_BYTES / 1024 / 1024 )) MiB." >&2
  echo "Grund: Die betroffenen Daten existieren kurzzeitig doppelt (alter Ort + neues Subvolume)." >&2
  umount "$MNT"
  exit 1
fi
echo ">>> Speicherplatz-Check bestanden (${AVAIL_BYTES} Bytes frei, ca. ${REQUIRED_WITH_MARGIN} Bytes benötigt)."

# --- alle ausgewählten Subvolumes anlegen (Root @ existiert im inkrementellen
# Modus schon; create_subvol ist idempotent, daher hier kein Unterschied) ---
create_subvol "@"
for entry in "${MAPS[@]}"; do
  create_subvol "${entry##*:}"
done

set_no_compression_policy() {
  local subvol="$1" target prop
  [[ -n "${NO_COMPRESSION_SUBVOLS[$subvol]:-}" ]] || return 0

  target="$MNT/$subvol"
  echo ">>> Deaktiviere Btrfs-Kompression für neue Daten in $subvol"
  btrfs property set "$target" compression no
  prop=$(btrfs property get "$target" compression)
  if [[ "$prop" != "compression=no" && "$prop" != "compression=none" ]]; then
    echo "FEHLER: Konnte Kompression für $subvol nicht deaktivieren (Ist: ${prop:-<leer>})." >&2
    echo "Abbruch, damit Daten nicht versehentlich mit falscher Kompressions-Policy kopiert werden." >&2
    umount "$MNT"
    exit 1
  fi
}

for entry in "${MAPS[@]}"; do
  set_no_compression_policy "${entry##*:}"
done

sync_dir() {
  local src="$1"    # z.B. /home
  local subvol="$2" # z.B. @home
  shift 2
  local extra_excludes=("$@") # z.B. --exclude=/volumes/* fuer verschachtelte Subvolumes

  if [[ ! -d "$src" ]]; then
    echo "Quelle $src existiert nicht, überspringe."
    return
  fi

  echo ">>> Übertrage $src nach $subvol (überschreibend)"
  rsync -axHAX --delete "${extra_excludes[@]}" "$src"/ "$MNT/$subvol"/
}

# --- Bekannte Dienste vor der Kopie stoppen (konsistente Daten statt
# halbgeschriebener Dateien bei aktiv laufenden Datenbanken/Containern) ---
declare -A SRC_SERVICE=(
  ["/var/lib/mongodb"]="mongod"
  ["/var/lib/mysql"]="mariadb mysql"
  ["/var/lib/postgresql"]="postgresql"
  ["/var/lib/chroma"]="chroma chromadb"
  ["/var/lib/clamav"]="clamav-freshclam clamav-freshclam-once.timer clamav-daemon"
  ["/var/lib/stalwart"]="stalwart-mail stalwart stalwart-server"
  ["/var/lib/elasticsearch"]="elasticsearch"
  ["/var/lib/opensearch"]="opensearch"
  ["/var/lib/clickhouse"]="clickhouse-server clickhouse"
  ["/var/lib/cassandra"]="cassandra"
  ["/var/lib/couchdb"]="couchdb"
  ["/var/lib/neo4j"]="neo4j"
  ["/var/lib/rabbitmq"]="rabbitmq-server rabbitmq"
  ["/var/lib/docker"]="docker"
  ["/var/lib/docker/volumes"]="docker"
  ["/var/lib/containers"]="podman podman.socket podman-restart crio containerd"
  ["/var/lib/containers/storage/volumes"]="podman podman.socket podman-restart crio containerd"
)
declare -a STOPPED_SERVICES=()
declare -A ALREADY_HANDLED=()

restart_stopped_services() {
  local svc
  for svc in "${STOPPED_SERVICES[@]}"; do
    echo ">>> Starte $svc wieder"
    systemctl start "$svc" || echo "WARNUNG: $svc konnte nicht neu gestartet werden – bitte manuell prüfen." >&2
  done
  STOPPED_SERVICES=()
}

for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  for svc in ${SRC_SERVICE[$src]:-}; do
    if [[ -z "${ALREADY_HANDLED[$svc]:-}" ]]; then
      ALREADY_HANDLED[$svc]=1
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo ">>> Stoppe $svc für eine konsistente Kopie"
        systemctl stop "$svc"
        STOPPED_SERVICES+=("$svc")
      fi
    fi
  done
done

echo ">>> Übertrage /root, /home, /var/... in ihre Subvolumes"
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  # /var/lib/docker/volumes und /var/lib/containers/storage/volumes bekommen
  # weiter unten ihr eigenes Subvolume - hier von der jeweiligen Elternkopie
  # ausschliessen, sonst landen sie doppelt (einmal hier, einmal separat).
  case "$src" in
    /var/lib/docker) sync_dir "$src" "$sub" --exclude=/volumes/* ;;
    /var/lib/containers) sync_dir "$src" "$sub" --exclude=/storage/volumes/* ;;
    *) sync_dir "$src" "$sub" ;;
  esac
done

# --- fstab im laufenden System anpassen ---
FSTAB="/etc/fstab"
backup="${FSTAB}.backup-$(date +%F-%H%M%S)"
echo ">>> Sicherung der aktuellen fstab nach $backup"
cp "$FSTAB" "$backup"

add_fstab_entry() {
  local mp="$1" sub="$2" opts="$3" pass="$4"
  if grep -Eq "^[^#[:space:]]+[[:space:]]+${mp}[[:space:]]+btrfs" "$FSTAB"; then
    echo ">>> fstab: Eintrag für ${mp} existiert bereits, überspringe."
  else
    echo "UUID=${UUID} ${mp} btrfs ${opts},subvol=${sub} 0 ${pass}" >> "$FSTAB"
    echo ">>> fstab: Eintrag für ${mp} hinzugefügt."
  fi
}

if [[ $INCREMENTAL -eq 0 ]]; then
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

  # Root mit subvol=@
  add_fstab_entry / @ "noatime,compress=zstd,space_cache=v2" 1
fi

# weitere Mounts (pass=2), Optionen aus SUBVOL_OPTS
for entry in "${MAPS[@]}"; do
  src="${entry%%:*}"
  sub="${entry##*:}"
  add_fstab_entry "$src" "$sub" "${SUBVOL_OPTS[$sub]}" 2
done

if [[ $INCREMENTAL -eq 0 ]]; then
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

  # Im initialen Modus muessen optionale APT-Pakete vor der Root-Kopie
  # installiert werden, damit Paketdateien und dpkg-Status in @ landen.
  offer_optional_btrfs_tools

  # --- Root nach @ kopieren (JETZT, damit neue fstab & grub darin landen) ---
  # Verzeichnisse, die wirklich ihr eigenes Subvolume bekommen, hier
  # ausschliessen: sie wurden oben bereits per sync_dir befuellt und wuerden
  # sonst redundant kopiert und per prepare_mp sofort wieder geloescht.
  # Abgewaehlte Kandidaten bleiben dagegen Teil von @ und duerfen nicht aus
  # dem Root-Rsync ausgeschlossen werden.
  echo ">>> Kopiere aktuelles Root-Dateisystem nach @ (überschreibend)"
  RSYNC_ROOT_EXCLUDES=(
    --exclude="$MNT/*"
    --exclude="/dev/*"
    --exclude="/proc/*"
    --exclude="/sys/*"
    --exclude="/run/*"
    --exclude="/mnt/*"
    --exclude="/media/*"
    --exclude="/lost+found"
  )
  for entry in "${MAPS[@]}"; do
    RSYNC_ROOT_EXCLUDES+=(--exclude="${entry%%:*}/*")
  done
  rsync -axHAX --delete "${RSYNC_ROOT_EXCLUDES[@]}" / "$MNT/@"
fi

# --- Mountpoints im neuen Root (@) leeren, damit Subvolumes dort einhängen können ---
# Verschachtelte Faelle (z.B. @containers-volumes wird unter
# /var/lib/containers/storage/volumes eingehaengt, also INNERHALB von
# @containers) brauchen den Platzhalter im Eltern-Subvolume, nicht in @ -
# sonst fehlt das Mount-Zielverzeichnis nach dem Einhaengen des Elternteils.
# Nutzt ALL_MAPS (nicht nur die ausgewaehlten), damit die Elternauflösung auch
# im inkrementellen Modus korrekt auf bereits vorhandene Subvolumes verweist.
parent_info_for() {
  # Gibt "SUBVOL:RELATIVER_PFAD" zurueck, z.B. "@containers:/storage/volumes"
  # oder "@:/var/lib/containers", wenn kein Elternteil in ALL_MAPS gefunden wird.
  local target="$1"
  local best_prefix="" best_subvol="@"
  local entry src sub
  for entry in "${ALL_MAPS[@]}"; do
    src="${entry%%:*}"
    sub="${entry##*:}"
    if [[ "$src" != "$target" && "$target" == "$src"/* && ${#src} -gt ${#best_prefix} ]]; then
      best_prefix="$src"
      best_subvol="$sub"
    fi
  done
  echo "${best_subvol}:${target#"$best_prefix"}"
}

prepare_mp() {
  local mp="$1" # z.B. /home oder /var/lib/containers/storage/volumes
  local info parent_subvol rel target
  info=$(parent_info_for "$mp")
  parent_subvol="${info%%:*}"
  rel="${info#*:}"
  target="$MNT/$parent_subvol$rel" # z.B. /mnt/btrfs-root/@containers/storage/volumes
  mkdir -p "$target"
  rm -rf "$target"/* 2>/dev/null || true
}

echo ">>> Mountpoints im neuen Root (@) vorbereiten"
for entry in "${MAPS[@]}"; do
  prepare_mp "${entry%%:*}"
done

# --- Default-Subvolume auf @ setzen (im inkrementellen Modus ohnehin schon
# korrekt gesetzt; set-default ist idempotent, daher hier kein Unterschied) ---
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
for entry in "${MAPS[@]}"; do
  mkdir -p "${entry%%:*}"
done

umount "$MNT"

# --- fstab validieren, ohne live umzumounten (kein Eingriff in laufende Dienste) ---
echo ">>> Validiere neue fstab mit 'findmnt --verify'"
if ! findmnt --verify; then
  echo "FEHLER: 'findmnt --verify' hat Probleme in der neuen fstab gefunden." >&2
  echo "Bitte ${FSTAB} pruefen, bevor du 'mount -a' ausfuehrst oder neu startest." >&2
  echo "Die alte fstab liegt gesichert unter ${backup}." >&2
  restart_stopped_services
  exit 1
fi
echo ">>> fstab-Validierung bestanden."

echo
if [[ $INCREMENTAL -eq 1 ]]; then
  echo ">>> Aktiviere die neuen Mounts sofort (kein Neustart nötig im inkrementellen Modus)"
  if ! systemctl daemon-reload; then
    echo "FEHLER: 'systemctl daemon-reload' ist fehlgeschlagen. Dienste werden wieder gestartet, soweit möglich." >&2
    restart_stopped_services
    exit 1
  fi
  if ! mount -a; then
    echo "FEHLER: 'mount -a' ist fehlgeschlagen. Dienste werden wieder gestartet, soweit möglich." >&2
    restart_stopped_services
    exit 1
  fi
  restart_stopped_services
  offer_optional_btrfs_tools
  echo ">>> FERTIG. Neue Subvolumes sind aktiv:"
  for entry in "${MAPS[@]}"; do
    findmnt -no TARGET,SOURCE,OPTIONS "${entry%%:*}" || true
  done
else
  echo ">>> FERTIG."
  echo "Kontrolliere kurz mit:  cat /etc/fstab"
  echo "Wenn dort die neuen Btrfs-Zeilen stehen, dann:"
  echo "  mount -a"
  echo "Wenn keine Fehler kommen:"
  echo "  reboot"
  echo
  if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
    echo "Folgende Dienste wurden für eine konsistente Kopie gestoppt und bleiben bis zum Reboot aus:"
    printf '  %s\n' "${STOPPED_SERVICES[@]}"
    echo
  fi
  echo "Nach dem Reboot sollte / von subvol=@ und /home, /var/log, /var/lib/docker usw. von den jeweiligen Subvolumes kommen."
  echo "Die alte fstab liegt gesichert unter ${FSTAB}.backup-<Datum>."
fi
