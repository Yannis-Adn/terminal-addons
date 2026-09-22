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

# --- find_pty ----------------------------------------------------------------
# Un faux « claude » (script nommé claude, donc comm = claude) lance un bash qui
# source tab-status.sh et appelle find_pty. Sous `script`, le faux claude a un
# pty jetable : find_pty doit renvoyer exactement celui-là, jamais celui de la
# vraie session Claude qui exécute les tests.

mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" << 'EOF'
#!/bin/bash
tty
bash -c 'source "$1"; find_pty && echo "$REPLY" || echo "introuvable"' _ "$SCRIPT"
EOF
chmod +x "$tmp/bin/claude"

result=$(SCRIPT=$script script -qec "$tmp/bin/claude" /dev/null < /dev/null | tr -d '\r')
expected_tty=$(sed -n 1p <<< "$result")
found_tty=$(sed -n 2p <<< "$result")
check "find_pty : trouve le pty du processus claude" "$expected_tty" "$found_tty"
check "find_pty : c'est bien un /dev/pts" "oui" "$([[ $found_tty == /dev/pts/* ]] && echo oui || echo non)"

result=$(SCRIPT=$script "$tmp/bin/claude" < /dev/null 2> /dev/null | sed -n 2p)
check "find_pty : claude sans pty (claude -p) → introuvable" "introuvable" "$result"

# --- Contenu des toasts (dry-run, appelle vraiment powershell.exe) -----------

# toast_of <événement> <champs JSON> : titre et corps calculés, séparés par « | ».
toast_of() {
  : > "$tmp/dry"
  rm -rf "$tmp/state"
  local json="{\"session_id\":\"s1\",\"cwd\":\"/home/u/mon-projet\",\"hook_event_name\":\"$1\",$2}"
  WT_SESSION=test TMUX= WT_TAB_STATUS_OUT="$tmp/out" WT_TAB_STATUS_STATE_DIR="$tmp/state" \
    WT_TAB_STATUS_TOAST_DRYRUN="$tmp/dry" bash "$script" <<< "$json"
  paste -sd '|' "$tmp/dry"
}

if command -v powershell.exe > /dev/null; then
  check "toast terminé : titre + corps nettoyé" \
    "🟢 mon-projet — Terminé|Fini : j'ai corrigé login.ts. Tout passe ✅" \
    "$(toast_of Stop '"last_assistant_message":"**Fini** : j'"'"'ai corrigé `login.ts`.\n\nTout passe ✅","background_tasks":[]')"
  check "toast permission : outil + commande" \
    "🔴 mon-projet — Claude vous attend|Permission demandée : Bash — git push" \
    "$(toast_of PermissionRequest '"tool_name":"Bash","tool_input":{"command":"git push"}')"
  check "toast notification : message repris" \
    "🔴 mon-projet — Claude vous attend|Claude needs your permission to use Bash" \
    "$(toast_of Notification '"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"')"
  check "toast question" \
    "🔴 mon-projet — Claude vous attend|Une question attend votre réponse" \
    "$(toast_of PreToolUse '"tool_name":"AskUserQuestion"')"
  check "toast erreur API" \
    "🟠 mon-projet — Erreur API|rate_limit" \
    "$(toast_of StopFailure '"error":"rate_limit"')"
  long=$(printf 'a%.0s' {1..300})
  check "toast : corps tronqué à 150 caractères" \
    "🟢 mon-projet — Terminé|$(printf 'a%.0s' {1..149})…" \
    "$(toast_of Stop "\"last_assistant_message\":\"$long\"")"
else
  echo "skip toasts : powershell.exe introuvable"
fi

# --- hooks.json --------------------------------------------------------------

hooks_json=$here/../hooks/hooks.json
for event in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure \
  PermissionRequest Elicitation ElicitationResult Notification Stop StopFailure; do
  check "hooks.json déclare $event" "oui" "$(grep -q "\"$event\"" "$hooks_json" 2> /dev/null && echo oui || echo non)"
done
check "hooks.json : 12 appels à tab-status.sh" "12" "$(grep -c 'tab-status.sh' "$hooks_json" 2> /dev/null)"

# --- Bilan -----------------------------------------------------------------

echo
echo "$pass réussi(s), $fail échec(s)"
[ "$fail" -eq 0 ]
