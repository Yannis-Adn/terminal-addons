# Gabarit du toast wt-tab-status, exécuté via -EncodedCommand par tab-status.sh,
# qui préfixe $Kind (waiting | done | error) et $DryRun. Le JSON du hook arrive
# sur stdin, lu en octets bruts pour préserver l'UTF-8 (accents, emoji).

# Sans ça, PowerShell envoie une barre de progression sérialisée (CLIXML) sur stderr.
$ProgressPreference = 'SilentlyContinue'

$stdin = [Console]::OpenStandardInput()
$bytes = New-Object System.IO.MemoryStream
$stdin.CopyTo($bytes)
$hook = [Text.Encoding]::UTF8.GetString($bytes.ToArray()) | ConvertFrom-Json

$project = ("$($hook.cwd)" -split '[\\/]')[-1]

switch ($Kind) {
    'waiting' {
        $title = "🔴 $project — Claude vous attend"
        if ($hook.tool_name -eq 'AskUserQuestion') { $body = 'Une question attend votre réponse' }
        elseif ($hook.tool_name -eq 'ExitPlanMode') { $body = 'Un plan attend votre validation' }
        elseif ($hook.tool_name) {
            $body = "Permission demandée : $($hook.tool_name)"
            if ($hook.tool_input.command) { $body += " — $($hook.tool_input.command)" }
        }
        else { $body = "$($hook.message)" }
    }
    'done' {
        $title = "🟢 $project — Terminé"
        $body = "$($hook.last_assistant_message)"
    }
    'error' {
        $title = "🟠 $project — Erreur API"
        $body = if ($hook.error_details) { "$($hook.error_details)" } else { "$($hook.error)" }
    }
}

# Corps sur une ligne, sans marqueurs Markdown, tronqué.
$body = ($body -replace '[*`#]', '' -replace '\s+', ' ').Trim()
if ($body.Length -gt 150) {
    $cut = 149
    # Ne pas couper un emoji (paire de substitution UTF-16) en deux.
    if ([char]::IsHighSurrogate($body[$cut - 1])) { $cut-- }
    $body = $body.Substring(0, $cut) + '…'
}

if ($DryRun) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::Out.Write("$title`n$body`n")
    exit 0
}

$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$texts = $xml.GetElementsByTagName('text')
$null = $texts.Item(0).AppendChild($xml.CreateTextNode($title))
$null = $texts.Item(1).AppendChild($xml.CreateTextNode($body))
# Muet : le son vient déjà de la cloche du terminal.
$audio = $xml.CreateElement('audio')
$audio.SetAttribute('silent', 'true')
$null = $xml.DocumentElement.AppendChild($audio)

$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
# AppUserModelID de Windows Terminal (nom et icône de WT), repli sur PowerShell.
foreach ($appId in 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App', '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe') {
    try {
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        break
    }
    catch { }
}
