#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$REPO_DIR/timeshift-launcher"
POLICY="$REPO_DIR/org.debian-btrfs.timeshift-grub-btrfs.policy"
TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/bin"
EVENT_LOG="$TEST_ROOT/events.log"
INFO_FILE="$TEST_ROOT/info.json"
MENU_FILE="$TEST_ROOT/grub-btrfs.cfg"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/timeshift-gtk" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'gui:start' >> "$TEST_EVENT_LOG"
printf '%s\n' '{"comments":"neuer Versuch mit , Komma"}' > "$TEST_INFO_FILE"
printf '%s\n' 'gui:end' >> "$TEST_EVENT_LOG"
exit "${TEST_GUI_STATUS:-0}"
EOF

cat > "$FAKE_BIN/grub-generator" <<'EOF'
#!/usr/bin/env bash
comment=$(sed -n 's/.*"comments":"\([^"]*\)".*/\1/p' "$TEST_INFO_FILE")
printf 'generator:%s\n' "$comment" >> "$TEST_EVENT_LOG"
printf "menuentry '%s'\n" "$comment" > "$TEST_MENU_FILE"
exit "${TEST_GENERATOR_STATUS:-0}"
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active)
    printf '%s\n' 'systemctl:is-active' >> "$TEST_EVENT_LOG"
    [[ ${TEST_DAEMON_ACTIVE:-1} == 1 ]]
    ;;
  stop)
    printf '%s\n' 'systemctl:stop' >> "$TEST_EVENT_LOG"
    ;;
  start)
    printf '%s\n' 'systemctl:start' >> "$TEST_EVENT_LOG"
    [[ ${TEST_DAEMON_START_FAIL:-0} == 0 ]]
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "$FAKE_BIN/grub-script-check" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'grub-script-check' >> "$TEST_EVENT_LOG"
[[ -s $1 ]]
EOF

chmod 0755 "$FAKE_BIN"/*

run_launcher() {
  local gui_status=${1:-0}
  local generator_status=${2:-0}
  local daemon_active=${3:-1}
  local daemon_start_fail=${4:-0}

  TIMESHIFT_LAUNCHER_TEST_MODE=1 \
  TIMESHIFT_LAUNCHER_TEST_GTK="$FAKE_BIN/timeshift-gtk" \
  TIMESHIFT_LAUNCHER_TEST_GENERATOR="$FAKE_BIN/grub-generator" \
  TIMESHIFT_LAUNCHER_TEST_MENU="$MENU_FILE" \
  TIMESHIFT_LAUNCHER_TEST_SYSTEMCTL="$FAKE_BIN/systemctl" \
  TIMESHIFT_LAUNCHER_TEST_SCRIPT_CHECK="$FAKE_BIN/grub-script-check" \
  TIMESHIFT_LAUNCHER_TEST_LOCK="$TEST_ROOT/launcher.lock" \
  TEST_EVENT_LOG="$EVENT_LOG" \
  TEST_INFO_FILE="$INFO_FILE" \
  TEST_MENU_FILE="$MENU_FILE" \
  TEST_GUI_STATUS="$gui_status" \
  TEST_GENERATOR_STATUS="$generator_status" \
  TEST_DAEMON_ACTIVE="$daemon_active" \
  TEST_DAEMON_START_FAIL="$daemon_start_fail" \
    "$LAUNCHER"
}

: > "$EVENT_LOG"
run_launcher
cat > "$TEST_ROOT/expected-success.log" <<'EOF'
gui:start
gui:end
systemctl:is-active
systemctl:stop
generator:neuer Versuch mit , Komma
grub-script-check
systemctl:start
EOF
cmp "$TEST_ROOT/expected-success.log" "$EVENT_LOG"
grep -Fq "neuer Versuch mit , Komma" "$MENU_FILE"

: > "$EVENT_LOG"
set +e
run_launcher 7
status=$?
set -e
[[ $status -eq 7 ]]
grep -Fq 'generator:neuer Versuch mit , Komma' "$EVENT_LOG"
grep -Fq 'systemctl:start' "$EVENT_LOG"

: > "$EVENT_LOG"
set +e
run_launcher 0 9
status=$?
set -e
[[ $status -ne 0 ]]
grep -Fq 'systemctl:start' "$EVENT_LOG"

: > "$EVENT_LOG"
run_launcher 0 0 0
grep -Fq 'systemctl:is-active' "$EVENT_LOG"
if grep -Eq '^systemctl:(stop|start)$' "$EVENT_LOG"; then
  echo "FEHLER: Inaktiver grub-btrfsd wurde verändert." >&2
  exit 1
fi

: > "$EVENT_LOG"
set +e
run_launcher 0 0 1 1
status=$?
set -e
[[ $status -ne 0 ]]
grep -Fq 'systemctl:start' "$EVENT_LOG"

grep -Fq '<annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/timeshift-launcher</annotate>' "$POLICY"
grep -Fq '<annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>' "$POLICY"
grep -Fq '# Managed by debian-btrfs/layout-script setup-timeshift.sh' "$LAUNCHER"
grep -Fq '<!-- Managed by debian-btrfs/layout-script setup-timeshift.sh -->' "$POLICY"

echo "OK: Timeshift-GUI-Nachlauf aktualisiert GRUB sicher und erhält Kommentare mit Komma."
