#!/bin/bash
# Tests de tab-status.sh : rejoue des suites d'événements de hooks et vérifie
# les séquences écrites (pty simulé par un fichier) et les toasts déclenchés.
# Usage : bash plugins/wt-tab-status/tests/run.sh

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

# Nouveau scénario : pty simulé, journal de toasts et état vierges.
fresh() {
  rm -rf "$tmp/state"
  : > "$tmp/out"
  : > "$tmp/toasts"
  : > "$tmp/stdout"
}

# hook <événement> [champs JSON supplémentaires] : appelle le script comme un hook.
hook() {
  local json="{\"session_id\":\"s1\",\"cwd\":\"/home/u/mon-projet\",\"hook_event_name\":\"$1\"${2:+,$2}}"
  WT_SESSION=test TMUX= WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
    WT_TAB_STATUS_TOAST_LOG="$tmp/toasts" bash "$script" <<< "$json" >> "$tmp/stdout"
}

# check <nom> <attendu> <obtenu>
check() {
  if [ "$2" == "$3" ]; then
    pass=$((pass + 1))
    echo "ok   $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1"
    printf '  attendu : %q\n  obtenu  : %q\n' "$2" "$3"
  fi
}

out() { cat "$tmp/out"; }
toasts() { tr '\n' ' ' < "$tmp/toasts"; }

# --- Scénarios -------------------------------------------------------------

fresh
hook SessionStart '"source":"startup"'
hook UserPromptSubmit '"prompt":"salut"'
hook PreToolUse '"tool_name":"Bash","tool_input":{"command":"ls"}'
hook PostToolUse '"tool_name":"Bash"'
hook Stop '"background_tasks":[]'
check "tour simple : neutre → en cours → terminé" "$NEUTRAL$WORKING$DONE" "$(out)"
check "tour simple : un toast « done »" "done " "$(toasts)"
check "rien sur stdout" "" "$(cat "$tmp/stdout")"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"Bash"'
hook PermissionRequest '"tool_name":"Bash","tool_input":{"command":"git push"}'
hook Notification '"notification_type":"permission_prompt","message":"Claude needs your permission"'
hook PostToolUse '"tool_name":"Bash"'
check "permission : en cours → attend → en cours" "$WORKING$WAITING$WORKING" "$(out)"
check "permission : un seul toast malgré la notification à 6 s" "waiting " "$(toasts)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"AskUserQuestion"'
hook PostToolUse '"tool_name":"AskUserQuestion"'
check "question : AskUserQuestion passe en attente" "$WORKING$WAITING$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"ExitPlanMode"'
check "plan : ExitPlanMode passe en attente" "$WORKING$WAITING" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"Bash","tool_input":{"description":"\"tool_name\":\"AskUserQuestion\""}'
check "tool_name imbriqué dans tool_input ignoré" "$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook Stop '"background_tasks":[{"id":"b1","status":"running"}]'
check "tâches de fond : reste en cours, sans toast" "$WORKING|" "$(out)|$(toasts)"
hook Stop '"background_tasks": [ ]'
check "tâches de fond finies : terminé" "$WORKING$DONE" "$(out)"

fresh
hook UserPromptSubmit
hook Stop
check "Stop sans background_tasks : terminé" "$WORKING$DONE" "$(out)"

fresh
hook UserPromptSubmit
hook StopFailure '"error":"rate_limit"'
check "erreur API : orange + toast" "$WORKING$ERROR|error " "$(out)|$(toasts)"

fresh
hook UserPromptSubmit
hook Notification '"notification_type":"idle_prompt"'
check "Échap puis idle_prompt : en cours → neutre" "$WORKING$NEUTRAL" "$(out)"

fresh
hook UserPromptSubmit
hook Stop
hook Notification '"notification_type":"idle_prompt"'
check "idle_prompt après terminé : ignoré" "$WORKING$DONE" "$(out)"

fresh
hook Notification '"notification_type":"elicitation_dialog"'
hook ElicitationResult
check "élicitation MCP : attend → en cours" "$WAITING$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook SubagentStop
hook PreCompact
hook Notification '"notification_type":"auth_success"'
check "événements non gérés ignorés" "$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook PreToolUse '"tool_name":"Read"'
hook PostToolUse '"tool_name":"Read"'
hook PreToolUse '"tool_name":"Edit"'
check "déduplication : une seule écriture tant que l'état ne change pas" "$WORKING" "$(out)"

fresh
hook UserPromptSubmit
hook SessionEnd '"reason":"prompt_input_exit"'
check "fin de session : retour au neutre" "$WORKING$NEUTRAL" "$(out)"
check "fin de session : fichier d'état supprimé" "absent" "$([ -e "$tmp/state/s1" ] && echo présent || echo absent)"

fresh
WT_SESSION= TMUX= WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"s1","hook_event_name":"UserPromptSubmit"}'
check "garde-fou : hors Windows Terminal, rien" "" "$(out)"

fresh
WT_SESSION=test TMUX=/tmp/tmux-1000/default,1,0 WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"s1","hook_event_name":"UserPromptSubmit"}'
check "garde-fou : sous tmux, rien" "" "$(out)"

fresh
WT_SESSION=test TMUX= WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
  bash "$script" <<< '{"session_id":"../../etc/x","hook_event_name":"UserPromptSubmit"}'
check "garde-fou : session_id invalide, rien" "" "$(out)"

# --- Bilan -----------------------------------------------------------------

echo
echo "$pass réussi(s), $fail échec(s)"
[ "$fail" -eq 0 ]
