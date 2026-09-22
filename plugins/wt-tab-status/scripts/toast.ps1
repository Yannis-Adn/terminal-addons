# Toast template for wt-tab-status, run through -EncodedCommand by tab-status.sh,
# which prepends $Kind (waiting | done | error), $DryRun and $Lang. The hook JSON
# arrives on stdin and is read as raw bytes to keep UTF-8 intact (accents, emoji).

# Otherwise PowerShell writes a serialized progress bar (CLIXML) to stderr.
$ProgressPreference = 'SilentlyContinue'

$stdin = [Console]::OpenStandardInput()
$bytes = New-Object System.IO.MemoryStream
$stdin.CopyTo($bytes)
$hook = [Text.Encoding]::UTF8.GetString($bytes.ToArray()) | ConvertFrom-Json

# Language: WT_TAB_STATUS_LANG if set, otherwise the Windows display language.
if (-not $Lang) { $Lang = (Get-UICulture).TwoLetterISOLanguageName }
$text = if ($Lang -eq 'fr') {
    @{
        waiting    = 'Claude vous attend'
        question   = 'Une question attend votre réponse'
        plan       = 'Un plan attend votre validation'
        permission = 'Permission demandée : '
        done       = 'Terminé'
        error      = 'Erreur API'
    }
}
else {
    @{
        waiting    = 'Claude needs you'
        question   = 'A question is waiting for your answer'
        plan       = 'A plan is waiting for your approval'
        permission = 'Permission requested: '
        done       = 'Done'
        error      = 'API error'
    }
}

$project = ("$($hook.cwd)" -split '[\\/]')[-1]

switch ($Kind) {
    'waiting' {
        $title = "🔴 $project — $($text.waiting)"
        if ($hook.tool_name -eq 'AskUserQuestion') { $body = $text.question }
        elseif ($hook.tool_name -eq 'ExitPlanMode') { $body = $text.plan }
        elseif ($hook.tool_name) {
            $body = "$($text.permission)$($hook.tool_name)"
            if ($hook.tool_input.command) { $body += " — $($hook.tool_input.command)" }
        }
        else { $body = "$($hook.message)" }
    }
    'done' {
        $title = "🟢 $project — $($text.done)"
        $body = "$($hook.last_assistant_message)"
    }
    'error' {
        $title = "🟠 $project — $($text.error)"
        $body = if ($hook.error_details) { "$($hook.error_details)" } else { "$($hook.error)" }
    }
}

# Single-line body, without Markdown markers, truncated.
$body = ($body -replace '[*`#]', '' -replace '\s+', ' ').Trim()
if ($body.Length -gt 150) {
    $cut = 149
    # Never split an emoji (UTF-16 surrogate pair) in two.
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
# Silent: the terminal bell already makes the sound.
$audio = $xml.CreateElement('audio')
$audio.SetAttribute('silent', 'true')
$null = $xml.DocumentElement.AppendChild($audio)

$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
# Windows Terminal's AppUserModelID (WT name and icon), falling back to PowerShell's.
foreach ($appId in 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App', '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe') {
    try {
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        break
    }
    catch { }
}
