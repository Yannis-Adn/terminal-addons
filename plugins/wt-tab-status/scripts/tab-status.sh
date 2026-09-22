#!/bin/bash
# wt-tab-status — mirrors Claude Code's state in the Windows Terminal tab.
#
# Called by every hook of the plugin with the event JSON on stdin. Colors the
# tab background (DECAC), drives the progress ring (OSC 9;4) and rings the bell
# (BEL) by writing straight to Claude's pty: hooks have no controlling
# terminal, and the official `terminalSequence` output field rejects CSI
# sequences such as DECAC.
#
# Never writes to stdout (it would be injected into Claude's context on
# SessionStart and UserPromptSubmit) and always exits with status 0.
#
# Environment:
#   WT_TAB_STATUS_LANG          toast language (fr | en); default: Windows display language
# Test-only:
#   WT_TAB_STATUS_OUT           file that receives the sequences instead of the pty
#   WT_TAB_STATUS_STATE_DIR     directory of the state files
#   WT_TAB_STATUS_TOAST_LOG     log of triggered toasts (no toast is shown)
#   WT_TAB_STATUS_TOAST_DRYRUN  file that receives the title and body computed by toast.ps1

# Tab background, "<text index>;<background index>" in the xterm-256 palette.
# 263;264 hands the color back to the profile.
declare -A COLOR=([neutral]='263;264' [working]='15;25' [waiting]='15;124' [done]='15;28' [error]='15;166')
# OSC 9;4 ring: 0 hidden, 3 spinning, 4 paused (yellow taskbar), 2 error (red taskbar).
declare -A RING=([neutral]='0' [working]='3' [waiting]='4;100' [done]='0' [error]='2;100')
# States that deserve an alert: bell and toast.
declare -A ALERT=([waiting]=1 [done]=1 [error]=1)

input=

# field <key>: set REPLY to the value of the first string field <key> of the JSON.
# A key nested inside a string is escaped (\"key\") and does not match.
field() {
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  REPLY=
  [[ $input =~ $re ]] && REPLY=${BASH_REMATCH[1]}
}

# True when an agent still runs in the background (subagent, workflow, teammate,
# cloud session): it will wake Claude up again. A background shell or monitor
# (dev server…) may run forever and does not prevent "done".
has_running_agents() {
  local re='"type"[[:space:]]*:[[:space:]]*"(subagent|workflow|teammate|cloud session)"'
  [[ $input =~ $re ]]
}

# agent: set REPLY to the author of the event (agent_id, or "main").
agent() {
  field agent_id
  REPLY=${REPLY:-main}
}

# target_state <current state> <author of the wait>: set REPLY to the state the
# event leads to, or to an empty string when the event changes nothing.
target_state() {
  local current=$1 owner=$2 event
  field hook_event_name
  event=$REPLY
  case $event in
    SessionStart)
      # Auto-compaction fires SessionStart again in the middle of a turn.
      field source
      [ "$REPLY" = compact ] && REPLY= || REPLY=neutral
      ;;
    SessionEnd) REPLY=neutral ;;
    UserPromptSubmit | ElicitationResult) REPLY=working ;;
    PreToolUse | PostToolUse | PostToolUseFailure)
      # While waiting, only the waiting agent can end the wait: tools run by a
      # parallel subagent do not mean the request was answered.
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
      # A background subagent cannot show a prompt: Claude still runs this hook,
      # then denies. Real subagent prompts arrive through
      # Notification:permission_prompt (~6 s later).
      field agent_id
      [ -z "$REPLY" ] && REPLY=waiting || REPLY=
      ;;
    Elicitation) REPLY=waiting ;;
    Notification)
      field notification_type
      case $REPLY in
        permission_prompt | worker_permission_prompt | elicitation_dialog | elicitation_url_dialog | agent_needs_input) REPLY=waiting ;;
        # The only signal after an Esc interrupt (no hook reports it). Claude
        # never sends it while a question or permission prompt is on screen,
        # so it can clear "working" as well as "waiting".
        idle_prompt) [ "$current" = working ] || [ "$current" = waiting ] && REPLY=neutral || REPLY= ;;
        *) REPLY= ;;
      esac
      ;;
    Stop)
      if has_running_agents; then
        # A background subagent may still be waiting for a permission: keep
        # the wait it reported visible.
        [ "$current" = waiting ] && REPLY= || REPLY=working
      else
        REPLY='done'
      fi
      ;;
    StopFailure) REPLY=error ;;
    *) REPLY= ;;
  esac
}

# find_pty: set REPLY to the pty of the Claude session that ran the hook.
# Walks up the parents to the first "claude" process and fails if its standard
# input is not a pty (claude -p, SDK, claude started by a tool): a nested claude
# must not color the tab of the parent session.
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
    # "pid (comm)" is followed by the state, then the ppid.
    read -r _ pid _ <<< "${stat##*) }"
  done
  return 1
}

# emit <state>: write color, ring and bell in a single write() to limit the
# risk of interleaving with Claude's own rendering.
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

# toast <state>: Windows notification started in the background, never blocking
# Claude. The hook JSON goes to PowerShell's stdin, which builds title and body.
toast() {
  if [ -n "${WT_TAB_STATUS_TOAST_LOG:-}" ]; then
    printf '%s\n' "$1" >> "$WT_TAB_STATUS_TOAST_LOG"
    return 0
  fi
  local ps dry=0 lang='' encoded dir
  ps=$(command -v powershell.exe) || ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$ps" ] || return 0
  [ -n "${WT_TAB_STATUS_TOAST_DRYRUN:-}" ] && dry=1
  [[ ${WT_TAB_STATUS_LANG:-} =~ ^[a-z]{2}$ ]] && lang=$WT_TAB_STATUS_LANG
  dir=$(dirname "${BASH_SOURCE[0]}")
  encoded=$({
    # shellcheck disable=SC2016 # literal PowerShell variables
    printf '$Kind = '"'"'%s'"'"'\n$DryRun = [bool]%s\n$Lang = '"'"'%s'"'"'\n' "$1" "$dry" "$lang"
    cat "$dir/toast.ps1"
  } | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  if [ "$dry" = 1 ]; then
    "$ps" -NoProfile -NonInteractive -EncodedCommand "$encoded" <<< "$input" 2>&1 \
      | tr -d '\r' >> "$WT_TAB_STATUS_TOAST_DRYRUN"
  else
    setsid -f "$ps" -NoProfile -NonInteractive -EncodedCommand "$encoded" <<< "$input" > /dev/null 2>&1
  fi
}

# update <state file>: read the state, compute the transition and apply it.
# Called with the lock open on file descriptor 9.
update() {
  local state_file=$1 current='' owner='' target event
  flock -w 2 9 2> /dev/null
  field hook_event_name
  event=$REPLY
  # SessionStart starts from scratch: a --resume must not assume the tab is already neutral.
  [ "$event" != SessionStart ] && [ -f "$state_file" ] && read -r current owner < "$state_file"
  target_state "$current" "$owner"
  target=$REPLY

  if [ -n "$target" ] && [ "$target" != "$current" ] && emit "$target"; then
    # Author of the wait; "any" when the event does not tell.
    case $event in
      Notification | Elicitation) REPLY=any ;;
      *) agent ;;
    esac
    printf '%s %s\n' "$target" "$REPLY" > "$state_file"
    # The toast must not inherit the lock.
    [ -n "${ALERT[$target]:-}" ] && toast "$target" 9>&-
  fi
  # Even when the pty is gone (tab closed): do not leave the state behind.
  [ "$event" = SessionEnd ] && rm -f "$state_file"
}

main() {
  [ -n "${WT_SESSION:-}" ] || return 0
  [ -z "${TMUX:-}" ] || return 0
  # cat rather than read -d '': read consumes a pipe one byte at a time.
  input=$(cat)

  field session_id
  [[ $REPLY =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  local state_dir=${WT_TAB_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/wt-tab-status}
  [ -d "$state_dir" ] || mkdir -m 700 "$state_dir" 2> /dev/null
  [ -O "$state_dir" ] || return 0
  # Hooks of the same turn run in parallel: the lock prevents duplicate bells and toasts.
  update "$state_dir/$REPLY" 9> "$state_dir/.lock"
  return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main
  exit 0
fi
