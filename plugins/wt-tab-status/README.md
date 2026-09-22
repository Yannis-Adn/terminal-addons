# wt-tab-status

L'onglet Windows Terminal reflète l'état de Claude Code (WSL) :

| État | Fond d'onglet | Anneau | Alertes |
|---|---|---|---|
| Neutre (session ouverte, fermée) | couleur du profil | — | — |
| En cours | bleu | tourne | — |
| Vous attend (permission, question, plan) | rouge | plein (barre des tâches jaune) | cloche + toast |
| Terminé | vert | — | cloche + toast |
| Erreur API | orange | plein (barre des tâches rouge) | cloche + toast |

## Installation

```
/plugin marketplace add /path/to/terminal-addons
/plugin install wt-tab-status@terminal-addons
```

Dans le `settings.json` de Windows Terminal, pour l'icône 🔔 et le clignotement
de la barre des tâches en plus du son :

```json
"profiles": { "defaults": { "bellStyle": ["audible", "taskbar"] } }
```

Toasts et mode « Ne pas déranger » : les toasts arrivent dans le centre de
notifications, mais leur bannière est masquée tant que « Ne pas déranger » est
actif. Pour les laisser passer : Paramètres Windows → Système → Notifications →
Définir les notifications prioritaires → Ajouter des applications → Terminal.

## Fonctionnement

Tous les hooks appellent `scripts/tab-status.sh`, qui écrit directement dans le
pty de Claude (trouvé en remontant `/proc` jusqu'au processus `claude`) :
DECAC pour le fond d'onglet, OSC 9;4 pour l'anneau, BEL pour la cloche. Les
hooks n'ont pas de `/dev/tty`, et le champ officiel `terminalSequence` refuse
DECAC. Le toast passe par `powershell.exe` en arrière-plan (`scripts/toast.ps1`).

## Limites

- Échap (pendant le travail ou sur une question) : aucun hook ne le signale → l'onglet
  reste bleu ou rouge jusqu'à la notification `idle_prompt`, puis redevient neutre.
  Délai par défaut 60 s ; réglable (clé non documentée) dans `~/.claude.json` :
  `"messageIdleNotifThresholdMs": 5000`.
- Permission accordée : reste rouge jusqu'à la fin de l'outil.
- Pas de tmux ; `claude -p` et le SDK n'affectent pas l'onglet.
- Claude tué brutalement : la couleur reste jusqu'à la prochaine session Claude dans l'onglet.

## Tests

```
bash plugins/wt-tab-status/tests/run.sh
```
