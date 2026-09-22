# wt-tab-status

Windows Terminal tabs that mirror Claude Code's state (Claude Code running in WSL).

| State | Tab | Ring | Bell + toast |
|---|---|---|---|
| Neutral (session start / end) | profile color | — | — |
| Working | blue | spinning | — |
| Needs you (permission, question, plan) | red | full (yellow taskbar) | ✅ |
| Done | green | — | ✅ |
| API error | orange | full (red taskbar) | ✅ |

```
/plugin marketplace add Yannis-Adn/terminal-addons
/plugin install wt-tab-status@terminal-addons
```

Full documentation (settings, how it works, limitations): see the [repository README](../../README.md) ([français](../../README.fr.md)).
