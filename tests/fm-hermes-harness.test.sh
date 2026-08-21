#!/usr/bin/env bash
# Behavior tests for the hermes (Hermes Agent) crewmate/scout adapter: harness
# detection via its kernel comm self-rename, spawn launch shape and
# model/effort mapping, the secondmate refusal, and the shared state.db busy
# fold (session resolution and turn-state classification).
#
# Hermes runs as `<venv>/bin/python <install>/hermes ...` and renames its own
# kernel process name to the literal value "hermes" via prctl PR_SET_NAME
# (verified live, Hermes Agent 0.20.0), while argv[0] and the exe path stay
# python. The detection case below reproduces that exact divergence with a
# real renamed process rather than a symlink, because a symlinked name can
# never model a POST-EXEC self-rename. The busy-fold fixtures reproduce
# hermes's real "messages" table shape, including the interrupt-path finding
# that a Ctrl+C-closed turn's finish_reason is NULL rather than "stop" - the
# whole reason the fold keys on "not tool_calls" rather than on "stop"
# specifically, so a fixture without that case would let a naive
# finish_reason="stop" implementation pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# --- detection ---------------------------------------------------------------

# Reproduces hermes's real process shape: invoked via a python argv0/path,
# self-renames its kernel comm to "hermes" via prctl, then blocks. Detection
# must follow the renamed comm, not the python argv0/path, or every hermes
# ancestor lookup would silently report "unknown".
test_detects_process_via_comm_rename() {
  local dir script out status
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  script="$dir/hermes_rename.py"
  cat > "$script" <<'PY'
import ctypes
import subprocess
import sys

PR_SET_NAME = 15
libc = ctypes.CDLL(None, use_errno=True)
libc.prctl(PR_SET_NAME, b"hermes", 0, 0, 0)
sys.exit(subprocess.call(sys.argv[1:]))
PY
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    python3 "$script" "$HARNESS")
  status=$?
  expect_code 0 "$status" "fm-harness.sh under a hermes-renamed comm should succeed"
  [ "$out" = hermes ] \
    || fail "fm-harness.sh under a hermes-renamed comm reported '$out', expected hermes"
  pass "hermes is detected through its kernel comm self-rename, not its python argv0"
}

test_unrenamed_python_is_not_misdetected_as_hermes() {
  local dir script out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  script="$dir/plain.py"
  cat > "$script" <<'PY'
import subprocess
import sys
sys.exit(subprocess.call(sys.argv[1:]))
PY
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    python3 "$script" "$HARNESS")
  [ "$out" != hermes ] \
    || fail "an ordinary python process with no comm rename was misdetected as hermes"
  pass "an ordinary python process is not misdetected as hermes without the comm rename"
}

# --- spawn scaffolding --------------------------------------------------------

# hermes chat rejects a positional prompt, so like Kimi it launches bare and
# receives the brief pointer through a separate typed-and-submitted send
# after a readiness poll. The fake tmux below is a small state machine
# reproducing that same launch -> ready -> pointer-typed -> delivered
# sequence Kimi's own fixture already uses, distinguishing the launch line
# from the pointer text by its distinctive `--accept-hooks` suffix. Delivery
# confirmation takes the busy-hint-row path (hermes_delivery_is_confirmed
# checks it FIRST, unconditionally): the "delivered" screen includes the
# literal busy token so no composer/cursor simulation is needed for it.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "$FM_FAKE_HERMES_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Hermes Agent!\n ⚕ model | ctx -- |\n────────\n❯\n────────\n'
      ;;
    pointer-typed)
      printf ' ⚕ model | ctx -- |\n────────\n❯ Read the brief\n────────\n'
      ;;
    delivered)
      printf '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '3\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *--accept-hooks*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_HERMES_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_HERMES_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched) printf 'ready\n' > "$FM_FAKE_HERMES_STATE" ;;
          pointer-typed) printf 'delivered\n' > "$FM_FAKE_HERMES_STATE" ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh hermes
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="hermes-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/pointer.log"
  : > "$case_dir/hermes.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_hermes_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 case_dir
  shift 5
  case_dir=$(dirname "$home")
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_HERMES_STATE="$case_dir/hermes.state" \
    FM_HERMES_READY_POLLS=5 FM_HERMES_DELIVERY_POLLS=5 FM_HERMES_POLL_INTERVAL=0 \
    HERMES_HOME="$home/hermeshome" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" hermes "$@" 2>&1
}

# --- spawn ---------------------------------------------------------------------

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "hermes spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report success"

  launch=$(cat "$home/launch.log")
  assert_contains "$launch" 'hermes chat --yolo --accept-hooks' \
    "hermes launch did not use the bare chat --yolo --accept-hooks shape"
  # hermes chat rejects a positional prompt, so unlike claude/grok/muse the
  # brief must never ride the launch command itself.
  assert_not_contains "$launch" 'encode launch-brief' \
    "hermes launch delivered the brief positionally, which hermes chat rejects"
  assert_grep 'harness=hermes' "$home/state/$id.meta" "hermes harness was not recorded in meta"
  assert_grep 'Read the brief at' "$case_dir/pointer.log" \
    "hermes spawn never typed the post-launch brief pointer"
  pass "hermes spawn launches bare with --yolo --accept-hooks, then delivers the brief as a pointer"
}

test_spawn_maps_effort_and_model() {
  local rec case_dir home proj wt fakebin id launch
  local -a cases=(low medium high xhigh max)
  local effort
  for effort in "${cases[@]}"; do
    rec=$(make_spawn_case "effort-$effort")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --model 'stepfun/step-3.7-flash:free' --effort "$effort" >/dev/null \
      || fail "hermes spawn with effort $effort failed"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "--reasoning '$effort'" "hermes effort $effort did not map straight across"
    assert_contains "$launch" "--model 'stepfun/step-3.7-flash:free'" "hermes spawn dropped the model axis"
  done
  # No effort chosen -> no invented flag.
  rec=$(make_spawn_case effort-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "hermes spawn without an effort axis failed"
  launch=$(cat "$home/launch.log")
  assert_not_contains "$launch" '--reasoning' "hermes spawn invented an effort when none was chosen"
  pass "hermes maps the shared low/medium/high/xhigh/max vocabulary straight across by name"
}

# hermes has no primary supervision protocol investigated or built by this
# verification, the same reason muse is refused.
test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="hermes-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" hermes --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "hermes was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "hermes secondmate refusal did not explain the boundary"
  pass "hermes is refused as a secondmate harness"
}

test_spawn_writes_busy_binding_and_teardown_removes_it() {
  local rec case_dir home proj wt fakebin id binding
  rec=$(make_spawn_case binding)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_hermes_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "hermes spawn failed"

  binding="$home/state/$id.hermes-session"
  assert_present "$binding" "hermes spawn did not write the session binding"
  assert_grep "db_path=$home/hermeshome/state.db" "$binding" \
    "hermes binding did not record the resolved database path"
  assert_grep "workspace_root=$wt" "$binding" "hermes binding did not record the task worktree"
  # No busy record is armed: the source is pull-only with no writer, so a
  # seeded busy record could never be settled.
  assert_absent "$home/state/$id.busy-gen" "hermes spawn armed a busy record it can never clear"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "hermes teardown failed"
  assert_absent "$binding" "hermes session binding survived teardown"
  pass "hermes spawn writes a session binding that teardown removes"
}

# --- busy source: shared state.db fold ----------------------------------------

# make_state_db <path>: a minimal state.db carrying only the columns the fold
# reads, matching hermes 0.20.0's real schema shape.
make_state_db() {
  local db=$1
  python3 - "$db" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT)")
con.execute(
    "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, "
    "session_id TEXT, role TEXT, content TEXT, finish_reason TEXT)"
)
con.commit()
con.close()
PY
}

add_session() {  # <db> <session-id> <cwd>
  python3 - "$1" "$2" "$3" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO sessions (id, cwd) VALUES (?, ?)", (sys.argv[2], sys.argv[3]))
con.commit()
con.close()
PY
}

add_message() {  # <db> <session-id> <role> <finish_reason-or-empty>
  python3 - "$1" "$2" "$3" "${4:-}" <<'PY'
import sqlite3
import sys

fr = sys.argv[4] or None
con = sqlite3.connect(sys.argv[1])
con.execute(
    "INSERT INTO messages (session_id, role, content, finish_reason) VALUES (?, ?, '', ?)",
    (sys.argv[2], sys.argv[3], fr),
)
con.commit()
con.close()
PY
}

classify_hermes() {  # <state-dir> <id>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux fake:0 hermes "$2" "$1"
  )
}

run_turn_state() {  # <db> <session-id>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_hermes_turn_state "$1" "$2"
  )
}

test_turn_fold_tracks_open_tool_calls_and_completion() {
  local dir db out
  dir="$TMP_ROOT/fold"
  mkdir -p "$dir"
  db="$dir/state.db"
  make_state_db "$db"

  add_message "$db" s1 user
  out=$(run_turn_state "$db" s1)
  [ "$out" = busy ] || fail "a trailing user message folded to '$out', expected busy"

  add_message "$db" s1 assistant tool_calls
  out=$(run_turn_state "$db" s1)
  [ "$out" = busy ] || fail "a pending tool call folded to '$out', expected busy"

  add_message "$db" s1 tool
  out=$(run_turn_state "$db" s1)
  [ "$out" = busy ] || fail "a tool result awaiting the model folded to '$out', expected busy"

  add_message "$db" s1 assistant stop
  out=$(run_turn_state "$db" s1)
  [ "$out" = settled ] || fail "a completed turn folded to '$out', expected settled"

  pass "the turn fold tracks an open tool-call round trip through to completion"
}

# The load-bearing regression: hermes 0.20.0's Ctrl+C interrupt path closes a
# turn with an assistant row whose finish_reason is NULL, not "stop". A fold
# keyed on finish_reason="stop" specifically would read an interrupted turn as
# busy forever.
test_interrupted_turn_with_null_finish_reason_settles() {
  local dir db out
  dir="$TMP_ROOT/interrupt"
  mkdir -p "$dir"
  db="$dir/state.db"
  make_state_db "$db"

  add_message "$db" s1 user
  add_message "$db" s1 assistant tool_calls
  add_message "$db" s1 tool
  add_message "$db" s1 assistant ''
  out=$(run_turn_state "$db" s1)
  [ "$out" = settled ] \
    || fail "an interrupted turn (finish_reason NULL) folded to '$out', expected settled"
  pass "an interrupted turn with a NULL finish_reason settles rather than staying busy forever"
}

test_resolved_session_with_no_messages_is_none() {
  local dir db out
  dir="$TMP_ROOT/none"
  mkdir -p "$dir"
  db="$dir/state.db"
  make_state_db "$db"
  out=$(run_turn_state "$db" s1)
  [ "$out" = none ] || fail "a message-free session folded to '$out', expected none"
  pass "a resolved session with no messages yet folds to none"
}

test_binding_selects_the_unique_matching_session() {
  local dir state id db verdict
  dir="$TMP_ROOT/bind"
  state="$dir/state"
  db="$dir/state.db"
  id=bindtask
  mkdir -p "$state"
  make_state_db "$db"

  # Another task's session lives in the same shared database and must never
  # be folded here.
  add_session "$db" other "$dir/other-ws"
  add_message "$db" other user

  add_session "$db" mine "$dir/my-ws"
  add_message "$db" mine user
  add_message "$db" mine assistant stop

  printf 'db_path=%s\nworkspace_root=%s\n' "$db" "$dir/my-ws" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "idle hermes-state-db" ] \
    || fail "binding leaked another workspace's turn state: got '$verdict'"

  printf 'db_path=%s\nworkspace_root=%s\n' "$db" "$dir/other-ws" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "busy hermes-state-db" ] \
    || fail "binding did not fold the workspace it was pointed at: got '$verdict'"
  pass "the session binding folds only the session matching this task's worktree"
}

test_binding_excludes_prior_session_in_same_workspace() {
  local dir state id db verdict
  dir="$TMP_ROOT/prior"
  state="$dir/state"
  db="$dir/state.db"
  id=priortask
  mkdir -p "$state"
  make_state_db "$db"

  # A reused treehouse pool slot: an OLD session already existed for this
  # exact workspace path before this pane launched.
  add_session "$db" old "$dir/ws"
  add_message "$db" old user
  add_message "$db" old assistant stop

  add_session "$db" current "$dir/ws"
  add_message "$db" current user

  printf 'db_path=%s\nworkspace_root=%s\n' "$db" "$dir/ws" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "unknown hermes-state-db" ] \
    || fail "two matching sessions with no prior_session exclusion resolved unambiguously: got '$verdict'"

  printf 'db_path=%s\nworkspace_root=%s\nprior_session=old\n' "$db" "$dir/ws" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "busy hermes-state-db" ] \
    || fail "the prior_session exclusion did not select the current pane's own session: got '$verdict'"
  pass "a relaunch into a reused worktree folds its own session, not a predecessor pane's"
}

test_missing_and_unreadable_bindings_are_unknown_never_idle() {
  local dir state id verdict db
  dir="$TMP_ROOT/unknowns"
  state="$dir/state"
  db="$dir/state.db"
  id=unk
  mkdir -p "$state"
  make_state_db "$db"

  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "unknown hermes-state-db" ] || fail "absent binding classified '$verdict'"

  printf 'db_path=%s\nworkspace_root=%s\n' "$dir/missing.db" "$dir/ws" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "unknown hermes-state-db" ] || fail "missing database classified '$verdict'"

  add_session "$db" nomatch "$dir/somewhere-else"
  add_message "$db" nomatch user
  printf 'db_path=%s\nworkspace_root=%s\n' "$db" "$dir/ws" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "unknown hermes-state-db" ] || fail "unmatched workspace classified '$verdict'"

  printf 'garbage\n' > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "unknown hermes-state-db" ] || fail "malformed binding classified '$verdict'"

  add_session "$db" nomsgs "$dir/ws-none"
  printf 'db_path=%s\nworkspace_root=%s\n' "$db" "$dir/ws-none" > "$state/$id.hermes-session"
  verdict=$(classify_hermes "$state" "$id")
  [ "$verdict" = "unknown hermes-state-db" ] \
    || fail "a resolved session with no messages yet classified '$verdict', expected unknown"
  pass "every unproven hermes binding classifies unknown rather than idle"
}

# hermes records nothing, so it must trust no record source. A trusted source
# with no writer would seed a busy record that nothing could ever settle.
test_hermes_trusts_no_record_sources() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness hermes
  )
  [ -z "$out" ] || fail "hermes trusts record sources it has no writer for: '$out'"
  pass "hermes trusts no busy record source"
}

# hermes draws a busy hint row inside its composer frame for the whole turn,
# which the structural composer scanner does not recognise (verified live),
# so delivery confirmation has to key on this rendered token instead - the
# same treatment cursor's own "ctrl+c to stop" footer already gets. Distinct
# harnesses' tokens must never cross-match: grok's similarly-shaped
# "Ctrl+c:cancel" uses a colon where hermes uses a space, so the two must
# stay mutually exclusive.
test_hermes_busy_token_matches_only_its_own_harness() {
  (
    # shellcheck source=bin/fm-composer-lib.sh
    . "$ROOT/bin/fm-composer-lib.sh"
    printf '%s' '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel' \
      | fm_busy_lines_match hermes \
      || fail "the hermes busy-hint row was not recognised as busy for harness=hermes"
    printf '%s' 'Ctrl+c:cancel' | fm_busy_lines_match hermes \
      && fail "hermes busy matching accepted grok's differently-punctuated token"
    printf '%s' 'Ctrl+C cancel' | fm_busy_lines_match \
      || fail "hermes's token is missing from the harness-less union default"
    printf '%s' '❯' | fm_busy_lines_match hermes \
      && fail "an idle bare composer was misclassified as busy for harness=hermes"
    true
  ) || exit 1
  pass "hermes's busy-hint token matches only harness=hermes and the harness-less union, never grok's"
}

test_detects_process_via_comm_rename
test_unrenamed_python_is_not_misdetected_as_hermes
test_spawn_launch_shape
test_spawn_maps_effort_and_model
test_spawn_refuses_secondmate
test_spawn_writes_busy_binding_and_teardown_removes_it
test_turn_fold_tracks_open_tool_calls_and_completion
test_interrupted_turn_with_null_finish_reason_settles
test_resolved_session_with_no_messages_is_none
test_binding_selects_the_unique_matching_session
test_binding_excludes_prior_session_in_same_workspace
test_missing_and_unreadable_bindings_are_unknown_never_idle
test_hermes_trusts_no_record_sources
test_hermes_busy_token_matches_only_its_own_harness
