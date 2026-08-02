#!/usr/bin/env bash
set -euo pipefail

WATCH_ROOT=${TIMESHIFT_WATCH_ROOT:-/run/timeshift}
EVENT_DELAY=${TIMESHIFT_EVENT_DELAY:-3}
WATCH_TIMEOUT=${TIMESHIFT_WATCH_TIMEOUT:-60}
LOCK_FILE=${TIMESHIFT_GRUB_BTRFS_LOCK_FILE:-/run/lock/timeshift-grub-btrfs-sync.lock}
GRUB_BTRFS_UPDATE_COMMAND=${GRUB_BTRFS_UPDATE_COMMAND:-}
GRUB_BTRFS_CONFIG=${GRUB_BTRFS_CONFIG:-/etc/default/grub-btrfs/config}

if [[ $EUID -ne 0 ]]; then
  echo "timeshift-grub-btrfs-sync: bitte als root ausführen." >&2
  exit 1
fi

for command_name in find inotifywait flock sleep; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "timeshift-grub-btrfs-sync: benötigtes Kommando fehlt: $command_name" >&2
    exit 1
  fi
done

log() {
  local message="$1"
  printf 'timeshift-grub-btrfs-sync: %s\n' "$message" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t timeshift-grub-btrfs-sync "$message" || true
  fi
}

mkdir -p "$WATCH_ROOT"
mkdir -p "$(dirname "$LOCK_FILE")"

declare -a WATCH_PATHS=()

add_watch_path() {
  local candidate="$1"
  local existing

  [[ -d "$candidate" ]] || return 0
  for existing in "${WATCH_PATHS[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  WATCH_PATHS+=("$candidate")
}

discover_watch_paths() {
  local watch_parent snapshot_root snapshot_dir
  local -a watch_parents=()
  local -a snapshot_roots=()

  WATCH_PATHS=()
  add_watch_path "$WATCH_ROOT"

  shopt -s nullglob
  watch_parents=(
    "$WATCH_ROOT"/*
    "$WATCH_ROOT"/*/backup
    "$WATCH_ROOT"/*/backup/timeshift-btrfs
    "$WATCH_ROOT"/backup
    "$WATCH_ROOT"/backup/timeshift-btrfs
  )
  for watch_parent in "${watch_parents[@]}"; do
    add_watch_path "$watch_parent"
  done

  snapshot_roots=(
    "$WATCH_ROOT"/*/backup/timeshift-btrfs/snapshots
    "$WATCH_ROOT"/backup/timeshift-btrfs/snapshots
  )

  for snapshot_root in "${snapshot_roots[@]}"; do
    [[ -d "$snapshot_root" ]] || continue
    add_watch_path "$snapshot_root"
    while IFS= read -r -d '' snapshot_dir; do
      add_watch_path "$snapshot_dir"
    done < <(
      find "$snapshot_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true
    )
  done
  shopt -u nullglob
}

regenerate_grub() {
  local grub_dir=/boot/grub
  local grub_config="$grub_dir/grub.cfg"
  local lock_fd

  exec {lock_fd}>"$LOCK_FILE"
  if ! flock -w 60 "$lock_fd"; then
    log "konnte die GRUB-Sperre nicht erhalten, verschiebe Aktualisierung auf das nächste Ereignis"
    return 1
  fi

  if [[ -n "$GRUB_BTRFS_UPDATE_COMMAND" ]]; then
    "$GRUB_BTRFS_UPDATE_COMMAND"
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    if [[ -r "$GRUB_BTRFS_CONFIG" ]]; then
      # shellcheck disable=SC1090
      . "$GRUB_BTRFS_CONFIG"
      grub_dir=${GRUB_BTRFS_GRUB_DIRNAME:-$grub_dir}
      grub_config="$grub_dir/grub.cfg"
    fi
    grub-mkconfig -o "$grub_config"
  else
    log "weder update-grub noch grub-mkconfig ist verfügbar"
    return 1
  fi

  log "GRUB-Konfiguration aktualisiert"
}

event_requires_update() {
  local path="$1"
  local events="$2"

  [[ "$path" == */info.json ]] && return 0

  case "$path" in
    */timeshift-btrfs/snapshots|*/timeshift-btrfs/snapshots/*)
      case ",$events," in
        *,CREATE,*|*,DELETE,*|*,MOVED_TO,*|*,MOVED_FROM,*|*,UNMOUNT,*)
          return 0
          ;;
      esac
      ;;
  esac

  return 1
}

wait_for_relevant_event() {
  local event path events

  discover_watch_paths
  if [[ ${#WATCH_PATHS[@]} -eq 0 ]]; then
    sleep 2
    return 1
  fi

  event=$(inotifywait -q \
    -e create -e delete -e moved_to -e moved_from -e close_write -e attrib -e unmount \
    --format '%w%f|%e' \
    -t "$WATCH_TIMEOUT" \
    "${WATCH_PATHS[@]}" 2>/dev/null || true)

  [[ -n "$event" ]] || return 1
  path=${event%%|*}
  events=${event#*|}

  event_requires_update "$path" "$events"
}

trap 'exit 0' INT TERM

log "überwache $WATCH_ROOT auf Timeshift-Snapshot- und info.json-Änderungen"

while true; do
  if wait_for_relevant_event; then
    sleep "$EVENT_DELAY"
    if ! regenerate_grub; then
      log "GRUB-Aktualisierung fehlgeschlagen; der Watcher bleibt aktiv"
    fi
  fi
done
