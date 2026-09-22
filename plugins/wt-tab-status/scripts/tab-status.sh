#!/bin/bash
# wt-tab-status — reflète l'état de Claude Code dans l'onglet Windows Terminal.
#
# Appelé par tous les hooks du plugin avec le JSON de l'événement sur stdin.
# Colore le fond de l'onglet (DECAC), pilote l'anneau de progression (OSC 9;4)
# et fait sonner la cloche (BEL) en écrivant directement dans le pty de Claude :
# les hooks n'ont pas de terminal de contrôle, et le champ officiel
# `terminalSequence` refuse les séquences CSI comme DECAC.
#
# N'écrit jamais sur stdout (injecté dans le contexte de Claude pour
# SessionStart et UserPromptSubmit) et sort toujours avec le code 0.
#
# Variables de test :
#   WT_TAB_STATUS_OUT           fichier qui reçoit les séquences à la place du pty
#   WT_TAB_STATUS_STATE_DIR     dossier des fichiers d'état
#   WT_TAB_STATUS_TOAST_LOG     journal des toasts déclenchés (aucun toast affiché)
#   WT_TAB_STATUS_TOAST_DRYRUN  fichier qui reçoit le titre et le corps calculés par toast.ps1

# Fond d'onglet, « <index texte>;<index fond> » de la palette xterm-256.
# 263;264 rend la main à la couleur du profil.
declare -A COLOR=([neutral]='263;264' [working]='15;25' [waiting]='15;124' [done]='15;28' [error]='15;166')
# Anneau OSC 9;4 : 0 masqué, 3 tourne, 4 pause (barre des tâches jaune), 2 erreur (rouge).
declare -A RING=([neutral]='0' [working]='3' [waiting]='4;100' [done]='0' [error]='2;100')
# États qui méritent une alerte : cloche et toast.
declare -A ALERT=([waiting]=1 [done]=1 [error]=1)

input=

# field <clé> : place dans REPLY la valeur du premier champ chaîne <clé> du JSON.
# Une clé imbriquée dans une chaîne est échappée (\"clé\") et ne correspond pas.
field() {
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  REPLY=
  [[ $input =~ $re ]] && REPLY=${BASH_REMATCH[1]}
}

# Vrai si un agent tourne encore en fond (sous-agent, workflow, coéquipier,
# session cloud) : il relancera Claude. Un shell ou un monitor en fond (serveur
# de dev…) peut durer indéfiniment et n'empêche pas « terminé ».
has_running_agents() {
  local re='"type"[[:space:]]*:[[:space:]]*"(subagent|workflow|teammate|cloud session)"'
  [[ $input =~ $re ]]
}

# agent : place dans REPLY l'auteur de l'événement (agent_id, ou « main »).
agent() {
  field agent_id
  REPLY=${REPLY:-main}
}

# target_state <état courant> <auteur de l'attente> : place dans REPLY l'état
# visé par l'événement, ou une chaîne vide si l'événement ne change rien.
target_state() {
  local current=$1 owner=$2 event
  field hook_event_name
  event=$REPLY
  case $event in
    SessionStart)
      # L'auto-compaction relance SessionStart en plein tour.
      field source
      [ "$REPLY" = compact ] && REPLY= || REPLY=neutral
      ;;
    SessionEnd) REPLY=neutral ;;
    UserPromptSubmit | ElicitationResult) REPLY=working ;;
    PreToolUse | PostToolUse | PostToolUseFailure)
      # Pendant une attente, seul l'agent qui attend peut la lever : les outils
      # d'un sous-agent parallèle ne veulent pas dire que la demande est réglée.
      agent
      if [ "$current" = waiting ] && [ -n "$owner" ] && [ "$owner" != any ] && [ "$REPLY" != "$owner" ]; then
        REPLY=
        return
      fi
      REPLY=working
      if [ "$event" = PreToolUse ]; then
        field tool_name
        case $REPLY in
          AskUserQuestion | ExitPlanMode) REPLY=waiting ;;
          *) REPLY=working ;;
        esac
      fi
      ;;
    PermissionRequest)
      # Un sous-agent en fond ne peut pas afficher de demande : Claude lance
      # quand même ce hook, puis refuse. Les vraies demandes d'un sous-agent
      # arrivent par Notification:permission_prompt (~6 s plus tard).
      field agent_id
      [ -z "$REPLY" ] && REPLY=waiting || REPLY=
      ;;
    Elicitation) REPLY=waiting ;;
    Notification)
      field notification_type
      case $REPLY in
        permission_prompt | worker_permission_prompt | elicitation_dialog | elicitation_url_dialog | agent_needs_input) REPLY=waiting ;;
        # Seul signal après une interruption par Échap (aucun hook ne la signale).
        # Claude ne l'envoie jamais pendant une question ou une permission
        # affichée : on peut donc quitter « en cours » comme « vous attend ».
        idle_prompt) [ "$current" = working ] || [ "$current" = waiting ] && REPLY=neutral || REPLY= ;;
        *) REPLY= ;;
      esac
      ;;
    Stop)
      if has_running_agents; then
        # Un sous-agent en fond peut encore attendre une permission : ne pas
        # effacer l'attente qu'il a signalée.
        [ "$current" = waiting ] && REPLY= || REPLY=working
      else
        REPLY=done
      fi
      ;;
    StopFailure) REPLY=error ;;
    *) REPLY= ;;
  esac
}

# find_pty : place dans REPLY le pty de la session Claude qui a lancé le hook.
# Remonte les parents jusqu'au premier processus « claude » et échoue si son
# entrée standard n'est pas un pty (claude -p, SDK, claude lancé par un outil) :
# un claude imbriqué ne doit pas colorer l'onglet de la session parente.
find_pty() {
  local pid=$PPID comm stat link i
  REPLY=
  for ((i = 0; i < 16 && pid > 1; i++)); do
    read -r comm 2> /dev/null < "/proc/$pid/comm" || return 1
    if [ "$comm" = claude ]; then
      link=$(readlink "/proc/$pid/fd/0" 2> /dev/null)
      [[ $link == /dev/pts/* ]] || return 1
      REPLY=$link
      return 0
    fi
    read -r stat 2> /dev/null < "/proc/$pid/stat" || return 1
    # Après « pid (comm) » viennent l'état puis le ppid.
    read -r _ pid _ <<< "${stat##*) }"
  done
  return 1
}

# emit <état> : écrit couleur, anneau et cloche en un seul write() pour limiter
# le risque d'entrelacement avec le rendu de Claude.
emit() {
  local seq dest
  printf -v seq '\e[2;%s,|\e]9;4;%s\a' "${COLOR[$1]}" "${RING[$1]}"
  [ -n "${ALERT[$1]:-}" ] && seq+=$'\a'
  if [ -n "${WT_TAB_STATUS_OUT:-}" ]; then
    dest=$WT_TAB_STATUS_OUT
  else
    find_pty || return 1
    dest=$REPLY
  fi
  printf '%s' "$seq" 2> /dev/null >> "$dest"
}

# toast <état> : notification Windows lancée en arrière-plan, sans bloquer Claude.
# Le JSON du hook part sur stdin de PowerShell, qui en tire titre et corps.
toast() {
  if [ -n "${WT_TAB_STATUS_TOAST_LOG:-}" ]; then
    printf '%s\n' "$1" >> "$WT_TAB_STATUS_TOAST_LOG"
    return 0
  fi
  local ps dry=0 encoded dir
  ps=$(command -v powershell.exe) || ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$ps" ] || return 0
  [ -n "${WT_TAB_STATUS_TOAST_DRYRUN:-}" ] && dry=1
  dir=$(dirname "${BASH_SOURCE[0]}")
  encoded=$({
    printf '$Kind = '"'"'%s'"'"'\n$DryRun = [bool]%s\n' "$1" "$dry"
    cat "$dir/toast.ps1"
  } | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  if [ "$dry" = 1 ]; then
    "$ps" -NoProfile -NonInteractive -EncodedCommand "$encoded" <<< "$input" 2>&1 \
      | tr -d '\r' >> "$WT_TAB_STATUS_TOAST_DRYRUN"
  else
    setsid -f "$ps" -NoProfile -NonInteractive -EncodedCommand "$encoded" <<< "$input" > /dev/null 2>&1
  fi
}

# update <fichier d'état> : lit l'état, calcule la transition et l'applique.
# Appelé avec le verrou ouvert sur le descripteur 9.
update() {
  local state_file=$1 current= owner= target event
  flock -w 2 9 2> /dev/null
  field hook_event_name
  event=$REPLY
  # SessionStart repart de zéro : un --resume ne doit pas croire l'onglet déjà neutre.
  [ "$event" != SessionStart ] && [ -f "$state_file" ] && read -r current owner < "$state_file"
  target_state "$current" "$owner"
  target=$REPLY

  if [ -n "$target" ] && [ "$target" != "$current" ] && emit "$target"; then
    # Auteur de l'attente ; « any » quand l'événement ne le dit pas.
    case $event in
      Notification | Elicitation) REPLY=any ;;
      *) agent ;;
    esac
    printf '%s %s\n' "$target" "$REPLY" > "$state_file"
    # Le toast ne doit pas hériter du verrou.
    [ -n "${ALERT[$target]:-}" ] && toast "$target" 9>&-
  fi
  # Même si le pty a disparu (onglet fermé) : ne pas laisser traîner l'état.
  [ "$event" = SessionEnd ] && rm -f "$state_file"
}

main() {
  [ -n "${WT_SESSION:-}" ] || return 0
  [ -z "${TMUX:-}" ] || return 0
  # cat plutôt que read -d '' : read lit un octet à la fois sur un pipe.
  input=$(cat)

  field session_id
  [[ $REPLY =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  local state_dir=${WT_TAB_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/wt-tab-status}
  [ -d "$state_dir" ] || mkdir -p -m 700 "$state_dir" 2> /dev/null
  [ -O "$state_dir" ] || return 0
  # Les hooks d'un même tour tournent en parallèle : le verrou évite cloche et toast en double.
  update "$state_dir/$REPLY" 9> "$state_dir/.lock"
  return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main
  exit 0
fi
