#!/usr/bin/env bash
# Live, opt-in guard for the real installed Hermes Agent CLI: exercises the
# shared state.db busy fold (bin/fm-busy-lib.sh) and the shared composer
# classifier (bin/fm-composer-lib.sh) against a REAL hermes process rather
# than a fixture, so a future hermes release that changes its database schema
# or its idle composer shape is caught here instead of silently drifting.
# Opt-in and self-skipping because standard CI has neither the hermes binary
# nor its Nous Portal credentials; run this after every hermes upgrade.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_BIN=$(command -v hermes 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-hermes-signals-$$"
SESSION=hermes-signals
TARGET="$SESSION:hermes"
HERMES_VERSION=

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s (hermes %s)\n' "$1" "${HERMES_VERSION:-unknown version}" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${FM_HERMES_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERMES_SIGNALS_LIVE=1 to run the real Hermes Agent signal drift guard"
  exit 0
fi

[ -x "$HERMES_BIN" ] || fail "FM_HERMES_SIGNALS_LIVE=1 but no real hermes executable is installed on PATH"
[ -x "$REAL_TMUX" ] || fail "FM_HERMES_SIGNALS_LIVE=1 but tmux is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to query hermes's shared state.db"

HERMES_VERSION=$("$HERMES_BIN" --version 2>/dev/null | head -1)
[ -n "$HERMES_VERSION" ] || fail "could not determine the installed hermes version"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hermes-signals.XXXXXX") || fail "could not create the isolated hermes lab"
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated hermes workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated hermes workspace"

# Deliberately NOT an isolated HERMES_HOME: this guard exercises the same
# shared credential/state.db model fm-spawn.sh's own launch template relies
# on (see "hermes shared state.db busy source" in the harness-adapters
# skill), so it reads the operator's already-authenticated Nous Portal
# session the same way a real crewmate spawn would.
DB="${HERMES_HOME:-$HOME/.hermes}/state.db"
[ -f "$DB" ] || fail "no hermes state.db at $DB; run 'hermes status' once to confirm Nous Portal auth before using this guard"

cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n hermes -c "$WORKSPACE" -- \
  "$HERMES_BIN" chat --yolo --accept-hooks \
  || fail "could not launch hermes chat"

# Composer-empty is the readiness gate, deliberately NOT the "Welcome to
# Hermes Agent!" banner text: verified live (frame-by-frame captures) that
# the banner renders roughly 1.2s BEFORE the composer/status-bar frame does,
# and a pointer typed during that window is silently lost - it lands as
# stray scrollback text, Enter submits nothing, and no session row is ever
# written to state.db. This exact race reproduced the "no workspace-bound
# session row" failure this guard exists to catch.
READY=0
for _ in $(seq 1 150); do
  [ "$(fm_tmux_composer_state "$TARGET")" = empty ] && { READY=1; break; }
  sleep 0.2
done
[ "$READY" = 1 ] || fail "hermes's composer never reached the shared classifier's empty state"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  'Run the shell command: sleep 3 && echo fm-hermes-signals-live-e2e-ok. Then report the result.' \
  || fail "could not type the test turn into hermes"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the test turn to hermes"

SESSION_ID=
for _ in $(seq 1 150); do
  SESSION_ID=$(fm_busy_hermes_matching_sessions "$DB" "$WORKSPACE" 2>/dev/null | head -1)
  [ -z "$SESSION_ID" ] || break
  sleep 0.2
done
[ -n "$SESSION_ID" ] || fail "real hermes produced no workspace-bound session row in state.db"

TURN_STATE=
for _ in $(seq 1 150); do
  TURN_STATE=$(fm_busy_hermes_turn_state "$DB" "$SESSION_ID" 2>/dev/null || true)
  [ "$TURN_STATE" = busy ] && break
  sleep 0.2
done
[ "$TURN_STATE" = busy ] || fail "fm_busy_hermes_turn_state never observed the real turn in flight"
pass "hermes's real shared state.db classifies busy in flight"

for _ in $(seq 1 300); do
  TURN_STATE=$(fm_busy_hermes_turn_state "$DB" "$SESSION_ID" 2>/dev/null || true)
  [ "$TURN_STATE" = settled ] && break
  sleep 0.2
done
[ "$TURN_STATE" = settled ] || fail "fm_busy_hermes_turn_state did not settle the real completed turn"
pass "hermes's real shared state.db settles after the real turn completes"

COMPOSER_STATE=
for _ in $(seq 1 100); do
  COMPOSER_STATE=$(fm_tmux_composer_state "$TARGET")
  [ "$COMPOSER_STATE" = empty ] && break
  sleep 0.2
done
[ "$COMPOSER_STATE" = empty ] || fail "the shared classifier read hermes's real idle composer as '$COMPOSER_STATE'"
pass "hermes's real idle composer classifies empty through the shared classifier with no glyph override"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/exit' \
  || fail "could not type /exit into hermes"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit /exit to hermes"

cleanup
trap - EXIT
