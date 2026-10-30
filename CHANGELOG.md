# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## pinned-prompt

### [0.1.0] - 2026-10-30

#### Added
- First version: your last message in a framed band above the prompt. Clicking `📌 You ▸` unfolds your last five messages, the latest in full.
- The band is filled from the transcript when a session is resumed, and emptied by `/clear`.
- Labels in English or French, following Claude Code's `language` setting.

## wt-tab-status

### [0.3.0] - 2026-09-22

#### Added
- Toasts in English or French, following the Windows display language; `WT_TAB_STATUS_LANG` forces one.
- CI: ShellCheck, JSON manifest validation and the test suite on every push.

#### Changed
- Code comments and documentation in English, with a French README.

### [0.2.1] - 2026-09-22

#### Fixed
- The end of the main turn no longer clears a pending request from a background subagent.

### [0.2.0] - 2026-09-22

#### Changed
- Only background agents (subagents, workflows, teammates, cloud sessions) keep the tab blue after a turn. Background shells and monitors, such as dev servers, no longer prevent "done".
- Permission requests from subagents rely on the permission notification (~6 s), since background subagents fire the permission hook for requests they cannot show.
- `idle_prompt` also releases the red tab after Esc on a question.

#### Fixed
- Tools run by a parallel subagent no longer clear the main thread's pending request.
- Concurrent hooks no longer ring the bell or send a toast twice (state updated under `flock`).
- Auto-compaction no longer resets the tab to neutral in the middle of a turn.
- `/resume` always resets the tab color left by a previous session.
- The state file is removed at session end even when the tab is already closed.
- Toast bodies no longer split an emoji; API error toasts show the readable error details.
- Large hook payloads are read in milliseconds instead of hundreds of milliseconds.

### [0.1.0] - 2026-09-22

#### Added
- First version: tab color (DECAC), progress ring (OSC 9;4), bell and Windows toast for the working, needs-you, done and API error states.
