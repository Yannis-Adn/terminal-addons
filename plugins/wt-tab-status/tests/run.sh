#!/bin/bash
# Tests for tab-status.sh: replay sequences of hook events and check the escape
# sequences written (the pty is simulated by a file) and the toasts triggered.
# Usage: bash plugins/wt-tab-status/tests/run.sh

here=$(cd "$(dirname "$0")" && pwd)
script=$here/../scripts/tab-status.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ESC=$'\e' BEL=$'\a'
NEUTRAL="${ESC}[2;263;264,|${ESC}]9;4;0${BEL}"
WORKING="${ESC}[2;15;25,|${ESC}]9;4;3${BEL}"
WAITING="${ESC}[2;15;124,|${ESC}]9;4;4;100${BEL}${BEL}"
DONE="${ESC}[2;15;28,|${ESC}]9;4;0${BEL}${BEL}"
ERROR="${ESC}[2;15;166,|${ESC}]9;4;2;100${BEL}${BEL}"

# New scenario: empty simulated pty, toast log and state.
fresh() {
  rm -rf "$tmp/state"
  : > "$tmp/out"
  : > "$tmp/toasts"
  : > "$tmp/stdout"
}

# hook <event> [extra JSON fields]: run the script the way Claude Code runs a hook.
hook() {
  local json="{\"session_id\":\"s1\",\"cwd\":\"/home/u/my-project\",\"hook_event_name\":\"$1\"${2:+,$2}}"
  WT_SESSION=test TMUX='' WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
    WT_TAB_STATUS_TOAST_LOG="$tmp/toasts" bash "$script" <<< "$json" >> "$tmp/stdout"
}

# check <name> <expected> <actual>
check() {
  if [ "$2" == "$3" ]; then
    pass=$((pass + 1))
    echo "ok   $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1"
    printf '  expected: %q\n  actual:   %q\n' "$2" "$3"
  fi
}

out() { cat "$tmp/out"; }
toasts() { tr '\n' ' ' < "$tmp/toasts"; }
state_file() { [ -e "$tmp/state/s1" ] && echo present || echo absent; }

# --- State machine -----------------------------------------------------------

fresh
hook SessionStart '"source":"startup"'
hook UserPromptSubmit '"prompt":"hi"'
hook PreToolUse '"tool_name":"Bash","tool_input":{"command":"ls"}'
hook PostToolUse '"tool_name":"Bash"'
hook Stop '"background_tasks":[]'
check "simple turn: neutral → working → done" "$NEUTRAL$WORKING$DONE" "$(out)"
check "simple turn: one \"done\" toast" "done " "$(toasts)"
check "nothing on stdout" "" "$(cat "$tmp/stdout")"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"Bash"'
hook PermissionRequest '"tool_name":"Bash","tool_input":{"command":"git push"}'
hook Notification '"notification_type":"permission_prompt","message":"Claude needs your permission"'
hook PostToolUse '"tool_name":"Bash"'
check "permission: working → waiting → working" "$WORKING$WAITING$WORKING" "$(out)"
check "permission: one toast despite the 6 s notification" "waiting " "$(toasts)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"AskUserQuestion"'
hook PostToolUse '"tool_name":"AskUserQuestion"'
check "AskUserQuestion waits" "$WORKING$WAITING$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"ExitPlanMode"'
check "ExitPlanMode waits" "$WORKING$WAITING" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"Bash","tool_input":{"description":"\"tool_name\":\"AskUserQuestion\""}'
check "tool_name nested in tool_input is ignored" "$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook Stop '"background_tasks":[{"id":"b1","type":"subagent","status":"running","agent_type":"Explore"}]'
check "background subagent: stays working, no toast" "$WORKING|" "$(out)|$(toasts)"
hook Stop '"background_tasks": [ ]'
check "background work finished: done" "$WORKING$DONE" "$(out)"

fresh
hook UserPromptSubmit
hook Stop
check "Stop without background_tasks: done" "$WORKING$DONE" "$(out)"

fresh
hook UserPromptSubmit
hook Stop '"background_tasks":[{"id":"b2","type":"shell","status":"running","description":"server","command":"npm run dev"},{"id":"b3","type":"monitor","status":"running"}]'
check "background shell or monitor: still done" "$WORKING$DONE|done " "$(out)|$(toasts)"

fresh
hook UserPromptSubmit
hook PermissionRequest '"agent_id":"a1","agent_type":"general-purpose","tool_name":"Bash"'
check "subagent PermissionRequest: ignored" "$WORKING" "$(out)"
hook Notification '"notification_type":"permission_prompt","message":"Claude needs your permission"'
check "… the 6 s notification takes over" "$WORKING$WAITING" "$(out)"
hook Stop '"background_tasks":[{"id":"b1","type":"subagent","status":"running","agent_type":"general-purpose"}]'
check "… main turn ends while the subagent still waits: stays red" "$WORKING$WAITING" "$(out)"

fresh
hook UserPromptSubmit
hook PermissionRequest '"tool_name":"Bash"'
hook PreToolUse '"agent_id":"a1","tool_name":"Read"'
hook PostToolUse '"agent_id":"a1","tool_name":"Read"'
check "main thread waiting: subagent tools do not clear it" "$WORKING$WAITING" "$(out)"
hook PostToolUse '"tool_name":"Bash"'
check "… the main thread's tool clears it" "$WORKING$WAITING$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook Notification '"notification_type":"permission_prompt","message":"Claude needs your permission"'
hook PostToolUse '"agent_id":"a1","tool_name":"Bash"'
check "waiting from a notification: any tool clears it" "$WORKING$WAITING$WORKING" "$(out)"

fresh
hook Notification '"notification_type":"worker_permission_prompt","message":"A teammate needs permission"'
check "teammate permission: waiting" "$WAITING" "$(out)"

fresh
hook UserPromptSubmit
hook SessionStart '"source":"compact"'
check "auto-compaction mid-turn: ignored" "$WORKING" "$(out)"

fresh
hook SessionStart '"source":"startup"'
hook SessionStart '"source":"resume"'
check "resume: SessionStart re-emits even when already neutral" "$NEUTRAL$NEUTRAL" "$(out)"

fresh
hook UserPromptSubmit
hook StopFailure '"error":"rate_limit"'
check "API error: orange + toast" "$WORKING$ERROR|error " "$(out)|$(toasts)"

fresh
hook UserPromptSubmit
hook Notification '"notification_type":"idle_prompt"'
check "Esc then idle_prompt: working → neutral" "$WORKING$NEUTRAL" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"AskUserQuestion"'
hook Notification '"notification_type":"idle_prompt"'
check "Esc on a question then idle_prompt: waiting → neutral" "$WORKING$WAITING$NEUTRAL" "$(out)"

fresh
hook UserPromptSubmit
hook Stop
hook Notification '"notification_type":"idle_prompt"'
check "idle_prompt after done: ignored" "$WORKING$DONE" "$(out)"

fresh
hook Notification '"notification_type":"elicitation_dialog"'
hook ElicitationResult
check "MCP elicitation: waiting → working" "$WAITING$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook SubagentStop
hook PreCompact
hook Notification '"notification_type":"auth_success"'
check "unhandled events are ignored" "$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"Read"'
hook PostToolUse '"tool_name":"Read"'
hook PreToolUse '"tool_name":"Edit"'
check "dedup: a single write while the state does not change" "$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook SessionEnd '"reason":"prompt_input_exit"'
check "session end: back to neutral" "$WORKING$NEUTRAL" "$(out)"
check "session end: state file removed" "absent" "$(state_file)"

fresh
hook UserPromptSubmit
WT_SESSION=test TMUX='' WT_TAB_STATUS_OUT=/nonexistent/pty WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"s1","hook_event_name":"SessionEnd","reason":"other"}'
check "session end with the tab already closed: state file removed" "absent" "$(state_file)"

races=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  fresh
  hook UserPromptSubmit
  hook PermissionRequest '"tool_name":"Bash"' &
  hook PermissionRequest '"tool_name":"Edit"' &
  hook PermissionRequest '"tool_name":"Write"' &
  wait
  [ "$(toasts)" = "waiting " ] || races=$((races + 1))
done
check "concurrency: 3 simultaneous permissions → one toast (10 runs)" "0" "$races"

fresh
WT_SESSION='' TMUX='' WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"s1","hook_event_name":"UserPromptSubmit"}'
check "guard: outside Windows Terminal, nothing" "" "$(out)"

fresh
WT_SESSION=test TMUX=/tmp/tmux-1000/default,1,0 WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"s1","hook_event_name":"UserPromptSubmit"}'
check "guard: inside tmux, nothing" "" "$(out)"

fresh
WT_SESSION=test TMUX='' WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"../../etc/x","hook_event_name":"UserPromptSubmit"}'
check "guard: invalid session_id, nothing" "" "$(out)"

# --- find_pty ----------------------------------------------------------------
# A fake "claude" (a script named claude, hence comm = claude) starts a bash that
# sources tab-status.sh and calls find_pty. Under `script`, the fake claude gets
# a throwaway pty: find_pty must return exactly that one, never the pty of the
# real Claude session that may be running these tests.

mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" << 'EOF'
#!/bin/bash
tty
bash -c 'source "$1"; find_pty && echo "$REPLY" || echo "not-found"' _ "$SCRIPT"
EOF
chmod +x "$tmp/bin/claude"

# stdin from /dev/null: under Claude Code, stdin is a socket that never closes.
result=$(SCRIPT=$script script -qec "$tmp/bin/claude" /dev/null < /dev/null | tr -d '\r')
expected_tty=$(sed -n 1p <<< "$result")
found_tty=$(sed -n 2p <<< "$result")
check "find_pty: finds the pty of the claude process" "$expected_tty" "$found_tty"
check "find_pty: it is a /dev/pts" "yes" "$([[ $found_tty == /dev/pts/* ]] && echo yes || echo no)"

result=$(SCRIPT=$script "$tmp/bin/claude" < /dev/null 2> /dev/null | sed -n 2p)
check "find_pty: claude without a pty (claude -p) → not found" "not-found" "$result"

# --- Toast content (dry run, really calls powershell.exe) ---------------------

# toast_of <lang> <event> <JSON fields>: computed title and body, joined by "|".
toast_of() {
  : > "$tmp/dry"
  rm -rf "$tmp/state"
  local json="{\"session_id\":\"s1\",\"cwd\":\"/home/u/my-project\",\"hook_event_name\":\"$2\",$3}"
  WT_SESSION=test TMUX='' WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
    WT_TAB_STATUS_LANG=$1 WT_TAB_STATUS_TOAST_DRYRUN="$tmp/dry" bash "$script" <<< "$json"
  paste -sd '|' "$tmp/dry"
}

if command -v powershell.exe > /dev/null; then
  # shellcheck disable=SC2016 # backticks are literal Markdown
  check "toast done: title + cleaned-up body" \
    "🟢 my-project — Done|Fixed: login.ts now redirects. All tests pass ✅" \
    "$(toast_of en Stop '"last_assistant_message":"**Fixed**: `login.ts` now redirects.\n\nAll tests pass ✅","background_tasks":[]')"
  check "toast permission: tool + command" \
    "🔴 my-project — Claude needs you|Permission requested: Bash — git push" \
    "$(toast_of en PermissionRequest '"tool_name":"Bash","tool_input":{"command":"git push"}')"
  check "toast notification: message is reused" \
    "🔴 my-project — Claude needs you|Claude needs your permission to use Bash" \
    "$(toast_of en Notification '"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"')"
  check "toast question" \
    "🔴 my-project — Claude needs you|A question is waiting for your answer" \
    "$(toast_of en PreToolUse '"tool_name":"AskUserQuestion"')"
  check "toast plan" \
    "🔴 my-project — Claude needs you|A plan is waiting for your approval" \
    "$(toast_of en PreToolUse '"tool_name":"ExitPlanMode"')"
  check "toast API error" \
    "🟠 my-project — API error|rate_limit" \
    "$(toast_of en StopFailure '"error":"rate_limit"')"
  check "toast API error: readable details when present" \
    "🟠 my-project — API error|Usage limit reached" \
    "$(toast_of en StopFailure '"error":"rate_limit","error_details":"Usage limit reached"')"
  check "toast: never splits an emoji" \
    "🟢 my-project — Done|$(printf 'a%.0s' {1..148})…" \
    "$(toast_of en Stop "\"last_assistant_message\":\"$(printf 'a%.0s' {1..148})😀 and the rest of the message\"")"
  check "toast: body truncated to 150 characters" \
    "🟢 my-project — Done|$(printf 'a%.0s' {1..149})…" \
    "$(toast_of en Stop "\"last_assistant_message\":\"$(printf 'a%.0s' {1..300})\"")"
  # shellcheck disable=SC2016 # backticks are literal Markdown
  check "toast in French: done" \
    "🟢 my-project — Terminé|J'ai corrigé login.ts ✅" \
    "$(toast_of fr Stop '"last_assistant_message":"J'"'"'ai corrigé `login.ts` ✅"')"
  check "toast in French: permission" \
    "🔴 my-project — Claude vous attend|Permission demandée : Bash — git push" \
    "$(toast_of fr PermissionRequest '"tool_name":"Bash","tool_input":{"command":"git push"}')"
  check "toast in French: question and API error" \
    "🔴 my-project — Claude vous attend|Une question attend votre réponse / 🟠 my-project — Erreur API|rate_limit" \
    "$(toast_of fr PreToolUse '"tool_name":"AskUserQuestion"') / $(toast_of fr StopFailure '"error":"rate_limit"')"
else
  echo "skip toasts: powershell.exe not found"
fi

# --- hooks.json --------------------------------------------------------------

hooks_json=$here/../hooks/hooks.json
for event in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure \
  PermissionRequest Elicitation ElicitationResult Notification Stop StopFailure; do
  check "hooks.json declares $event" "yes" "$(grep -q "\"$event\"" "$hooks_json" 2> /dev/null && echo yes || echo no)"
done
check "hooks.json: 12 calls to tab-status.sh" "12" "$(grep -c 'tab-status.sh' "$hooks_json" 2> /dev/null)"

# --- Summary -----------------------------------------------------------------

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
