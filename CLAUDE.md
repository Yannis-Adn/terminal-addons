# terminal-addons

Marketplace locale de plugins Claude Code (`.claude-plugin/marketplace.json`), un dossier par plugin dans `plugins/`.

## Commandes

- Tests : `bash plugins/wt-tab-status/tests/run.sh`
- Validation : `claude plugin validate plugins/wt-tab-status` et `claude plugin validate .`
- Le plugin installé est une **copie** (`~/.claude/plugins/cache/terminal-addons/wt-tab-status/<version>`) : après une modification, incrémenter `version` dans `plugin.json`, puis `claude plugin marketplace update terminal-addons && claude plugin update wt-tab-status@terminal-addons`, et ouvrir une nouvelle session.

## wt-tab-status — contraintes à respecter

- Les hooks n'ont **pas** de terminal de contrôle : `/dev/tty` échoue. On écrit dans le pty du premier ancêtre `claude` (`find_pty`).
- `terminalSequence` (sortie JSON officielle des hooks) n'accepte que OSC 0/1/2/9/99/777 et BEL : pas DECAC, d'où l'écriture directe.
- `tab-status.sh` : **jamais** de stdout (injecté dans le contexte de Claude sur SessionStart/UserPromptSubmit), **toujours** code 0, un seul `write()` par changement d'état.
- Bash pur, pas de `jq` (absent de la machine).
- Claude Code gère lui-même le titre de l'onglet : le plugin n'y touche pas.
- Les tests n'écrivent jamais dans un vrai pty : `WT_TAB_STATUS_OUT`, `WT_TAB_STATUS_STATE_DIR`, `WT_TAB_STATUS_TOAST_LOG`, `WT_TAB_STATUS_TOAST_DRYRUN`.
- Nouvel événement géré dans `target_state` → le déclarer aussi dans `hooks/hooks.json` et la liste du test de cohérence.
- Les hooks d'un même tour tournent en **parallèle** : lecture/écriture de l'état sous `flock` (fd 9), et le toast est lancé avec `9>&-` pour ne pas garder le verrou.
- Fichier d'état : `<état> <auteur>` ; pendant `waiting`, seuls les événements d'outil du même agent (`agent_id` ou `main`) lèvent l'attente, sauf auteur `any` (notification).
- Lire stdin avec `cat` : `read -d ''` lit octet par octet (563 ms pour 2 Mo sur chaque Pre/PostToolUse).
- Dans les tests, toute commande qui lit stdin (`script`, `powershell.exe`) doit recevoir `< /dev/null` ou un here-string : sous Claude, stdin est une socket qui ne se ferme jamais.
- `toast.ps1` : garder `$ProgressPreference = 'SilentlyContinue'`, sinon PowerShell pollue stderr avec du CLIXML.
- Toasts invisibles alors qu'ils sont dans le centre de notifications (Win+N) : c'est le mode « Ne pas déranger » de Windows, pas un bug.
- Aucun hook ne signale une interruption (Échap) : seul `idle_prompt` libère l'onglet. Claude ne l'envoie jamais pendant une boîte de dialogue (`isDialogOnScreen`), d'où la sortie de `working` **et** de `waiting`. Délai : `messageIdleNotifThresholdMs` dans `~/.claude.json` (réglé à 5000 sur cette machine, défaut 60000, clé non documentée).

