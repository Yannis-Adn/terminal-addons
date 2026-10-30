# terminal-addons

Claude Code plugin marketplace (`.claude-plugin/marketplace.json`), one folder per plugin under `plugins/`. User documentation: `README.md` (English) and `README.fr.md` (French), keep both in sync.

## Commands

- Tests: `bash plugins/wt-tab-status/tests/run.sh` and `claude plugin test plugins/pinned-prompt` (the latter needs the Claude Code CLI, so CI does not run it)
- Lint: `shellcheck plugins/wt-tab-status/scripts/tab-status.sh plugins/wt-tab-status/tests/run.sh` (must stay clean, CI runs it)
- Validation: `claude plugin validate plugins/<plugin>` and `claude plugin validate .`
- Installed from this folder (a local marketplace), a plugin is read from the folder itself (`claude plugin list` shows `Read from:`): `/reload-plugins` in a session picks up a change. A release still bumps `version` in `plugin.json` and adds a `CHANGELOG.md` entry: installs from GitHub are cached copies.

## pinned-prompt: constraints

- A Claude Code hooks module (`hooks/register.tsx`, early-access plugin API), not shell hooks: no Node, no DOM, everything goes through `$`. The API's types are written by the engine into `.claude-plugin/types/` (git-ignored); `claude plugin validate` and `claude plugin test` check the module.
- State lives in `$.state` (contract in `types/index.d.ts`), never in module variables: a reload resets those. A `ui.render` hook never writes state; handlers use `update`.
- Labels exist in English and French (`LABELS`); add both when adding one. The language comes from Claude Code's `language` setting.
- Only the `📌 You ▸` pin is a `Button`: the message text must stay selectable for copying.

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
