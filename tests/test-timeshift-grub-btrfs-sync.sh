#!/usr/bin/env bash
set -euo pipefail

if ! command -v inotifywait >/dev/null 2>&1; then
  echo "SKIP: inotifywait ist nicht installiert."
  exit 0
fi

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
WATCH_ROOT="$TEST_ROOT/timeshift"
SNAPSHOT_DIR="$WATCH_ROOT/123/backup/timeshift-btrfs/snapshots/2026-08-02_23-00-00"
UPDATE_LOG="$TEST_ROOT/update.log"
FAKE_UPDATE="$TEST_ROOT/fake-update-grub"
WATCH_LOG="$TEST_ROOT/watcher.log"
WATCH_PID=""

cleanup() {
  if [[ -n "$WATCH_PID" ]]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$SNAPSHOT_DIR"
printf '%s\n' '{"comment":"before"}' > "$SNAPSHOT_DIR/info.json"
cat > "$FAKE_UPDATE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "update" >> "$UPDATE_LOG"
EOF
chmod 0755 "$FAKE_UPDATE"

TIMESHIFT_WATCH_ROOT="$WATCH_ROOT" \
TIMESHIFT_EVENT_DELAY=1 \
TIMESHIFT_WATCH_TIMEOUT=2 \
TIMESHIFT_GRUB_BTRFS_LOCK_FILE="$TEST_ROOT/lock" \
GRUB_BTRFS_UPDATE_COMMAND="$FAKE_UPDATE" \
  "$REPO_DIR/timeshift-grub-btrfs-sync.sh" >"$WATCH_LOG" 2>&1 &
WATCH_PID=$!

sleep 1
printf '%s\n' '{"comment":"after GUI edit"}' > "$SNAPSHOT_DIR/info.json.tmp"
mv "$SNAPSHOT_DIR/info.json.tmp" "$SNAPSHOT_DIR/info.json"

for _ in {1..15}; do
  [[ -s "$UPDATE_LOG" ]] && break
  sleep 1
done

if [[ ! -s "$UPDATE_LOG" ]]; then
  echo "FEHLER: info.json-Änderung löste keine GRUB-Aktualisierung aus." >&2
  sed -n '1,120p' "$WATCH_LOG" >&2 || true
  exit 1
fi

echo "OK: info.json-Änderung löste eine GRUB-Aktualisierung aus."
