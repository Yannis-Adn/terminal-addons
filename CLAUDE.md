# terminal-addons

Claude Code plugin marketplace (`.claude-plugin/marketplace.json`), one folder per plugin under `plugins/`. User documentation: `README.md` (English) and `README.fr.md` (French), keep both in sync.

## Commands

- Tests: `bash plugins/wt-tab-status/tests/run.sh`
- Lint: `shellcheck plugins/wt-tab-status/scripts/tab-status.sh plugins/wt-tab-status/tests/run.sh` (must stay clean, CI runs it)
- Validation: `claude plugin validate plugins/wt-tab-status` and `claude plugin validate .`
- Installed plugins are **copies** (`~/.claude/plugins/cache/terminal-addons/wt-tab-status/<version>`): after a change, bump `version` in `plugin.json`, add a `CHANGELOG.md` entry, then `claude plugin marketplace update terminal-addons && claude plugin update wt-tab-status@terminal-addons` and open a new session.

## wt-tab-status: constraints

- Hooks have **no** controlling terminal: `/dev/tty` fails. The script writes to the pty of the first `claude` ancestor (`find_pty`).
- `terminalSequence` (the official hook JSON output) only accepts OSC 0/1/2/9/99/777 and BEL: not DECAC, hence the direct pty write.
- `tab-status.sh`: **never** print to stdout (injected into Claude's context on SessionStart/UserPromptSubmit), **always** exit 0, a single `write()` per state change.
- Pure bash, no `jq`, no Python, no Node.
- Claude Code owns the tab title: the plugin never touches it.
- Tests never write to a real pty: `WT_TAB_STATUS_OUT`, `WT_TAB_STATUS_STATE_DIR`, `WT_TAB_STATUS_TOAST_LOG`, `WT_TAB_STATUS_TOAST_DRYRUN`.
- A new event handled in `target_state` must also be declared in `hooks/hooks.json` and in the consistency test list.
- In tests, any command that reads stdin (`script`, `powershell.exe`) needs `< /dev/null` or a here-string: under Claude Code, stdin is a socket that never closes.
- Hooks of the same turn run in **parallel**: the state is read and written under `flock` (fd 9), and the toast is started with `9>&-` so it does not keep the lock.
- State file: `<state> <author>`. While `waiting`, only tool events from the same agent (`agent_id` or `main`) end the wait, unless the author is `any` (notification).
- Read stdin with `cat`: `read -d ''` reads a pipe one byte at a time (hundreds of ms for large Pre/PostToolUse payloads).
- `toast.ps1`: keep `$ProgressPreference = 'SilentlyContinue'`, otherwise PowerShell writes CLIXML to stderr. Toast strings exist in English and French; add both when adding one.
- Toasts missing on screen but present in the notification center (`Win+N`): that is Windows' Do Not Disturb, not a bug.
- No hook reports an Esc interrupt: only `idle_prompt` releases the tab. Claude never sends it while a dialog is on screen (`isDialogOnScreen`), hence it clears both `working` and `waiting`. Delay: `messageIdleNotifThresholdMs` in `~/.claude.json` (default 60000, undocumented).
