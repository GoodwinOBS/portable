$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════
# Кириллица: принудительный UTF-8
# ═══════════════════════════════════════════════════
# PowerShell 5.1 по умолчанию ЧИТАЕТ текстовые файлы в системной ANSI-кодировке
# (cp1251/cp1252/…), а НЕ в UTF-8. Конфиги OBS (basic.ini, user.ini, JSON сцен)
# и значения с кириллицей (никнейм, путь записи) хранятся в UTF-8 — поэтому без
# явного UTF-8 при чтении русские буквы превращаются в «кракозябры» (фыва→С„РІ…),
# а двойная перезапись закрепляет их в файле. Включаем UTF-8 по умолчанию для
# чтения и для консоли, чтобы кириллица в путях и никнеймах не ломалась.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false) } catch {}
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'

# ═══════════════════════════════════════════════════
# Win32 API: скрытие консольного окна
# ═══════════════════════════════════════════════════
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    public const int SW_MINIMIZE = 6;
    public const int WM_SETICON  = 0x0080;
    public const int ICON_SMALL  = 0;
    public const int ICON_BIG    = 1;
    public static void MinimizeConsole() {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero) ShowWindow(h, SW_MINIMIZE);
    }
    public static void SetConsoleIcon(IntPtr hIcon) {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero && hIcon != IntPtr.Zero) {
            SendMessage(h, WM_SETICON, (IntPtr)ICON_SMALL, hIcon);
            SendMessage(h, WM_SETICON, (IntPtr)ICON_BIG,   hIcon);
        }
    }
}
'@ -ErrorAction SilentlyContinue

# ── AppUserModelID: без этого Windows ставит на taskbar иконку powershell.exe.
# Должен быть вызван ДО создания любого окна (формы или консоли).
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class WinAppId {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void SetCurrentProcessExplicitAppUserModelID(
        [MarshalAs(UnmanagedType.LPWStr)] string AppID);
}
'@ -ErrorAction SilentlyContinue
try { [WinAppId]::SetCurrentProcessExplicitAppUserModelID('Goodwin.OBS.App') } catch {}

# Глобальный флаг: идёт загрузка (блокирует закрытие окна)
$script:IsUploading = $false
# Глобальный флаг: любая операция (reentrancy guard)
$script:IsBusy = $false

# Загружаем System.Net.Http один раз (для chunked upload)
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$script:GoodwinBootstrapLogFile = Join-Path $env:APPDATA 'goodwin_obs\goodwin_obs.log'
$script:GoodwinBootstrapScriptUrl = 'https://raw.githubusercontent.com/GoodwinOBS/portable/main/start.ps1'

function Write-GoodwinBootstrapLog {
    param([string] $Message)
    try {
        $dir = Split-Path -Parent $script:GoodwinBootstrapLogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
        Add-Content -Path $script:GoodwinBootstrapLogFile -Value $line -Encoding UTF8
    }
    catch {}
}

# Проверка STA-режима для WinForms и прав администратора.
function Test-GoodwinAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([AllowNull()][string] $Value)
    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Save-GoodwinRestartScript {
    param([Parameter(Mandatory = $true)][string] $ScriptPath)

    Write-GoodwinBootstrapLog "Bootstrap: downloading restart script from $script:GoodwinBootstrapScriptUrl"
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $wc = New-Object Net.WebClient
    $wc.Encoding = New-Object System.Text.UTF8Encoding($false)
    $scriptContent = $wc.DownloadString($script:GoodwinBootstrapScriptUrl)
    if ([string]::IsNullOrWhiteSpace($scriptContent)) {
        throw 'Downloaded restart script is empty.'
    }
    $scriptContent = $scriptContent.TrimStart([char]0xFEFF)
    [IO.File]::WriteAllText($ScriptPath, $scriptContent, (New-Object System.Text.UTF8Encoding($true)))
    Write-GoodwinBootstrapLog "Bootstrap: restart script saved to $ScriptPath"
}

function Start-GoodwinRestart {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [bool] $Elevated
    )

    $scriptLiteral = ConvertTo-PowerShellSingleQuotedLiteral $ScriptPath
    $goodwinKey = [Environment]::GetEnvironmentVariable('GOODWIN_OBS_KEY', 'Process')
    if ([string]::IsNullOrEmpty($goodwinKey)) {
        $command = "& $scriptLiteral"
    } else {
        $keyLiteral = ConvertTo-PowerShellSingleQuotedLiteral $goodwinKey
        $command = "`$env:GOODWIN_OBS_KEY = $keyLiteral; & $scriptLiteral"
    }

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
    Write-GoodwinBootstrapLog "Bootstrap: launching restart elevated=$Elevated script=$ScriptPath"
    if ($Elevated) {
        Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Minimized -ArgumentList $arguments
    } else {
        Start-Process -FilePath powershell.exe -WindowStyle Minimized -ArgumentList $arguments
    }
}

$needsSta = ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA')
$needsAdmin = -not (Test-GoodwinAdministrator)
Write-GoodwinBootstrapLog "Bootstrap: pid=$PID admin=$(-not $needsAdmin) sta=$(-not $needsSta)"
if ($needsSta -or $needsAdmin) {
    $restartScriptPath = $PSCommandPath
    if (-not $restartScriptPath) { $restartScriptPath = $MyInvocation.MyCommand.Path }
    if (-not $restartScriptPath -and (Get-Variable -Name scriptPath -Scope Local -ErrorAction SilentlyContinue)) {
        $candidateScriptPath = (Get-Variable -Name scriptPath -Scope Local -ErrorAction SilentlyContinue).Value
        if ($candidateScriptPath -and (Test-Path -LiteralPath $candidateScriptPath)) {
            $restartScriptPath = $candidateScriptPath
        }
    }
    if (-not $restartScriptPath) {
        # Запуск через irm | iex — сохраняем скрипт в штатную директорию.
        $restartDir = Join-Path $env:USERPROFILE 'Downloads\GoodwinOBS'
        New-Item -ItemType Directory -Force -Path $restartDir | Out-Null
        $restartScriptPath = Join-Path $restartDir 'goodwin_obs.ps1'
        Save-GoodwinRestartScript -ScriptPath $restartScriptPath
    }
    if (Test-Path -LiteralPath $restartScriptPath) {
        try {
            Write-GoodwinBootstrapLog "Bootstrap: restart required needsAdmin=$needsAdmin needsSta=$needsSta"
            Start-GoodwinRestart -ScriptPath $restartScriptPath -Elevated $needsAdmin
            exit
        }
        catch {
            Write-GoodwinBootstrapLog "Bootstrap: restart failed: $($_.Exception.Message)"
            Write-Host "Goodwin OBS restart failed: $($_.Exception.Message)"
            exit 1
        }
    } else {
        Write-Host 'Запустите скрипт от имени администратора в STA-режиме: powershell -STA -ExecutionPolicy Bypass -File goodwin_obs.ps1'
        exit
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Скрипт работает открыто: без скрытых окон, без зашифрованных или обфусцированных
# блоков, без изменения настроек антивируса. Настройки OBS скачиваются из GoodwinOBS/portable.
# Dropbox access token получается через официальный OAuth API; для публичной
# раздачи скрипта лучше вынести OAuth-секреты и refresh token на сервер.
# ─────────────────────────────────────────────────────────────────────────────

# Dropbox OAuth: значения зашифрованы и расшифровываются ключом из GOODWIN_OBS_KEY.
$script:DropboxOAuthEncrypted = @{
    k = 'v1:e4lHo3yR7K+epx0VWmli+Q==:LCWV7f4lquLsxhNQckm6kQ==:uWbp9RS6lMSrwibtodMPhQ=='
    s = 'v1:xXugp2z9JVGHXuGEeo0SNQ==:YfFlAXKN1cjZ5ks+0isK4A==:pWV7bOiPNoKEs4eVusFZOw=='
    r = 'v1:OTds3siySL+CqvtN5ae54w==:4uwtfoxil3wVVavGaCSmjQ==:X76yvUwQxErfKqRpEBV9uNTQeU3P+wNJStS0FgADH4d+gss5e2OqonWo5rMyeew9Vk+Fz0Eaz6KUW29qf79JrLKRCoIG/38RFh1oVOmH2YU='
}
$script:DropboxOAuthConfig = $null
$script:DropboxRuntimeRefreshToken = $null
$DropboxUploadFolderPath = '/Goodwin'

# ── Пути установки, записи и локального хранилища ────────────────────────────
$InstallDir               = Join-Path $env:USERPROFILE 'Downloads\GoodwinOBS'
$script:RecordingRoot     = Join-Path $env:USERPROFILE 'Downloads\goodwin_record'
$script:RecordingDir      = $script:RecordingRoot
$script:SettingsFile      = Join-Path $env:APPDATA 'goodwin_obs\settings.json'
$script:UploadHistoryFile = Join-Path $env:APPDATA 'goodwin_obs\uploaded.json'
$script:LogFile           = Join-Path $env:APPDATA 'goodwin_obs\goodwin_obs.log'
$script:UploadProgressActive = $false
$script:DebugVersion = 'debug-2026-07-03.1'
$ObsApiUrl = 'https://api.github.com/repos/obsproject/obs-studio/releases/latest'
$TempRoot = Join-Path $InstallDir '.tmp_install'
$script:PortableRepoOwner = 'GoodwinOBS'
$script:PortableRepoName = 'portable'
$script:PortableRepoBranch = 'main'
$script:PortableAssetsDirName = 'assets'
$script:PortableProfilesFile = 'profiles.txt'
# Прогресс загрузки: одна строка состояния на каждый параллельно загружаемый
# файл в памяти; агрегированный прогресс выводится в нижнюю строку состояния.
# $script:MultiProgressState: [ordered]@{ FileName -> @{ Uploaded; Total; Status } }
$script:MultiProgressState = $null
$script:MultiProgressLineCount = 0
$script:RecentActivity = New-Object System.Collections.Generic.List[string]

function Add-LogFileLine {
    param([string] $Line)
    try {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Add-Content -Path $script:LogFile -Value $Line -Encoding UTF8
    }
    catch {
        # Лог не должен ломать основную работу приложения.
    }
}

function Format-UiText {
    param([string] $Text, [int] $MaxLength = 92)
    if ($null -eq $Text) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return ($clean.Substring(0, [math]::Max(0, $MaxLength - 3)) + '...')
}

function Refresh-ActivityUi {
    if (-not $script:ActivityLabels) { return }
    for ($i = 0; $i -lt $script:ActivityLabels.Count; $i++) {
        $label = $script:ActivityLabels[$i]
        if (-not $label) { continue }
        if ($i -lt $script:RecentActivity.Count) {
            $label.Text = Format-UiText $script:RecentActivity[$i] 86
            $label.ForeColor = if ($i -eq 0) {
                [System.Drawing.Color]::FromArgb(238, 242, 247)
            } else {
                [System.Drawing.Color]::FromArgb(154, 164, 178)
            }
        } else {
            $label.Text = ''
        }
    }
}

function Add-ActivityItem {
    param([string] $Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $script:RecentActivity.Insert(0, $Message)
    while ($script:RecentActivity.Count -gt 6) {
        $script:RecentActivity.RemoveAt($script:RecentActivity.Count - 1)
    }
    Refresh-ActivityUi
}

function Set-UploadProgressUi {
    param(
        [int] $Percent,
        [string] $Title,
        [string] $Detail,
        [string[]] $Rows
    )

    $text = "{0}: {1}% — {2}" -f $Title, ([math]::Min(100, [math]::Max(0, $Percent))), $Detail
    $color = if ($Percent -ge 100) { 'Green' } else { 'Yellow' }
    Set-Status (Format-UiText $text 132) $color
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function Clear-UploadProgress {
    $script:MultiProgressLineCount = 0
    $script:MultiProgressState = $null
    $script:UploadProgressActive = $false
}

function Initialize-MultiProgress {
    param([string[]] $Names)
    $script:MultiProgressState = [ordered]@{}
    foreach ($n in $Names) {
        $script:MultiProgressState[$n] = @{ Uploaded = 0L; Total = 0L; Status = 'pending' }
    }
    $script:MultiProgressLineCount = 0
    $script:UploadProgressActive = $true
    Update-MultiProgressRender -Force
}

function Write-Step {
    param([string] $Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Message"
    Write-Host "[goodwin_obs] $Message"
    Add-LogFileLine $line
    Add-ActivityItem $Message
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

# Технический лог — пишется в файл и консоль PowerShell, не в основной GUI.
# Используется внутри install/setup функций, чтобы не засорять интерфейс.
function Write-Log {
    param([string] $Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Message"
    Write-Host $line
    Add-LogFileLine $line
}

# Подробный отчёт об ошибке пишется в файл и консоль. В интерфейсе остаётся
# короткая понятная строка, полный блок доступен через кнопку «Логи».
function Write-ErrorDetails {
    param(
        [string] $Context,
        $ErrorRecord
    )
    if (-not $ErrorRecord) { return }

    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('═══ ОШИБКА — скопируйте этот блок ═══')
    if ($Context) { [void]$sb.AppendLine("Этап:    $Context") }
    if ($ex) {
        [void]$sb.AppendLine("Тип:     $($ex.GetType().FullName)")
        [void]$sb.AppendLine("Сообщ.:  $($ex.Message)")
        if ($ex.HResult)    { [void]$sb.AppendLine("HResult: 0x$($ex.HResult.ToString('X8'))") }
    }
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $inv = $ErrorRecord.InvocationInfo
        if ($inv) {
            if ($inv.ScriptName)        { [void]$sb.AppendLine("Скрипт:  $($inv.ScriptName):$($inv.ScriptLineNumber)") }
            elseif ($inv.ScriptLineNumber) { [void]$sb.AppendLine("Строка:  $($inv.ScriptLineNumber)") }
            if ($inv.Line)              { [void]$sb.AppendLine("Код:     $($inv.Line.Trim())") }
            if ($inv.PositionMessage)   { [void]$sb.AppendLine($inv.PositionMessage) }
        }
        if ($ErrorRecord.CategoryInfo)   { [void]$sb.AppendLine("Кат.:    $($ErrorRecord.CategoryInfo)") }
    }
    # Inner exception chain
    $inner = if ($ex) { $ex.InnerException } else { $null }
    $depth = 0
    while ($inner -and $depth -lt 5) {
        [void]$sb.AppendLine("Внутр.($depth): $($inner.GetType().FullName): $($inner.Message)")
        $inner = $inner.InnerException
        $depth++
    }
    # Stack trace (truncate to first 12 lines for readability; full goes to console)
    if ($ex -and $ex.StackTrace) {
        $lines = $ex.StackTrace -split "`r?`n" | Where-Object { $_ }
        $shown = $lines | Select-Object -First 12
        [void]$sb.AppendLine('Стек:')
        foreach ($ln in $shown) { [void]$sb.AppendLine('  ' + $ln.Trim()) }
        if ($lines.Count -gt 12) { [void]$sb.AppendLine("  …ещё $($lines.Count - 12) строк (см. файл логов)") }
    }
    [void]$sb.AppendLine('═══════════════════════════════════════')
    $text = $sb.ToString().TrimEnd()

    Add-LogFileLine ''
    Add-LogFileLine $text
    if ($ex -and $ex.StackTrace) { Add-LogFileLine $ex.StackTrace }
    Add-LogFileLine ''

    Write-Host ''
    Write-Host $text -ForegroundColor Red
    if ($ex -and $ex.StackTrace) { Write-Host $ex.StackTrace -ForegroundColor DarkGray }
    Write-Host ''

    Add-ActivityItem ("Ошибка: " + $(if ($Context) { $Context } else { $ex.Message }))
}

$script:LastMultiRenderTicks = 0

function Update-MultiProgressRender {
    # Обновляет агрегированный прогресс загрузки в нижней строке состояния.
    param([switch] $Force)
    if (-not $script:MultiProgressState -or $script:MultiProgressState.Count -eq 0) { return }

    if (-not $Force) {
        if ($null -eq $script:LastMultiRenderTicks) { $script:LastMultiRenderTicks = 0 }
        if (([Environment]::TickCount - $script:LastMultiRenderTicks) -lt 140) { return }
    }
    $script:LastMultiRenderTicks = [Environment]::TickCount

    $totalAll = 0L
    $upAll    = 0L
    $doneCnt  = 0
    $errorCnt = 0
    $rows = New-Object System.Collections.Generic.List[string]

    foreach ($name in $script:MultiProgressState.Keys) {
        $st = $script:MultiProgressState[$name]
        $u = [long]$st.Uploaded
        $t = [long]$st.Total
        $totalAll += $t
        $upAll    += $u
        if ($st.Status -eq 'done')  { $doneCnt++ }
        if ($st.Status -eq 'error') { $doneCnt++; $errorCnt++ }

        $pct = if ($t -gt 0) { [math]::Min(100, [math]::Floor($u * 100.0 / $t)) } else { 0 }
        $tag = switch ($st.Status) {
            'done'  { 'Готово' }
            'error' { 'Ошибка' }
            default { 'Загрузка' }
        }
        $rows.Add(("{0}%  {1}  {2}" -f $pct, $tag, $name))
    }

    $aggPct = if ($totalAll -gt 0) { [math]::Min(100, [math]::Floor($upAll * 100.0 / $totalAll)) } else { 0 }
    $uploadedGb = [math]::Round($upAll / 1GB, 2)
    $totalGb = [math]::Round($totalAll / 1GB, 2)
    $detail = "Файлы: $doneCnt/$($script:MultiProgressState.Count), объём: $uploadedGb/$totalGb ГБ"
    if ($errorCnt -gt 0) { $detail += ", ошибок: $errorCnt" }

    if ($script:StatusLabel_ref) {
        $script:StatusLabel_ref.Text = "НЕ ЗАКРЫВАЙТЕ ОКНО. Загрузка ($doneCnt/$($script:MultiProgressState.Count)): $aggPct%"
    }
    Set-UploadProgressUi -Percent $aggPct -Title 'Идёт загрузка записей' -Detail $detail -Rows $rows.ToArray()
}

function Show-UploadProgress {
    # Совместимость со старым API: одиночный файл — это просто словарь из одного элемента
    param([string] $FileName, [long] $Uploaded, [long] $Total, [string] $Status = 'active')
    if (-not $script:MultiProgressState) {
        Initialize-MultiProgress -Names @($FileName)
    }
    if ($script:MultiProgressState.Contains($FileName)) {
        $script:MultiProgressState[$FileName].Uploaded = $Uploaded
        $script:MultiProgressState[$FileName].Total    = $Total
        $script:MultiProgressState[$FileName].Status   = $Status
    } else {
        $script:MultiProgressState[$FileName] = @{ Uploaded = $Uploaded; Total = $Total; Status = $Status }
    }
    # Финальные состояния файла рисуем сразу (минуя троттлинг), активные — троттлятся.
    if ($Status -eq 'done' -or $Status -eq 'error') {
        Update-MultiProgressRender -Force
    } else {
        Update-MultiProgressRender
    }
}

function Ensure-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $OutFile
    )

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $wc = $null
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'goodwin_obs-portable-installer')
            $lastProgressTick = 0
            $lastProgressPct = -1
            $wc.add_DownloadProgressChanged({
                param($sender, $eventArgs)
                try {
                    $pct = [int]$eventArgs.ProgressPercentage
                    $nowTick = [Environment]::TickCount
                    if ($pct -eq $lastProgressPct -and (($nowTick - $lastProgressTick) -lt 300)) { return }
                    $lastProgressTick = $nowTick
                    $lastProgressPct = $pct

                    $receivedMb = [math]::Round([double]$eventArgs.BytesReceived / 1MB, 1)
                    if ($eventArgs.TotalBytesToReceive -gt 0) {
                        $totalMb = [math]::Round([double]$eventArgs.TotalBytesToReceive / 1MB, 1)
                        Set-Status ("Скачиваем OBS Studio: {0}% ({1} / {2} МБ)" -f $pct, $receivedMb, $totalMb) 'Yellow'
                    } else {
                        Set-Status ("Скачиваем OBS Studio: {0} МБ" -f $receivedMb) 'Yellow'
                    }
                }
                catch {}
            })

            $task = $wc.DownloadFileTaskAsync($Uri, $OutFile)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $timeoutSec = 1200   # 20 минут на попытку — страховка от зависшего соединения без RST
            while (-not $task.IsCompleted) {
                try { [System.Windows.Forms.Application]::DoEvents() } catch {}
                Start-Sleep -Milliseconds 100
                if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) {
                    try { $wc.CancelAsync() } catch {}
                    throw "Таймаут скачивания ($timeoutSec с) — соединение зависло."
                }
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
            Set-Status 'Установка OBS...' 'Yellow'
            return
        }
        catch {
            if ($attempt -eq $maxAttempts) { throw }
            $delay = [math]::Min(30, [math]::Pow(2, $attempt))
            Write-Log "Ошибка скачивания (попытка $attempt/$maxAttempts): $($_.Exception.Message). Повтор через $delay с."
            Start-Sleep -Seconds $delay
        }
        finally {
            if ($wc) { $wc.Dispose() }
        }
    }
}


function Get-LatestObsZipUrl {
    Write-Log 'Ищем последнюю версию OBS Studio...'
    $headers = @{ 'User-Agent' = 'goodwin_obs-portable-installer' }
    $release = Invoke-RestMethod -Uri $ObsApiUrl -Headers $headers

    $asset = $release.assets |
        Where-Object { $_.name -match '^OBS-Studio-.+-Windows-x64\.zip$' -and $_.name -notmatch 'PDB' } |
        Select-Object -First 1

    if (-not $asset) {
        throw 'Не удалось найти OBS Studio x64 ZIP в последнем релизе.'
    }

    Write-Log ("Найден файл: {0}" -f $asset.name)
    return $asset.browser_download_url
}

function Get-SteamLibraryPaths {
    $paths = @()
    try {
        $steamBase = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        if ($steamBase -and (Test-Path $steamBase)) {
            $paths += $steamBase
            # Parse libraryfolders.vdf for additional library roots
            $vdf = Join-Path $steamBase 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                Get-Content $vdf | ForEach-Object {
                    if ($_ -match '"path"\s+"(.+?)"') {
                        $p = $Matches[1] -replace '\\\\', '\'
                        if (Test-Path $p) { $paths += $p }
                    }
                }
            }
        }
    } catch {}
    return $paths
}

function Get-InstalledObsDir {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'obs-studio'),
        (Join-Path ${env:ProgramFiles(x86)} 'obs-studio')
    )

    # Steam OBS locations
    foreach ($lib in (Get-SteamLibraryPaths)) {
        $candidates += Join-Path $lib 'steamapps\common\OBS Studio'
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $candidateExe = Join-Path $candidate 'bin\64bit\obs64.exe'
        if (Test-Path $candidateExe) {
            Write-Log "Найден OBS: $candidate"
            return $candidate
        }
    }

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio'
    )

    foreach ($registryPath in $registryPaths) {
        if (-not (Test-Path $registryPath)) { continue }
        $installLocation = (Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue).InstallLocation
        if ([string]::IsNullOrWhiteSpace($installLocation)) { continue }
        $candidateExe = Join-Path $installLocation 'bin\64bit\obs64.exe'
        if (Test-Path $candidateExe) {
            Write-Log "Найден OBS (реестр): $installLocation"
            return $installLocation
        }
    }

    return $null
}

function Install-ObsPortable {
    param([switch]$ForceDownload)
    Write-Step 'Устанавливаем OBS Studio'
    $obsExe = Join-Path $InstallDir 'bin\64bit\obs64.exe'
    if (Test-Path $obsExe) {
        Write-Log "OBS уже установлен: $InstallDir"
        return
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $installedObsDir = Get-InstalledObsDir
    if ($installedObsDir -and -not $ForceDownload) {
        $candidateExe = Join-Path $installedObsDir 'bin\64bit\obs64.exe'
        try {
            $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($candidateExe).ProductVersion
            Write-Log "Найден установленный OBS версии $ver"
            # Требуем минимум 32.0
            $verNum = [version]($ver.Split(' ')[0])
            if ($verNum -lt [version]'32.0') {
                Write-Log "Версия OBS слишком старая ($ver), будет скачана новая."
                $installedObsDir = $null
            }
        } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($installedObsDir) -and -not $ForceDownload) {
        Write-Log "Копируем OBS из $installedObsDir в $InstallDir"
        Copy-Item -Path (Join-Path $installedObsDir '*') -Destination $InstallDir -Recurse -Force

        if (-not (Test-Path $obsExe)) {
            throw "Файл OBS не найден после копирования: $obsExe"
        }

        return
    }

    $obsZipUrl = Get-LatestObsZipUrl
    $obsZip = Join-Path $TempRoot 'obs.zip'

    if ($script:StatusLabel_ref) { Set-Status 'Скачиваем OBS Studio — это может занять несколько минут...' 'Yellow' }
    Write-Log 'Скачиваем OBS Studio...'
    Invoke-Download -Uri $obsZipUrl -OutFile $obsZip

    Write-Log "Распаковываем OBS в $InstallDir"
    Expand-Archive -Path $obsZip -DestinationPath $InstallDir -Force

    if (-not (Test-Path $obsExe)) {
        throw "Файл OBS не найден после распаковки: $obsExe"
    }

    # Проверка целостности: официальные сборки OBS подписаны Authenticode.
    # Невалидная подпись — повод насторожиться (подмена на зеркале / MITM).
    # Не прерываем установку жёстко, но явно предупреждаем.
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $obsExe
        if ($sig.Status -eq 'Valid') {
            Write-Log "Подпись obs64.exe подтверждена: $($sig.SignerCertificate.Subject)"
        } else {
            Write-Log "⚠ Подпись obs64.exe НЕ подтверждена (Status=$($sig.Status)) — возможна подмена дистрибутива."
            if ($script:StatusLabel_ref) { Set-Status '⚠ Подпись OBS не подтверждена — будьте внимательны' 'Yellow' }
        }
    }
    catch {
        Write-Log "Не удалось проверить подпись obs64.exe: $($_.Exception.Message)"
    }
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextFileAtomic {
    # Атомарная запись текста БЕЗ BOM: пишем во временный файл и заменяем целевой,
    # чтобы аварийная остановка в момент записи не оставила усечённый/битый файл.
    # BOM критичен: с ним OBS не распознаёт первую секцию basic.ini/user.ini.
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Content, $script:Utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        # ВАЖНО: в PowerShell 5.1 / .NET Framework File.Replace с backup-аргументом
        # $null бросает "The path is not of a legal form". Поэтому передаём временный
        # backup-файл и тут же его удаляем. На случай иных сбоев — фолбэк копированием.
        $bak = "$Path.bak"
        try {
            [IO.File]::Replace($tmp, $Path, $bak)
        }
        catch {
            [IO.File]::Copy($tmp, $Path, $true)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        finally {
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
        }
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

function Write-BytesFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    if (Test-Path -LiteralPath $Path) {
        $bak = "$Path.bak"
        try {
            [IO.File]::Replace($tmp, $Path, $bak)
        }
        catch {
            [IO.File]::Copy($tmp, $Path, $true)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        finally {
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
        }
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

function Write-LinesFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $Lines
    )
    Write-TextFileAtomic -Path $Path -Content (($Lines -join "`r`n") + "`r`n")
}

function Get-GitHubRawPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return (($Path -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
}

function Get-PortableRepoFiles {
    $headers = @{ 'User-Agent' = 'goodwin_obs-portable-installer' }
    $treeUrl = "https://api.github.com/repos/$script:PortableRepoOwner/$script:PortableRepoName/git/trees/$script:PortableRepoBranch`?recursive=1"

    try {
        $tree = Invoke-RestMethod -Uri $treeUrl -Headers $headers
    }
    catch {
        throw "Не удалось получить список файлов GoodwinOBS/portable: $($_.Exception.Message)"
    }

    $files = @($tree.tree | Where-Object {
        $_.type -eq 'blob' -and
        -not [string]::IsNullOrWhiteSpace($_.path) -and
        ([IO.Path]::GetFileName($_.path) -ne 'start.ps1')
    })

    if (-not $files) {
        throw 'В GoodwinOBS/portable не найдено файлов для установки OBS-настроек'
    }

    return $files
}

function Get-PortableRepoFileBytes {
    param([Parameter(Mandatory = $true)][string] $Path)

    $rawPath = Get-GitHubRawPath -Path $Path
    $uri = "https://raw.githubusercontent.com/$script:PortableRepoOwner/$script:PortableRepoName/$script:PortableRepoBranch/$rawPath"
    $maxAttempts = 4

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $wc = $null
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'goodwin_obs-portable-installer')
            $bytes = $wc.DownloadData($uri)
            return ,$bytes
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                throw "Не удалось скачать $Path из GoodwinOBS/portable: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds ([math]::Min(12, [math]::Pow(2, $attempt)))
        }
        finally {
            if ($wc) { $wc.Dispose() }
        }
    }
}

function Get-PortableAssetFileName {
    param([Parameter(Mandatory = $true)][string] $Path)

    return [IO.Path]::GetFileName(($Path -replace '/', '\'))
}

function ConvertTo-ObsPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return ([IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

function Set-ObsSceneAssetPaths {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][hashtable] $AssetMap
    )

    $changed = $false
    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        foreach ($item in $Object) {
            if (Set-ObsSceneAssetPaths -Object $item -AssetMap $AssetMap) {
                $changed = $true
            }
        }
        return $changed
    }

    foreach ($property in @($Object.PSObject.Properties)) {
        $value = $property.Value

        if ($property.Name -eq 'file' -and $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            $fileName = Get-PortableAssetFileName -Path $value
            if ($AssetMap.ContainsKey($fileName)) {
                $newPath = ConvertTo-ObsPath -Path $AssetMap[$fileName]
                if ($value -ne $newPath) {
                    $property.Value = $newPath
                    $changed = $true
                }
            }
        }
        elseif ($value -and $value -isnot [string]) {
            if (Set-ObsSceneAssetPaths -Object $value -AssetMap $AssetMap) {
                $changed = $true
            }
        }
    }

    return $changed
}

function Install-PortableRepoObsFiles {
    param([Parameter(Mandatory = $true)][string] $ConfigDir)

    Write-Step 'Скачиваем настройки OBS из GoodwinOBS/portable'

    $repoFiles = Get-PortableRepoFiles
    $sceneFiles = @($repoFiles | Where-Object { [IO.Path]::GetExtension($_.path) -ieq '.json' })
    $assetFiles = @($repoFiles | Where-Object {
        [IO.Path]::GetExtension($_.path) -ine '.json' -and
        ([IO.Path]::GetFileName($_.path) -ne $script:PortableProfilesFile)
    })

    if (-not $sceneFiles) {
        throw 'В GoodwinOBS/portable не найдено JSON-файлов сцен'
    }

    $sceneDir = Join-Path $ConfigDir 'basic\scenes'
    $assetsDir = Join-Path $InstallDir $script:PortableAssetsDirName
    New-Item -ItemType Directory -Force -Path $sceneDir | Out-Null
    New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

    $assetMap = @{}
    foreach ($assetFile in $assetFiles) {
        $assetName = Get-PortableAssetFileName -Path $assetFile.path
        if ([string]::IsNullOrWhiteSpace($assetName)) {
            continue
        }
        if ($assetMap.ContainsKey($assetName)) {
            throw "В GoodwinOBS/portable найдено несколько asset-файлов с именем $assetName"
        }

        $targetPath = Join-Path $assetsDir $assetName
        $bytes = Get-PortableRepoFileBytes -Path $assetFile.path
        Write-BytesFileAtomic -Path $targetPath -Bytes $bytes
        $assetMap[$assetName] = $targetPath
    }

    $installedScenes = 0
    foreach ($sceneFile in $sceneFiles) {
        $sceneName = Get-PortableAssetFileName -Path $sceneFile.path
        if ([string]::IsNullOrWhiteSpace($sceneName)) {
            continue
        }

        $sceneBytes = Get-PortableRepoFileBytes -Path $sceneFile.path
        $sceneJsonText = $script:Utf8NoBom.GetString($sceneBytes)
        if ($sceneJsonText.Length -gt 0 -and $sceneJsonText[0] -eq [char]0xFEFF) {
            $sceneJsonText = $sceneJsonText.Substring(1)
        }
        try {
            $sceneJson = $sceneJsonText | ConvertFrom-Json
        }
        catch {
            throw "Файл сцены $($sceneFile.path) повреждён: $($_.Exception.Message)"
        }

        if ($assetMap.Count -gt 0) {
            $null = Set-ObsSceneAssetPaths -Object $sceneJson -AssetMap $assetMap
            $sceneJsonText = $sceneJson | ConvertTo-Json -Depth 100
        }

        $scenePath = Join-Path $sceneDir $sceneName
        Write-TextFileAtomic -Path $scenePath -Content ($sceneJsonText.Trim() + "`r`n")
        $installedScenes++
    }

    if ($installedScenes -le 0) {
        throw 'Не удалось установить ни одного JSON-файла сцены'
    }

    Write-Log "Настройки OBS скачаны из GoodwinOBS/portable: сцен=$installedScenes, assets=$($assetMap.Count), assetsDir=$assetsDir"
}

function ConvertFrom-PortableProfilesText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content)

    if ($Content.Length -gt 0 -and $Content[0] -eq [char]0xFEFF) {
        $Content = $Content.Substring(1)
    }

    $lines = $Content -split '\r?\n', -1
    $entries = New-Object System.Collections.Generic.List[object]
    $i = 0

    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            $i++
            continue
        }

        if ($line -notmatch '^===== FILE (?<path>.+) =====$') {
            throw "Недопустимая строка в $($script:PortableProfilesFile): $line"
        }

        $relativePath = $Matches['path'].Trim()
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            throw "Пустой путь файла в $script:PortableProfilesFile"
        }

        $i++
        $contentLines = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count -and $lines[$i] -ne '===== END FILE =====') {
            $contentLines.Add($lines[$i])
            $i++
        }

        if ($i -ge $lines.Count) {
            throw "Не найден конец блока для профиля $relativePath"
        }

        $entries.Add([pscustomobject]@{
            Path = $relativePath
            Content = ($contentLines -join "`r`n")
        })
        $i++
    }

    if ($entries.Count -le 0) {
        throw "$script:PortableProfilesFile не содержит файлов профилей"
    }

    return $entries.ToArray()
}

function Install-PortableRepoObsProfiles {
    param([Parameter(Mandatory = $true)][string] $ConfigDir)

    $profileRoot = Join-Path $ConfigDir 'basic\profiles'
    New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null

    Write-Step "Скачиваем профили OBS из $script:PortableProfilesFile"

    try {
        $profilesBytes = Get-PortableRepoFileBytes -Path $script:PortableProfilesFile
        $profilesText = $script:Utf8NoBom.GetString($profilesBytes)
        $profileEntries = ConvertFrom-PortableProfilesText -Content $profilesText
        $profileRootFull = [IO.Path]::GetFullPath($profileRoot).TrimEnd('\') + '\'
        $count = 0

        foreach ($entry in $profileEntries) {
            if ([string]::IsNullOrWhiteSpace($entry.Path)) {
                continue
            }

            $relativePath = $entry.Path.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|\\)\.\.(\\|$)') {
                throw "Недопустимый путь в $($script:PortableProfilesFile): $($entry.Path)"
            }

            $targetPath = Join-Path $profileRoot $relativePath
            $targetFull = [IO.Path]::GetFullPath($targetPath)
            if (-not $targetFull.StartsWith($profileRootFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Недопустимый путь в $($script:PortableProfilesFile): $($entry.Path)"
            }

            Write-TextFileAtomic -Path $targetFull -Content ($entry.Content.TrimEnd([char[]]@("`r", "`n")) + "`r`n")
            $count++
        }

        if ($count -le 0) {
            throw "$script:PortableProfilesFile не содержит файлов профилей"
        }

        Write-Log "Профили OBS скачаны из GoodwinOBS/portable/$($script:PortableProfilesFile): $profileRoot ($count файлов)"
    }
    catch {
        throw "Не удалось применить профили OBS из $($script:PortableProfilesFile): $($_.Exception.Message)"
    }
}

function Set-IniValue {
    param(
        [AllowEmptyString()][string[]] $Lines,
        [Parameter(Mandatory = $true)][string] $Section,
        [Parameter(Mandatory = $true)][string] $Key,
        [Parameter(Mandatory = $true)][string] $Value
    )

    $sectionHeader = "[$Section]"
    $sectionIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $sectionHeader) {
            $sectionIndex = $i
            break
        }
    }

    if ($sectionIndex -lt 0) {
        return @($Lines + '' + $sectionHeader + "$Key=$Value")
    }

    $escapedKey = [regex]::Escape($Key)
    $insertIndex = $Lines.Count
    for ($i = $sectionIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[.+\]\s*$') {
            $insertIndex = $i
            break
        }

        if ($Lines[$i] -match "^\s*$escapedKey\s*=") {
            $Lines[$i] = "$Key=$Value"
            return $Lines
        }
    }

    if ($insertIndex -ge $Lines.Count) {
        return @($Lines + "$Key=$Value")
    }

    return @($Lines[0..($insertIndex - 1)] + "$Key=$Value" + $Lines[$insertIndex..($Lines.Count - 1)])
}

function Get-JsonStringProperty {
    param(
        [object] $Object,
        [string] $Name
    )

    if (-not $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) {
        return $null
    }

    $value = $property.Value
    if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
        return $value
    }

    return $null
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [object] $Value
    )

    if (-not $Object) {
        return
    }

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Find-ObsSource {
    param(
        [object] $Object,
        [string] $SourceId
    )

    $found = @()
    if (-not $Object) {
        return $found
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        foreach ($item in $Object) {
            $found += Find-ObsSource -Object $item -SourceId $SourceId
        }
        return $found
    }

    $id = Get-JsonStringProperty -Object $Object -Name 'id'
    if ($id -eq $SourceId) {
        $found += $Object
    }

    foreach ($property in $Object.PSObject.Properties) {
        $value = $property.Value
        if ($value -and $value -isnot [string]) {
            $found += Find-ObsSource -Object $value -SourceId $SourceId
        }
    }

    return $found
}

function Get-WindowsCameraName {
    # Exclude virtual/software cameras (OBS Virtual Camera, ManyCam, etc.)
    $virtualCameraPattern = 'virtual|obs|manycam|splitcam|droidcam|epoccam|iriun|mmhmm|snap camera'

    # 1. DirectShow registry — most reliable source of capture device names
    try {
        $dsPath = 'HKLM:\SOFTWARE\Classes\CLSID\{860BB310-5D01-11d0-BD3B-00A0C911CE86}\Instance'
        if (Test-Path $dsPath) {
            $dsDevices = Get-ChildItem $dsPath -ErrorAction Stop |
                ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).FriendlyName } |
                Where-Object { $_ -and $_ -notmatch $virtualCameraPattern }
            $dsDevice = $dsDevices | Select-Object -First 1
            if ($dsDevice) {
                return $dsDevice
            }
        }
    }
    catch { }

    # 2. WMI PnP — works even when DirectShow registry is missing
    try {
        $devices = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object {
                ($_.PNPClass -match '^(Camera|Image)$' -or $_.Service -match 'usbvideo') -and
                $_.Name -and
                $_.Name -notmatch 'microphone|audio' -and
                $_.Name -notmatch $virtualCameraPattern
            }
        $device = $devices | Select-Object -First 1
        if ($device) {
            return $device.Name
        }
    }
    catch { }

    # 3. Get-PnpDevice — last resort
    try {
        $device = Get-PnpDevice -Class Camera -Status OK -ErrorAction Stop |
            Where-Object { $_.FriendlyName -notmatch $virtualCameraPattern } |
            Select-Object -First 1
        if ($device -and $device.FriendlyName) {
            return $device.FriendlyName
        }
    }
    catch { }

    return $null
}

function Get-MicrophoneDeviceMap {
    # Возвращает [ordered] @{ FriendlyName = MMDeviceId } для активных capture-устройств,
    # читая имя ровно так же, как это делает OBS: через WASAPI (IMMDeviceEnumerator +
    # IPropertyStore::PKEY_Device_FriendlyName). Это даёт "Микрофон (FIFINE K670 Microphone)"
    # вместо общего "Микрофон", который лежит в кешированном реестре.
    $map = [ordered]@{}
    try {
        $entries = [GoodwinCoreAudio.AudioMeter]::EnumerateCaptureDevices()
        foreach ($line in $entries) {
            if (-not $line) { continue }
            $sep = $line.LastIndexOf('|')
            if ($sep -lt 0) { continue }
            $name = $line.Substring(0, $sep)
            $id   = $line.Substring($sep + 1)
            if (-not $name -or -not $id) { continue }
            $key = $name
            $i = 2
            while ($map.Contains($key)) { $key = "$name #$i"; $i++ }
            $map[$key] = $id
        }
    } catch {
        Write-Log "Перечисление микрофонов не удалось: $($_.Exception.Message)"
    }
    return $map
}

function Get-MicrophoneDeviceIdByName {
    param([string]$FriendlyName)
    if ([string]::IsNullOrWhiteSpace($FriendlyName)) { return 'default' }
    $map = Get-MicrophoneDeviceMap
    if ($map.Contains($FriendlyName)) { return $map[$FriendlyName] }
    $hit = $map.Keys | Where-Object { $_ -like "*$FriendlyName*" } | Select-Object -First 1
    if ($hit) { return $map[$hit] }
    return 'default'
}

function Get-DefaultMicrophoneDeviceId {
    try {
        $regPath = 'HKCU:\SOFTWARE\Microsoft\Multimedia\Sound\LastUsedSoundDevice\Capture'
        if (Test-Path $regPath) {
            $deviceId = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DeviceId
            if ($deviceId) { return $deviceId }
        }
    } catch {}
    return 'default'
}

function Set-ObsDeviceSettings {
    Write-Step 'Применяем настройки микрофона и камеры'
    $sceneFiles = Get-ChildItem -Path (Join-Path $InstallDir 'config\obs-studio\basic\scenes') -Filter '*.json' -File -ErrorAction SilentlyContinue
    if (-not $sceneFiles) {
        Write-Log 'Файлы сцен OBS не найдены (настройка устройств пропущена)'
        return
    }

    # --- Микрофон ---
    $micFriendly = $null
    if ($script:SelectedMic) { $micFriendly = $script:SelectedMic }

    $micDeviceId = $null
    if ($micFriendly) {
        $micDeviceId = Get-MicrophoneDeviceIdByName $micFriendly
    } else {
        $micDeviceId = Get-DefaultMicrophoneDeviceId
    }

    # --- Камера ---
    $cameraSettings = $null
    $cameraName = $null
    if ($script:SelectedCamera) {
        $cameraName = $script:SelectedCamera
    } else {
        $cameraName = Get-WindowsCameraName
    }
    if ($cameraName) {
        $cameraSettings = [pscustomobject]@{ video_device_id = $cameraName }
    }

    foreach ($sceneFile in $sceneFiles) {
        try {
            $json = Get-Content -Raw -Path $sceneFile.FullName | ConvertFrom-Json
        } catch {
            Write-Log "Пропускаем повреждённый файл сцены: $($sceneFile.Name)"
            continue
        }

        $changed = $false

        # wasapi_input_capture
        $micSources = @()
        foreach ($property in $json.PSObject.Properties) {
            if ($property.Value -and (Get-JsonStringProperty -Object $property.Value -Name 'id') -eq 'wasapi_input_capture') {
                $micSources += $property.Value
            }
        }
        $micSources += Find-ObsSource -Object $json.sources -SourceId 'wasapi_input_capture'

        foreach ($micSource in $micSources) {
            if (-not $micSource.settings) {
                $micSource | Add-Member -MemberType NoteProperty -Name 'settings' -Value ([pscustomobject]@{})
            }
            if ($micSource.settings.PSObject.Properties['device_id']) {
                $micSource.settings.device_id = $micDeviceId
            } else {
                $micSource.settings | Add-Member -MemberType NoteProperty -Name 'device_id' -Value $micDeviceId
            }
            $changed = $true
        }

        # dshow_input
        if ($cameraSettings) {
            $cameraSources = Find-ObsSource -Object $json.sources -SourceId 'dshow_input'
            foreach ($cameraSource in $cameraSources) {
                $cameraSource.settings = $cameraSettings
                # Глушим звук камеры: она захватывает аудио-пин устройства и роутит его
                # во все дорожки записи. muted=true + mixers=0 убирают её со всех дорожек.
                Set-JsonProperty -Object $cameraSource -Name 'muted'  -Value $true
                Set-JsonProperty -Object $cameraSource -Name 'mixers' -Value 0
                $changed = $true
            }
        }

        if ($changed) {
            Write-TextFileAtomic -Path $sceneFile.FullName -Content ($json | ConvertTo-Json -Depth 100)
        }
    }

    # --- Прошиваем глобальные аудио-устройства в профилях ---
    $profileRoot = Join-Path $InstallDir 'config\obs-studio\basic\profiles'
    if (Test-Path $profileRoot) {
        Get-ChildItem -Path $profileRoot -Directory | ForEach-Object {
            $basicIni = Join-Path $_.FullName 'basic.ini'
            if (Test-Path $basicIni) {
                $lines = @(Get-Content -Path $basicIni)
                $lines = Set-IniValue -Lines $lines -Section 'Audio' -Key 'MicDeviceId' -Value $micDeviceId
                if ($micFriendly) {
                    $lines = Set-IniValue -Lines $lines -Section 'Audio' -Key 'MicDevice' -Value $micFriendly
                }
                Write-LinesFileAtomic -Path $basicIni -Lines $lines
            }
        }
    }

    if ($cameraSettings) {
        Write-Log "Камера настроена: $cameraName"
    } else {
        Write-Log 'Камера не обнаружена — используются настройки из пакета'
    }

    $micLog = 'default'
    if ($micFriendly) { $micLog = $micFriendly }
    Write-Log "Микрофон настроен: $micLog [$micDeviceId]"
}

function Set-SceneItemTransform {
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][double] $X,
        [Parameter(Mandatory = $true)][double] $Y,
        [Parameter(Mandatory = $true)][double] $Width,
        [Parameter(Mandatory = $true)][double] $Height,
        # 1 = STRETCH (заполнить bounds игнорируя AR), 2 = SCALE_INNER (вписать с сохранением AR)
        [int] $BoundsType = 1
    )

    $Item.pos = [pscustomobject]@{ x = $X; y = $Y }
    $Item.scale = [pscustomobject]@{ x = 1.0; y = 1.0 }
    $Item.align = 5
    $Item.bounds_type = $BoundsType
    $Item.bounds_align = 5
    $Item.bounds_crop = $false
    $Item.bounds = [pscustomobject]@{ x = $Width; y = $Height }
    $Item.crop_left = 0
    $Item.crop_top = 0
    $Item.crop_right = 0
    $Item.crop_bottom = 0
}

function Set-ObsSceneLayout {
    Write-Step 'Проверяем разрешение сцены'
    $sceneFiles = Get-ChildItem -Path (Join-Path $InstallDir 'config\obs-studio\basic\scenes') -Filter '*.json' -File -ErrorAction SilentlyContinue
    if (-not $sceneFiles) {
        Write-Log 'Файлы сцен OBS не найдены (настройка размещения пропущена)'
        return
    }

    foreach ($sceneFile in $sceneFiles) {
        try {
            $json = Get-Content -Raw -Path $sceneFile.FullName | ConvertFrom-Json
        }
        catch {
            Write-Log "Пропускаем повреждённый файл сцены: $($sceneFile.Name)"
            continue
        }

        $changed = $false
        if ($json.PSObject.Properties['resolution']) {
            if ($json.resolution.x -ne 1920 -or $json.resolution.y -ne 1080) {
                $json.resolution.x = 1920
                $json.resolution.y = 1080
                $changed = $true
            }
        }
        else {
            $json | Add-Member -MemberType NoteProperty -Name 'resolution' -Value ([pscustomobject]@{ x = 1920; y = 1080 })
            $changed = $true
        }

        if ($changed) {
            Write-TextFileAtomic -Path $sceneFile.FullName -Content ($json | ConvertTo-Json -Depth 100)
        }
    }

    Write-Log 'Размещение сцены берётся из JSON-файлов GoodwinOBS/portable; автоматически фиксируется только resolution=1920x1080'
}

function Show-LowDiskSpaceWarning {
    $downloadsPath = Join-Path $env:USERPROFILE 'Downloads'
    try {
        $driveRoot = [IO.Path]::GetPathRoot((Resolve-Path $downloadsPath))
        $drive = Get-PSDrive -Name $driveRoot.TrimEnd(':\') -ErrorAction Stop
        $freeGb = [math]::Round(($drive.Free / 1GB), 1)

        if ($drive.Free -lt 30GB) {
            Write-Step "Мало места на диске: свободно $freeGb ГБ, запись может быть короче 2 часов."

            if ($script:StatusLabel_ref) {
                Set-Status "⚠ Мало места на диске: $freeGb ГБ свободно" 'Red'
            }
        }
    }
    catch {
        Write-Log 'Не удалось проверить свободное место на диске'
    }
}

function Get-HardwareProfileName {
    $gpuNames = @()
    $logicalCpuCount = 0
    $totalMemoryGb = 0

    try {
        $gpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { $_.Name })
    }
    catch {
        try {
            $gpuNames = @(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Video\*\*\Video' -ErrorAction SilentlyContinue | ForEach-Object { $_.DriverDesc })
        }
        catch {
            $gpuNames = @()
        }
    }

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $logicalCpuCount = [int] $cpu.NumberOfLogicalProcessors
    }
    catch {
        $logicalCpuCount = [int] $env:NUMBER_OF_PROCESSORS
    }

    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $totalMemoryGb = [math]::Round(([double] $computer.TotalPhysicalMemory / 1GB), 0)
    }
    catch {
        $totalMemoryGb = 0
    }

    $gpuText = ($gpuNames -join ' ')
    $vendor = 'cpu'
    if ($gpuText -match 'NVIDIA|GeForce|RTX|GTX|Quadro') {
        $vendor = 'nvidia'
    }
    elseif ($gpuText -match 'AMD|Radeon') {
        $vendor = 'amd'
    }

    # Detect VRAM
    $vramMb = 0
    $gpuModel = ''
    try {
        $gpuObj = Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|AMD|Radeon' } |
            Select-Object -First 1
        if ($gpuObj) {
            $gpuModel = $gpuObj.Name
            if ($gpuObj.AdapterRAM) {
                $rawVramMb = [int] ($gpuObj.AdapterRAM / 1MB)
                # Win32_VideoController.AdapterRAM — uint32 и не может показать > 4096 МБ.
                # Около 4095 МБ значение недостоверно (переполнение для карт с 6/8/12+ ГБ),
                # поэтому в этом случае оцениваем VRAM по модели (vramMap ниже).
                if ($rawVramMb -gt 0 -and $rawVramMb -lt 4000) {
                    $vramMb = $rawVramMb
                } else {
                    Write-Log "AdapterRAM=$rawVramMb МБ недостоверно (uint32), оцениваю VRAM по модели GPU"
                }
            }
        }
    }
    catch { }

    # Fallback VRAM estimation from model name if AdapterRAM is 0
    if ($vramMb -le 0 -and $gpuModel) {
        # Common modern cards
        $vramMap = @{
            '5090' = 32768; '5080' = 16384; '5070 Ti' = 16384; '5070' = 12288; '5060 Ti' = 16384; '5060' = 8192;
            '4090' = 24576; '4080' = 16384; '4070 Ti' = 12288; '4070' = 12288; '4060 Ti' = 16384; '4060' = 8192;
            '3090' = 24576; '3080' = 10240; '3070' = 8192; '3060' = 12288;
            '7900 XTX' = 24576; '7900 XT' = 20480; '7800 XT' = 16384; '7700 XT' = 12288; '7600' = 8192;
            '6950 XT' = 16384; '6900 XT' = 16384; '6800 XT' = 16384; '6700 XT' = 12288; '6600 XT' = 8192
        }
        foreach ($k in $vramMap.Keys) {
            if ($gpuModel -match [regex]::Escape($k)) { $vramMb = $vramMap[$k]; break }
        }
    }

    $tier = 'medium'

    if ($vendor -eq 'nvidia') {
        # High tier for RTX 40/50 series and high VRAM
        $isHighSeries = $gpuModel -match 'RTX\s*(50|40)\d{2}'
        $isMidHigh = $gpuModel -match 'RTX\s*30[789]0'
        if ($isHighSeries -or $isMidHigh -or $vramMb -ge 12000 -or $totalMemoryGb -ge 32) {
            $tier = 'high'
        }
        elseif ($vramMb -gt 0 -and $vramMb -lt 6000) {
            $tier = 'low'
        }
        else {
            $tier = 'medium'
        }
    }
    elseif ($vendor -eq 'amd') {
        $isHighSeries = $gpuModel -match 'RX\s*(7|6)\d{3}'
        if ($isHighSeries -or $vramMb -ge 12000 -or $totalMemoryGb -ge 32) {
            $tier = 'high'
        }
        elseif ($vramMb -gt 0 -and $vramMb -lt 6000) {
            $tier = 'low'
        }
        else {
            $tier = 'medium'
        }
    }
    else {
        # CPU encoding path
        if ($logicalCpuCount -ge 12 -and $totalMemoryGb -ge 32) {
            $tier = 'high'
        }
        elseif ($logicalCpuCount -ge 8 -and $totalMemoryGb -ge 16) {
            $tier = 'medium'
        }
        else {
            $tier = 'low'
        }
    }

    Write-Log "Оборудование: vendor=$vendor, tier=$tier, gpu='$gpuModel', ядра=$logicalCpuCount, ОЗУ=${totalMemoryGb}ГБ, VRAM=${vramMb}МБ"
    return "${vendor}_${tier}"
}

function Set-ActiveObsProfile {
    Write-Step 'Определяем оборудование'
    $configDir = Join-Path $InstallDir 'config\obs-studio'
    $profileRoot = Join-Path $configDir 'basic\profiles'
    $sceneRoot = Join-Path $configDir 'basic\scenes'

    $profileName = Get-HardwareProfileName
    if (-not (Test-Path (Join-Path $profileRoot $profileName))) {
        $profileName = 'cpu_medium'
    }

    $preferredScenePath = Join-Path $sceneRoot 'goodwin_obs.json'
    $sceneFile = if (Test-Path -LiteralPath $preferredScenePath) {
        Get-Item -LiteralPath $preferredScenePath
    } else {
        Get-ChildItem -Path $sceneRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    $sceneCollectionFile = if ($sceneFile) { $sceneFile.Name } else { 'goodwin_obs.json' }
    $sceneCollectionName = [IO.Path]::GetFileNameWithoutExtension($sceneCollectionFile)

    $userIni = Join-Path $configDir 'user.ini'
    $lines = @()
    if (Test-Path $userIni) {
        $lines = @(Get-Content -Path $userIni)
    }

    $lines = Set-IniValue -Lines $lines -Section 'General' -Key 'FirstRun' -Value 'true'
    $lines = Set-IniValue -Lines $lines -Section 'Basic' -Key 'Profile' -Value $profileName
    $lines = Set-IniValue -Lines $lines -Section 'Basic' -Key 'ProfileDir' -Value $profileName
    $lines = Set-IniValue -Lines $lines -Section 'Basic' -Key 'SceneCollection' -Value $sceneCollectionName
    $lines = Set-IniValue -Lines $lines -Section 'Basic' -Key 'SceneCollectionFile' -Value $sceneCollectionFile
    $lines = Set-IniValue -Lines $lines -Section 'Basic' -Key 'ConfigOnNewProfile' -Value 'true'

    Write-LinesFileAtomic -Path $userIni -Lines $lines
    Write-Step "Установлен профиль: $profileName"
}

function Set-PortableObsConfig {
    Write-Step 'Устанавливаем путь записи'
    $profileRoot = Join-Path $InstallDir 'config\obs-studio\basic\profiles'
    if (-not (Test-Path $profileRoot)) {
        Write-Log 'Профили OBS не найдены'
        return
    }

    $profiles = @(Get-ChildItem -Path $profileRoot -Directory)
    if (-not $profiles) {
        Write-Log 'Профили OBS не найдены'
        return
    }

    New-Item -ItemType Directory -Force -Path $script:RecordingDir | Out-Null

    $recordingPath = $script:RecordingDir
    $recordingPathForObs = $recordingPath.Replace('\', '\\')
    $recordingResolution = '1920x1080'

    Write-Log "Путь записей: $recordingPath"
    Write-Log "Разрешение записи: $recordingResolution"

    $nickname = $script:SelectedNickname
    if ([string]::IsNullOrWhiteSpace($nickname)) { $nickname = 'untitled' }
    $filenameFormat = "$nickname %CCYY-%MM-%DD %hh-%mm-%ss"
    Write-Log "Формат имени файла установлен: $filenameFormat"

    foreach ($profile in $profiles) {
        $basicIni = Join-Path $profile.FullName 'basic.ini'
        if (-not (Test-Path $basicIni)) {
            continue
        }

        $lines = @(Get-Content -Path $basicIni)
        $lines = Set-IniValue -Lines $lines -Section 'SimpleOutput' -Key 'FilePath' -Value $recordingPathForObs
        $lines = Set-IniValue -Lines $lines -Section 'SimpleOutput' -Key 'VBitrate' -Value '15000'
        $lines = Set-IniValue -Lines $lines -Section 'AdvOut' -Key 'RecFilePath' -Value $recordingPathForObs
        $lines = Set-IniValue -Lines $lines -Section 'AdvOut' -Key 'FFFilePath' -Value $recordingPathForObs
        $lines = Set-IniValue -Lines $lines -Section 'AdvOut' -Key 'FFVBitrate' -Value '15000'
        $lines = Set-IniValue -Lines $lines -Section 'AdvOut' -Key 'RescaleRes' -Value $recordingResolution
        $lines = Set-IniValue -Lines $lines -Section 'AdvOut' -Key 'RecRescaleRes' -Value $recordingResolution
        $lines = Set-IniValue -Lines $lines -Section 'AdvOut' -Key 'FFRescaleRes' -Value $recordingResolution
        $lines = Set-IniValue -Lines $lines -Section 'Video' -Key 'BaseCX' -Value '1920'
        $lines = Set-IniValue -Lines $lines -Section 'Video' -Key 'BaseCY' -Value '1080'
        $lines = Set-IniValue -Lines $lines -Section 'Video' -Key 'OutputCX' -Value '1920'
        $lines = Set-IniValue -Lines $lines -Section 'Video' -Key 'OutputCY' -Value '1080'

        $lines = Set-IniValue -Lines $lines -Section 'Output' -Key 'FilenameFormatting' -Value $filenameFormat

        Write-LinesFileAtomic -Path $basicIni -Lines $lines

        # Update bitrate in recordEncoder.json (used by AdvOut for h264/NVENC/AMD)
        $encoderJson = Join-Path $profile.FullName 'recordEncoder.json'
        if (Test-Path $encoderJson) {
            try {
                $enc = Get-Content -Raw -Path $encoderJson | ConvertFrom-Json
                foreach ($key in @('bitrate', 'target_bitrate', 'VBitrate')) {
                    if ($enc.PSObject.Properties[$key]) {
                        $enc.$key = 15000
                    }
                }
                Write-TextFileAtomic -Path $encoderJson -Content ($enc | ConvertTo-Json -Depth 100)
            } catch {
                Write-Log "Не удалось обновить recordEncoder.json: $($_.Exception.Message)"
            }
        }
    }

    Set-ObsDeviceSettings
    Set-ObsSceneLayout
    Set-ActiveObsProfile
    Show-LowDiskSpaceWarning
}

function Install-PortableSettings {
    Write-Step 'Применяем базовые настройки'
    $portableFlag = Join-Path $InstallDir 'portable_mode.txt'
    $configDir = Join-Path $InstallDir 'config\obs-studio'

    Write-Log 'Включаем портативный режим OBS'
    New-Item -ItemType File -Force -Path $portableFlag | Out-Null
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    Write-Log 'Скачиваем и применяем настройки OBS из GoodwinOBS/portable'
    Install-PortableRepoObsFiles -ConfigDir $configDir
    Install-PortableRepoObsProfiles -ConfigDir $configDir

    Set-PortableObsConfig
}

function Start-PortableObs {
    $obsExe = Join-Path $InstallDir 'bin\64bit\obs64.exe'
    $obsWorkDir = Split-Path $obsExe -Parent

    Write-Step 'Запускаем OBS Studio'
    Start-Process -FilePath $obsExe -ArgumentList '--multi --portable' -WorkingDirectory $obsWorkDir
}


# Доступ к Dropbox: refresh token обменивается на короткоживущий access token.
# Для распространения скрипта безопаснее вынести этот обмен на серверный endpoint.

function Get-WebExceptionDetail {
    # Извлекает HTTP-статус и тело ответа из ошибки Invoke-RestMethod/Invoke-WebRequest.
    # Работает и в Windows PowerShell 5.1 (поток ответа), и в PowerShell 7 (ErrorDetails).
    # Дополнительно парсит JSON-ошибку OAuth/API: поле error
    # и error_description.
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    $result = [pscustomobject]@{
        StatusCode = $null
        Body       = $null
        OAuthError = $null
        OAuthDesc  = $null
    }

    $resp = $ErrorRecord.Exception.Response
    if ($resp) {
        try { $result.StatusCode = [int] $resp.StatusCode } catch {}
    }

    # PS 7 кладёт тело в ErrorDetails.Message; PS 5.1 — читаем поток ответа вручную.
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $result.Body = $ErrorRecord.ErrorDetails.Message
    }
    elseif ($resp -and $resp.PSObject.Methods['GetResponseStream']) {
        try {
            $stream = $resp.GetResponseStream()
            $reader = New-Object IO.StreamReader($stream)
            $result.Body = $reader.ReadToEnd()
            $reader.Close()
        } catch {}
    }

    if ($result.Body) {
        try {
            $json = $result.Body | ConvertFrom-Json
            if ($json.error) {
                if ($json.error -is [string]) { $result.OAuthError = $json.error }
                elseif ($json.error.message)  { $result.OAuthError = $json.error.message }
            }
            if ($json.error_description) { $result.OAuthDesc = $json.error_description }
        } catch {}
    }

    return $result
}

function Test-RetryableWebError {
    # Повторять есть смысл только на временных сбоях: сетевые ошибки/таймауты,
    # 408 (timeout), 429 (rate limit) и 5xx. 400/401/404 — постоянные ошибки клиента.
    # 403 здесь НЕ повторяем: это либо квота/права (повтор бесполезен), либо суточный
    # лимит выгрузки (userRateLimitExceeded) — его разруливает failover на другой
    # аккаунт на уровне открытия сессии, а не слепой повтор того же запроса (который
    # лишь сильнее жжёт суточный лимит).
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    $resp = $ErrorRecord.Exception.Response
    if (-not $resp) { return $true }  # нет ответа => сетевая ошибка/таймаут — повторяем

    $code = 0
    try { $code = [int] $resp.StatusCode } catch { return $true }
    if ($code -le 0) { return $true }

    if ($code -eq 408 -or $code -eq 429) { return $true }
    if ($code -ge 500) { return $true }
    return $false
}

function Invoke-UploadWithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Operation,
        [int] $Retries = 5
    )

    $attempt = 0
    while ($true) {
        try {
            return & $Operation
        }
        catch {
            $attempt++
            # На постоянных ошибках клиента (например 400 от OAuth) не крутим повторы впустую.
            if ($attempt -gt $Retries -or -not (Test-RetryableWebError $_)) {
                throw
            }

            $delaySeconds = [math]::Min(30, [math]::Pow(2, $attempt))
            Write-Step "Ошибка загрузки, повтор через $delaySeconds с. ($attempt/$Retries): $($_.Exception.Message)"
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

# Кэш короткоживущего Dropbox access_token. Refresh token нужен только для
# получения нового access token, поэтому чанк-загрузка не дёргает OAuth на каждый блок.
$script:CachedAccessToken = $null
$script:CachedAccessTokenExpiresAt = [datetime]::MinValue
$script:DropboxUploadFolderPath = $DropboxUploadFolderPath
$script:DropboxAccessState = 'Не проверен'

function Get-GoodwinSecretKey {
    $key = [Environment]::GetEnvironmentVariable('GOODWIN_OBS_KEY', 'Process')
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw 'Не задан ключ дешифровки GOODWIN_OBS_KEY. Укажите его в переменной окружения перед запуском скрипта.'
    }
    return $key
}

function Unprotect-GoodwinSecret {
    param(
        [Parameter(Mandatory = $true)][string] $Payload,
        [Parameter(Mandatory = $true)][string] $Password
    )

    $parts = $Payload -split ':', 4
    if ($parts.Count -ne 4 -or $parts[0] -ne 'v1') {
        throw 'Некорректный формат зашифрованного значения.'
    }

    $salt = [Convert]::FromBase64String($parts[1])
    $iv = [Convert]::FromBase64String($parts[2])
    $cipher = [Convert]::FromBase64String($parts[3])
    $kdf = $null
    $aes = $null
    $dec = $null
    try {
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
        $aes = [Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $kdf.GetBytes(32)
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        return [Text.Encoding]::UTF8.GetString($plain)
    }
    catch {
        throw 'Не удалось расшифровать Dropbox OAuth-конфиг. Проверьте ключ GOODWIN_OBS_KEY.'
    }
    finally {
        if ($dec) { $dec.Dispose() }
        if ($aes) { $aes.Dispose() }
        if ($kdf) { $kdf.Dispose() }
    }
}

function Get-DropboxOAuthConfig {
    if ($script:DropboxOAuthConfig) { return $script:DropboxOAuthConfig }

    $key = Get-GoodwinSecretKey
    $script:DropboxOAuthConfig = [pscustomobject]@{
        AppKey       = Unprotect-GoodwinSecret $script:DropboxOAuthEncrypted.k $key
        AppSecret    = Unprotect-GoodwinSecret $script:DropboxOAuthEncrypted.s $key
        RefreshToken = Unprotect-GoodwinSecret $script:DropboxOAuthEncrypted.r $key
    }
    return $script:DropboxOAuthConfig
}

function Ensure-DropboxRefreshToken {
    if (-not [string]::IsNullOrWhiteSpace($script:DropboxRuntimeRefreshToken)) {
        return $script:DropboxRuntimeRefreshToken
    }

    $cfg = Get-DropboxOAuthConfig
    if ([string]::IsNullOrWhiteSpace($cfg.RefreshToken)) {
        throw 'Dropbox refresh_token не задан в зашифрованном OAuth-конфиге.'
    }

    $script:DropboxRuntimeRefreshToken = [string]$cfg.RefreshToken
    return $script:DropboxRuntimeRefreshToken
}

function Get-DropboxAccessToken {
    [CmdletBinding()]
    param([switch] $Force)

    Ensure-Tls12

    # Переиспользуем токен, пока до истечения > 5 минут; иначе спрашиваем сервер заново.
    if (-not $Force -and $script:CachedAccessToken -and
        ((Get-Date) -lt $script:CachedAccessTokenExpiresAt.AddMinutes(-5))) {
        Set-DropboxAccessState 'Готов'
        return $script:CachedAccessToken
    }

    Set-DropboxAccessState 'Проверка'
    try {
        $refreshToken = Ensure-DropboxRefreshToken
    }
    catch {
        Set-DropboxAccessState 'Ошибка'
        throw
    }

    $cfg = Get-DropboxOAuthConfig
    $pair = '{0}:{1}' -f $cfg.AppKey, $cfg.AppSecret
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    try {
        $response = Invoke-UploadWithRetry {
            Invoke-RestMethod `
                -Method Post `
                -Uri 'https://api.dropboxapi.com/oauth2/token' `
                -Headers @{ Authorization = "Basic $basic" } `
                -Body @{
                    grant_type = 'refresh_token'
                    refresh_token = $refreshToken
                } `
                -TimeoutSec 30
        }
    }
    catch {
        $detail = Get-WebExceptionDetail $_
        $statusText = if ($detail.StatusCode) { "HTTP $($detail.StatusCode)" } else { 'сетевая ошибка' }
        Write-Log "Запрос Dropbox access token не удался ($statusText): $($_.Exception.Message)"
        if ($detail.Body) { Write-Log "Тело ответа Dropbox OAuth: $($detail.Body)" }
        Set-DropboxAccessState 'Ошибка'
        throw "Не удалось получить Dropbox access token ($statusText). Проверьте ключ GOODWIN_OBS_KEY, OAuth-конфиг и права приложения."
    }

    if (-not $response.access_token) {
        Set-DropboxAccessState 'Ошибка'
        throw 'Dropbox OAuth не вернул access_token.'
    }

    $lifetime = if ($response.expires_in) { [int]$response.expires_in } else { 3600 }
    $script:CachedAccessToken = $response.access_token
    $script:CachedAccessTokenExpiresAt = (Get-Date).AddSeconds($lifetime)
    Set-DropboxAccessState 'Готов'
    return $script:CachedAccessToken
}

function ConvertTo-DropboxApiJson {
    param([Parameter(Mandatory = $true)] $Object)
    $json = ($Object | ConvertTo-Json -Depth 20 -Compress)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -gt 127) {
            [void]$sb.Append(('\u{0:x4}' -f $code))
        } else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Ensure-DropboxUploadFolder {
    param([Parameter(Mandatory = $true)][string] $AccessToken)

    $path = $script:DropboxUploadFolderPath
    if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '/') { return }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
    $path = $path.TrimEnd('/')
    $script:DropboxUploadFolderPath = $path

    $headers = @{ Authorization = "Bearer $AccessToken" }
    try {
        Invoke-RestMethod `
            -Method Post `
            -Uri 'https://api.dropboxapi.com/2/files/create_folder_v2' `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body (ConvertTo-DropboxApiJson @{ path = $path; autorename = $false }) | Out-Null
        Write-Log "Dropbox: создана папка $path"
    }
    catch {
        $detail = Get-WebExceptionDetail $_
        if ($detail.Body -and $detail.Body -match 'path/conflict/folder') {
            Write-Log "Dropbox: папка уже существует $path"
            return
        }
        if ($detail.Body) { Write-Log "Dropbox create_folder detail: $($detail.Body)" }
        throw
    }
}

function Set-DropboxAccessState {
    param([string] $State)

    $script:DropboxAccessState = $State
    if ($script:DropboxStateLabel_ref) {
        $script:DropboxStateLabel_ref.Text = $State
        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
    }
}

function Test-DropboxAccess {
    # Дополнительная проверка: убеждаемся, что OAuth-токен живой и папка
    # Dropbox для загрузки доступна на запись.
    # Возвращает $true при успехе, $false иначе. Сама ошибка пишется в технический лог.
    Set-DropboxAccessState 'Проверка'
    try {
        Ensure-Tls12
        $accessToken = Get-DropboxAccessToken
        Ensure-DropboxUploadFolder -AccessToken $accessToken
        Write-Log "Dropbox API: папка '$($script:DropboxUploadFolderPath)' доступна для загрузки"
        Set-DropboxAccessState 'Готов'
        return $true
    }
    catch {
        $detail = Get-WebExceptionDetail $_
        Write-Log "Dropbox API check FAILED: $($_.Exception.Message)"
        if ($detail.Body) { Write-Log "Detail: $($detail.Body)" }
        Set-DropboxAccessState 'Ошибка'
        return $false
    }
}

function Get-VideoMimeType {
    param([Parameter(Mandatory = $true)][string] $InputFile)

    switch ([IO.Path]::GetExtension($InputFile).ToLowerInvariant()) {
        '.mp4' { return 'video/mp4' }
        '.mkv' { return 'video/x-matroska' }
        '.mov' { return 'video/quicktime' }
        '.flv' { return 'video/x-flv' }
        default { return 'application/octet-stream' }
    }
}

function Get-DropboxUploadPath {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo] $File)

    $folder = $script:DropboxUploadFolderPath
    if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq '/') {
        return '/' + $File.Name
    }
    if (-not $folder.StartsWith('/')) { $folder = '/' + $folder }
    $folder = $folder.TrimEnd('/')
    return "$folder/$($File.Name)"
}

function New-DropboxUploadSession {
    param(
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][string] $InputFile
    )

    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post), 'https://content.dropboxapi.com/2/files/upload_session/start'
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $AccessToken)
    $request.Headers.TryAddWithoutValidation('Dropbox-API-Arg', (ConvertTo-DropboxApiJson @{ close = $false })) | Out-Null
    $emptyBytes = New-Object byte[] 0
    $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (,$emptyBytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
    $request.Content = $content
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    try {
        $response = Wait-HttpTask ($client.SendAsync($request))
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Dropbox upload_session/start HTTP $([int]$response.StatusCode): $body"
        }
        $json = $body | ConvertFrom-Json
        if (-not $json.session_id) {
            throw 'Dropbox не вернул session_id для upload_session/start.'
        }
        return [string]$json.session_id
    }
    finally {
        $request.Dispose()
        $content.Dispose()
        $client.Dispose()
    }
}

function Wait-HttpTask {
    # Ждём завершения HTTP-задачи, прокручивая очередь сообщений WinForms,
    # чтобы окно не зависало («Не отвечает») во время отправки большого чанка.
    param([Parameter(Mandatory = $true)] $Task)
    while (-not $Task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    return $Task.GetAwaiter().GetResult()
}

function Get-DropboxErrorSummary {
    # Достаёт короткую машинную причину ошибки Dropbox (error_summary).
    param([string] $Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try {
        $j = $Body | ConvertFrom-Json
        if ($j.error_summary) { return [string]$j.error_summary }
        if ($j.error -and $j.error.'.tag') { return [string]$j.error.'.tag' }
    } catch {}
    return $null
}

function Get-DropboxCorrectOffset {
    param([string] $Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try {
        $j = $Body | ConvertFrom-Json
        if ($j.error -and $j.error.'.tag' -eq 'incorrect_offset' -and $j.error.correct_offset -ne $null) {
            return [long]$j.error.correct_offset
        }
        if ($j.error -and $j.error.lookup_failed -and
            $j.error.lookup_failed.'.tag' -eq 'incorrect_offset' -and
            $j.error.lookup_failed.correct_offset -ne $null) {
            return [long]$j.error.lookup_failed.correct_offset
        }
    } catch {}
    return $null
}

function Format-DropboxFailure {
    param(
        [string] $Prefix,
        [string] $Body
    )
    $summary = Get-DropboxErrorSummary $Body
    if ($summary) { return "$Prefix ($summary): $Body" }
    if (-not [string]::IsNullOrWhiteSpace($Body)) { return "$Prefix`: $Body" }
    return $Prefix
}

function Send-DropboxChunk {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][string] $SessionId,
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][long] $Offset
    )

    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post), 'https://content.dropboxapi.com/2/files/upload_session/append_v2'
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $AccessToken)
    $arg = @{
        cursor = @{
            session_id = $SessionId
            offset = $Offset
        }
        close = $false
    }
    $request.Headers.TryAddWithoutValidation('Dropbox-API-Arg', (ConvertTo-DropboxApiJson $arg)) | Out-Null
    $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (,$Bytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
    $request.Content = $content
    try {
        return Wait-HttpTask ($Client.SendAsync($request))
    }
    finally {
        $request.Dispose()
        $content.Dispose()
    }
}

function Finish-DropboxUploadSession {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][string] $SessionId,
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][long] $Offset,
        [Parameter(Mandatory = $true)][string] $DropboxPath
    )

    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post), 'https://content.dropboxapi.com/2/files/upload_session/finish'
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $AccessToken)
    $arg = @{
        cursor = @{
            session_id = $SessionId
            offset = $Offset
        }
        commit = @{
            path = $DropboxPath
            mode = 'add'
            autorename = $true
            mute = $true
        }
    }
    $request.Headers.TryAddWithoutValidation('Dropbox-API-Arg', (ConvertTo-DropboxApiJson $arg)) | Out-Null
    $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (,$Bytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
    $request.Content = $content
    try {
        return Wait-HttpTask ($Client.SendAsync($request))
    }
    finally {
        $request.Dispose()
        $content.Dispose()
    }
}

function Sync-UploadPosition {
    # У Dropbox нет отдельного status-запроса для upload session. Если предыдущий
    # чанк был принят, повтор обычно вернёт incorrect_offset с correct_offset;
    # этот случай обрабатывается в основном цикле по телу HTTP 409.
    param(
        [Parameter(Mandatory = $true)] $Client,
        [Parameter(Mandatory = $true)] $Session,
        [AllowEmptyString()][string] $AccessToken = ''
    )
    return
}

function New-DropboxSharedLink {
    param(
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $body = ConvertTo-DropboxApiJson @{ path = $Path; settings = @{} }
    try {
        $resp = Invoke-RestMethod `
            -Method Post `
            -Uri 'https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings' `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $body
        if ($resp.url) { return [string]$resp.url }
    }
    catch {
        $detail = Get-WebExceptionDetail $_
        if (-not ($detail.Body -and $detail.Body -match 'shared_link_already_exists')) {
            Write-Log "Dropbox shared link не создан: $($_.Exception.Message)"
            if ($detail.Body) { Write-Log "Dropbox shared link detail: $($detail.Body)" }
            return $null
        }
    }

    try {
        $resp = Invoke-RestMethod `
            -Method Post `
            -Uri 'https://api.dropboxapi.com/2/sharing/list_shared_links' `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body (ConvertTo-DropboxApiJson @{ path = $Path; direct_only = $true })
        if ($resp.links -and $resp.links.Count -gt 0 -and $resp.links[0].url) {
            return [string]$resp.links[0].url
        }
    }
    catch {
        Write-Log "Dropbox shared link lookup не удался: $($_.Exception.Message)"
    }

    return $null
}




function Upload-RecordedFiles {
    # Параллельная (interleaved) загрузка нескольких файлов.
    # Все файлы стартуют одновременно: открываем resumable-session для каждого,
    # далее в цикле round-robin отправляем по одному 32 МБ-чанку каждой активной сессии.
    # Это:
    #  - даёт визуально одновременный прогресс всех файлов (а не последовательный)
    #  - использует ОДИН HttpClient (keep-alive) — экономичнее, чем по соединению на файл
    #  - при потерянном ответе Dropbox возвращает incorrect_offset, и позиция безопасно
    #    сдвигается только вперёд.
    param([System.IO.FileInfo[]] $Files)
    $files = $Files

    if (-not $files -or $files.Count -eq 0) {
        Write-Step 'Файлы для загрузки не выбраны.'
        return
    }

    Write-Step ("Файлов к загрузке: {0}" -f $files.Count)
    $totalSizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
    $totalSizeGb = [math]::Round($totalSizeBytes / 1GB, 2)
    Write-Step ("Общий объём: {0} ГБ" -f $totalSizeGb)

    # Берём короткоживущий Dropbox access token из refresh token.
    $accessToken = Get-DropboxAccessToken -Force
    Ensure-DropboxUploadFolder -AccessToken $accessToken

    # Открываем сессии и стримы для каждого файла. Если для одного не получилось —
    # помечаем ошибкой, но не валим остальные.
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $s = [pscustomobject]@{
            File       = $f
            Name       = $f.Name
            Size       = [long]$f.Length
            MimeType   = (Get-VideoMimeType -InputFile $f.FullName)
            DropboxPath = (Get-DropboxUploadPath -File $f)
            SessionId  = $null
            Stream     = $null
            Position   = [long]0
            ErrorCount = 0
            AuthRetries = 0
            Done       = $false
            Error      = $null
            LastDetail = $null
            Result     = $null
        }
        try {
            $s.SessionId = New-DropboxUploadSession -AccessToken $accessToken -InputFile $f.FullName
            $s.Stream = [IO.File]::OpenRead($f.FullName)
        }
        catch {
            $s.Error = "Не удалось открыть сессию: $($_.Exception.Message)"
        }
        $sessions.Add($s) | Out-Null
    }

    # Инициализируем состояние прогресса
    Initialize-MultiProgress -Names ($sessions | ForEach-Object { $_.Name })
    foreach ($s in $sessions) {
        if ($s.Error) {
            Show-UploadProgress -FileName $s.Name -Uploaded 0 -Total $s.Size -Status 'error'
        } else {
            Show-UploadProgress -FileName $s.Name -Uploaded 0 -Total $s.Size -Status 'active'
        }
    }

    $chunkSize  = [long](32MB)
    $buffer     = New-Object byte[] $chunkSize
    $maxRetries = 5

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromHours(2)
    $client.DefaultRequestHeaders.ConnectionClose = $false
    $client.DefaultRequestHeaders.ExpectContinue = $false

    try {
        # Главный цикл: круговой обход всех активных сессий, по 1 чанку за проход.
        while ($true) {
            $active = $sessions | Where-Object { -not $_.Done -and -not $_.Error }
            if (-not $active) { break }

            foreach ($s in $active) {
                if ($s.Done -or $s.Error) { continue }
                if ($s.Position -ge $s.Size) {
                    # Все байты уже приняты сессией, но файл ещё нужно закоммитить.
                    try {
                        $accessToken = Get-DropboxAccessToken
                        $response = Finish-DropboxUploadSession -Client $client -SessionId $s.SessionId `
                            -AccessToken $accessToken -Bytes ([byte[]]@()) -Offset $s.Size -DropboxPath $s.DropboxPath
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        if ($response.IsSuccessStatusCode) {
                            $s.Done = $true
                            try { $s.Result = $body | ConvertFrom-Json } catch {}
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Size -Total $s.Size -Status 'done'
                        } else {
                            $s.LastDetail = $body
                            $s.Error = Format-DropboxFailure "Dropbox finish HTTP $([int]$response.StatusCode)" $body
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                        }
                    }
                    catch {
                        $s.Error = "Не удалось завершить Dropbox upload session: $($_.Exception.Message)"
                        Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                    }
                    continue
                }

                # Освежаем токен: кэш сам обновит его, если до истечения < 5 минут
                # (спасает загрузки длиннее часа).
                try { $accessToken = Get-DropboxAccessToken }
                catch { Write-Log "Не удалось обновить токен: $($_.Exception.Message)" }
                $chunkToken = $accessToken

                # Читаем очередной чанк
                $s.Stream.Position = $s.Position
                $remaining = $s.Size - $s.Position
                $readSize  = [int][math]::Min($chunkSize, $remaining)
                $read      = $s.Stream.Read($buffer, 0, $readSize)
                if ($read -le 0) {
                    $s.Error = 'Неожиданный конец файла при чтении блока.'
                    Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                    continue
                }
                $chunk = New-Object byte[] $read
                [Array]::Copy($buffer, 0, $chunk, 0, $read)
                $start = $s.Position
                $end   = $s.Position + $read - 1
                $isFinalChunk = ($end -ge ($s.Size - 1))

                try {
                    if ($isFinalChunk) {
                        $response = Finish-DropboxUploadSession -Client $client -SessionId $s.SessionId `
                            -AccessToken $chunkToken -Bytes $chunk -Offset $start -DropboxPath $s.DropboxPath
                    } else {
                        $response = Send-DropboxChunk -Client $client -SessionId $s.SessionId `
                            -AccessToken $chunkToken -Bytes $chunk -Offset $start
                    }
                    $statusCode   = [int]$response.StatusCode
                    $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

                    if ($response.IsSuccessStatusCode) {
                        $s.ErrorCount  = 0
                        $s.AuthRetries = 0
                        if ($isFinalChunk) {
                            $s.Position = $s.Size
                            $s.Done     = $true
                            try { $s.Result = $responseBody | ConvertFrom-Json } catch {}
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Size -Total $s.Size -Status 'done'
                        } else {
                            $s.Position = $end + 1
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'active'
                        }
                    }
                    elseif ($statusCode -eq 401) {
                        # Токен протух во время загрузки — обновляем и повторяем ЭТОТ ЖЕ чанк,
                        # не считая это ошибкой и не трогая позицию.
                        $s.AuthRetries++
                        Write-Log "401 на $($s.Name): обновляем токен (попытка $($s.AuthRetries))"
                        if ($s.AuthRetries -gt 3) {
                            $s.Error = 'Повторный 401: не удаётся обновить токен.'
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                        }
                        else {
                            try { $accessToken = Get-DropboxAccessToken -Force }
                            catch { Write-Log "Обновление токена не удалось: $($_.Exception.Message)" }
                        }
                    }
                    elseif ($statusCode -eq 409) {
                        $s.LastDetail = $responseBody
                        $correctOffset = Get-DropboxCorrectOffset -Body $responseBody
                        if ($correctOffset -ne $null -and $correctOffset -ge $s.Position) {
                            Write-Log "Dropbox incorrect_offset на $($s.Name): server=$correctOffset local=$($s.Position)"
                            $s.Position = [long]$correctOffset
                            $s.ErrorCount = 0
                            Show-UploadProgress -FileName $s.Name -Uploaded ([math]::Min($s.Position, $s.Size)) -Total $s.Size -Status 'active'
                        } else {
                            $s.ErrorCount++
                            Write-Log "Dropbox HTTP 409 на $($s.Name): $responseBody"
                            if ($s.ErrorCount -gt $maxRetries) {
                                $s.Error = Format-DropboxFailure "Dropbox HTTP 409 после $maxRetries попыток" $responseBody
                                Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                            }
                            else {
                                Start-Sleep -Milliseconds ([int][math]::Min(5000, [math]::Pow(2, $s.ErrorCount) * 250))
                            }
                        }
                    }
                    else {
                        $s.LastDetail = $responseBody
                        if ($statusCode -eq 403) {
                            $reason = Get-DropboxErrorSummary $responseBody
                            $s.Error = Format-DropboxFailure "Dropbox отказал (403 $reason)" $responseBody
                            Write-Log "Dropbox 403 ($reason) на $($s.Name): $responseBody"
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                            continue
                        }
                        # Прочие 4xx/5xx — счётчик + безопасный ресинк позиции.
                        $s.ErrorCount++
                        Write-Log "Chunk HTTP $statusCode на $($s.Name): $responseBody"
                        if ($s.ErrorCount -gt $maxRetries) {
                            $s.Error = Format-DropboxFailure "HTTP $statusCode после $maxRetries попыток" $responseBody
                            Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                        }
                        else {
                            Sync-UploadPosition -Client $client -Session $s -AccessToken $chunkToken
                            Start-Sleep -Milliseconds ([int][math]::Min(5000, [math]::Pow(2, $s.ErrorCount) * 250))
                        }
                    }
                }
                catch {
                    # Транспортная ошибка (HTTP-ответа не было): повторяем чанк с
                    # экспоненциальной паузой, предварительно пересинхронизировав позицию.
                    $s.ErrorCount++
                    Write-Log "Транспорт на $($s.Name) (попытка $($s.ErrorCount)/$maxRetries): $($_.Exception.Message)"
                    if ($s.ErrorCount -gt $maxRetries) {
                        $s.Error = $_.Exception.Message
                        Show-UploadProgress -FileName $s.Name -Uploaded $s.Position -Total $s.Size -Status 'error'
                    }
                    else {
                        Sync-UploadPosition -Client $client -Session $s -AccessToken $accessToken
                        Start-Sleep -Milliseconds ([int][math]::Min(5000, [math]::Pow(2, $s.ErrorCount) * 250))
                    }
                }
            }
        }
    }
    finally {
        foreach ($s in $sessions) {
            if ($s.Stream) { try { $s.Stream.Dispose() } catch {} }
        }
        try { $client.Dispose() } catch {}
    }

    # Очищаем состояние прогресса, выводим финальные строки на каждый файл.
    Clear-UploadProgress
    $uploadErrors = 0
    $hist = Load-UploadHistory          # читаем историю один раз...
    $histChanged = $false
    foreach ($s in $sessions) {
        if ($s.Done) {
            $dropboxPath = if ($s.Result -and $s.Result.path_display) { [string]$s.Result.path_display } else { $s.DropboxPath }
            $shareLink = $null
            try {
                $shareLink = New-DropboxSharedLink -AccessToken (Get-DropboxAccessToken) -Path $dropboxPath
            } catch {}
            $link = if ($shareLink) { $shareLink } else { $dropboxPath }
            Write-Step "✓ $($s.Name) → $link"
            $dedupKey = $null
            if ($script:UploadDedupKeys -and $script:UploadDedupKeys.ContainsKey($s.File.FullName)) {
                $dedupKey = $script:UploadDedupKeys[$s.File.FullName]
            }
            if (-not $dedupKey) { $dedupKey = Get-FileDedupSignature -Path $s.File.FullName }
            if ($dedupKey) {
                $dropboxId = if ($s.Result) { $s.Result.id } else { $null }
                $hist[$dedupKey] = [pscustomobject]@{
                    key         = $dedupKey
                    name        = $s.File.Name
                    size        = $s.File.Length
                    dropbox_id  = $dropboxId
                    dropbox_path = $dropboxPath
                    uploaded_at = (Get-Date).ToUniversalTime().ToString('o')
                }
                $histChanged = $true
            }
        }
        else {
            $uploadErrors++
            $reason = if ($s.Error) { $s.Error } else { 'неизвестная ошибка' }
            Write-Step "✗ $($s.Name): $reason"
        }
    }
    if ($histChanged) { Save-UploadHistory $hist }   # ...и сохраняем один раз

    Write-Step 'Все записи загружены в Dropbox. Окно можно закрыть.'

    if ($uploadErrors -gt 0) {
        $details = @(
            foreach ($s in $sessions) {
                if (-not $s.Done) {
                    $reason = if ($s.Error) { [string]$s.Error } else { 'неизвестная ошибка' }
                    "- $($s.Name): $reason"
                }
            }
        )
        $detailText = if ($details.Count -gt 0) { "`r`n" + ($details -join "`r`n") } else { '' }
        throw "Загрузка завершена с ошибками: $uploadErrors из $($files.Count) файлов не было загружено.$detailText"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Локальное хранилище настроек (JSON в %APPDATA%\goodwin_obs\settings.json)
# ═══════════════════════════════════════════════════════════════════════════════
function Load-LocalSettings {
    if (-not (Test-Path $script:SettingsFile)) { return @{} }
    try {
        $raw = Get-Content -Raw -Path $script:SettingsFile -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        Write-Log "Не удалось прочитать settings.json: $($_.Exception.Message)"
        return @{}
    }
}

function Save-LocalSettings {
    param([hashtable] $Data)
    try {
        $json = $Data | ConvertTo-Json -Compress
        Write-TextFileAtomic -Path $script:SettingsFile -Content $json
    } catch {
        Write-Log "Не удалось сохранить settings.json: $($_.Exception.Message)"
    }
}

function Save-CurrentSettings {
    Save-LocalSettings @{
        nickname      = $script:SelectedNickname
        recordingRoot = $script:RecordingRoot
        camera        = $script:SelectedCamera
        mic           = $script:SelectedMic
    }
}

# ── Лог уже загруженных файлов (защита от дублей) ─────────────────────────
# Хранится в %APPDATA%\goodwin_obs\uploaded.json. Каждая запись:
# { name, size, sha1_head, dropbox_id, dropbox_path, uploaded_at }. Ключ дедупа: "name|size|sha1_head".
# SHA-1 считается по первым 1 МБ — достаточно для отсечения дублей, быстро на больших файлах.

function Get-FileDedupSignature {
    # Подпись = имя|размер|SHA1 по трём окнам (начало+середина+конец, по 256 КБ).
    # Несколько окон вместо «только первый мегабайт» убирают ложные совпадения
    # у видео с одинаковым заголовком контейнера.
    param([Parameter(Mandatory=$true)][string] $Path)
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($fi.Length -le 0) { return "{0}|{1}|empty" -f $fi.Name, $fi.Length }

        $win = [long]262144   # 256 КБ
        $offsets = @([long]0)
        if ($fi.Length -gt (2 * $win)) { $offsets += [long][math]::Floor($fi.Length / 2) }
        if ($fi.Length -gt $win)       { $offsets += [long]($fi.Length - $win) }
        $offsets = @($offsets | Sort-Object -Unique)

        $sha = [System.Security.Cryptography.SHA1]::Create()
        $fs  = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] $win
            foreach ($off in $offsets) {
                $fs.Position = $off
                $want = [int][math]::Min($win, ($fi.Length - $off))
                $read = $fs.Read($buf, 0, $want)
                if ($read -gt 0) { $null = $sha.TransformBlock($buf, 0, $read, $buf, 0) }
            }
            $null = $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $hex = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
            return "{0}|{1}|{2}" -f $fi.Name, $fi.Length, $hex
        }
        finally { $fs.Dispose(); $sha.Dispose() }
    } catch {
        # Если не смогли посчитать — отдаём имя+размер, лучше чем ничего (но логируем).
        $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($fi) {
            Write-Log "Подпись файла $($fi.Name) не посчитана, дедуп по имени+размеру: $($_.Exception.Message)"
            return "{0}|{1}|nohash" -f $fi.Name, $fi.Length
        }
        return $null
    }
}

function Load-UploadHistory {
    if (-not (Test-Path $script:UploadHistoryFile)) { return @{} }
    try {
        $raw = Get-Content -Raw -Path $script:UploadHistoryFile -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $arr = ConvertFrom-Json $raw
        $h = @{}
        foreach ($e in $arr) {
            if ($e.key) { $h[[string]$e.key] = $e }
        }
        return $h
    } catch {
        Write-Log "Не удалось прочитать uploaded.json: $($_.Exception.Message)"
        return @{}
    }
}

function Save-UploadHistory {
    param([hashtable] $History)
    try {
        $dir = Split-Path -Parent $script:UploadHistoryFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $arr = @($History.Values)
        $json = $arr | ConvertTo-Json -Depth 4 -Compress
        if (-not $json) { $json = '[]' }
        Write-TextFileAtomic -Path $script:UploadHistoryFile -Content $json
    } catch {
        Write-Log "Не удалось сохранить uploaded.json: $($_.Exception.Message)"
    }
}

function Add-UploadHistoryEntry {
    param(
        [Parameter(Mandatory=$true)][string] $Key,
        [Parameter(Mandatory=$true)][System.IO.FileInfo] $File,
        [string] $DropboxId,
        [string] $DropboxPath
    )
    $hist = Load-UploadHistory
    $hist[$Key] = [pscustomobject]@{
        key         = $Key
        name        = $File.Name
        size        = $File.Length
        dropbox_id  = $DropboxId
        dropbox_path = $DropboxPath
        uploaded_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-UploadHistory $hist
}

function Get-FileMd5 {
    param([Parameter(Mandatory=$true)][string] $Path)
    try {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $fs  = [IO.File]::OpenRead($Path)
        try {
            $hash = $md5.ComputeHash($fs)
            return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
        }
        finally { $fs.Dispose(); $md5.Dispose() }
    } catch {
        Write-Log "Не удалось посчитать MD5 для $($Path): $($_.Exception.Message)"
        return $null
    }
}

function Test-UploadedOnDropbox {
    # Проверяет в Dropbox точный путь файла в целевой папке. Если файл есть и размер
    # совпадает, считаем его уже загруженным. Возвращает $false при ошибке, чтобы
    # сетевая проблема не блокировала загрузку.
    # Возвращает $false при ошибке — чтобы сетевая проблема не блокировала загрузку.
    param(
        [Parameter(Mandatory=$true)][string] $AccessToken,
        [Parameter(Mandatory=$true)][System.IO.FileInfo] $File,
        [Parameter(Mandatory=$true)][long]   $Size,
        [string] $Path
    )
    try {
        $dropboxPath = Get-DropboxUploadPath -File $File
        $headers = @{ Authorization = "Bearer $AccessToken" }
        $resp = Invoke-RestMethod `
            -Method Post `
            -Uri 'https://api.dropboxapi.com/2/files/get_metadata' `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body (ConvertTo-DropboxApiJson @{ path = $dropboxPath; include_media_info = $false; include_deleted = $false; include_has_explicit_shared_members = $false })
        return ($resp -and $resp.'.tag' -eq 'file' -and [long]$resp.size -eq $Size)
    }
    catch {
        $detail = Get-WebExceptionDetail $_
        if ($detail.Body -and $detail.Body -match 'not_found') { return $false }
        Write-Log "Dropbox dedup check failed (продолжаем без удалённой проверки): $($_.Exception.Message)"
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CoreAudio: уровень микрофона через IAudioMeterInformation
# ═══════════════════════════════════════════════════════════════════════════════
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace GoodwinCoreAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out int pcDevices);
        [PreserveSig] int Item(int nDevice, out IMMDevice ppDevice);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        [PreserveSig] int Activate([MarshalAs(UnmanagedType.LPStruct)] Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        [PreserveSig] int GetState(out int pdwState);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pszVal;
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out int cProps);
        [PreserveSig] int GetAt(int iProp, out PROPERTYKEY pkey);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioMeterInformation {
        [PreserveSig] int GetPeakValue(out float pfPeak);
    }

    public static class AudioMeter {
        const int eCapture = 1;
        const int DEVICE_STATE_ACTIVE = 1;
        const int CLSCTX_INPROC_SERVER = 1;
        const int STGM_READ = 0;
        const ushort VT_LPWSTR = 31;

        static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY {
            fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
            pid = 14
        };

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PROPVARIANT pvar);

        public static float GetPeakByName(string name) {
            if (string.IsNullOrEmpty(name)) return GetDefaultCapturePeak();
            var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            try {
                IMMDeviceCollection col;
                if (en.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out col) != 0 || col == null) return 0f;
                try {
                    int count;
                    col.GetCount(out count);
                    for (int i = 0; i < count; i++) {
                        IMMDevice dev;
                        if (col.Item(i, out dev) != 0 || dev == null) continue;
                        try {
                            IPropertyStore props;
                            if (dev.OpenPropertyStore(STGM_READ, out props) != 0 || props == null) continue;
                            string fn = null;
                            try {
                                var key = PKEY_Device_FriendlyName;
                                PROPVARIANT pv;
                                if (props.GetValue(ref key, out pv) == 0) {
                                    try {
                                        if (pv.vt == VT_LPWSTR && pv.pszVal != IntPtr.Zero) {
                                            fn = Marshal.PtrToStringUni(pv.pszVal);
                                        }
                                    } finally { PropVariantClear(ref pv); }
                                }
                            } finally { Marshal.ReleaseComObject(props); }
                            if (fn == name) {
                                return GetPeakFromDevice(dev);
                            }
                        } finally { Marshal.ReleaseComObject(dev); }
                    }
                } finally { Marshal.ReleaseComObject(col); }
            } finally { Marshal.ReleaseComObject(en); }
            return 0f;
        }

        public static float GetDefaultCapturePeak() {
            var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            try {
                IMMDevice dev;
                if (en.GetDefaultAudioEndpoint(eCapture, 0, out dev) != 0 || dev == null) return 0f;
                try {
                    return GetPeakFromDevice(dev);
                } finally { Marshal.ReleaseComObject(dev); }
            } finally { Marshal.ReleaseComObject(en); }
        }

        // Уровень по точному MMDevice-id, БЕЗ перебора всех устройств — для таймера,
        // который раньше энумерировал все capture-устройства ~12 раз в секунду.
        public static float GetPeakById(string id) {
            if (string.IsNullOrEmpty(id)) return GetDefaultCapturePeak();
            var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            try {
                IMMDevice dev;
                if (en.GetDevice(id, out dev) != 0 || dev == null) return 0f;
                try {
                    return GetPeakFromDevice(dev);
                } finally { Marshal.ReleaseComObject(dev); }
            } finally { Marshal.ReleaseComObject(en); }
        }

        // Возвращает массив пар "FriendlyName|DeviceId" для всех активных
        // capture-устройств. Имя берём из IPropertyStore::PKEY_Device_FriendlyName —
        // ровно то же значение, которое использует OBS (например, "Микрофон (FIFINE K670 Microphone)").
        public static string[] EnumerateCaptureDevices() {
            var result = new System.Collections.Generic.List<string>();
            var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            try {
                IMMDeviceCollection col;
                if (en.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out col) != 0 || col == null) return result.ToArray();
                try {
                    int count;
                    col.GetCount(out count);
                    for (int i = 0; i < count; i++) {
                        IMMDevice dev;
                        if (col.Item(i, out dev) != 0 || dev == null) continue;
                        try {
                            string deviceId = null;
                            dev.GetId(out deviceId);

                            IPropertyStore props;
                            if (dev.OpenPropertyStore(STGM_READ, out props) != 0 || props == null) continue;
                            string fn = null;
                            try {
                                var key = PKEY_Device_FriendlyName;
                                PROPVARIANT pv;
                                if (props.GetValue(ref key, out pv) == 0) {
                                    try {
                                        if (pv.vt == VT_LPWSTR && pv.pszVal != IntPtr.Zero) {
                                            fn = Marshal.PtrToStringUni(pv.pszVal);
                                        }
                                    } finally { PropVariantClear(ref pv); }
                                }
                            } finally { Marshal.ReleaseComObject(props); }

                            if (!string.IsNullOrEmpty(fn) && !string.IsNullOrEmpty(deviceId)) {
                                result.Add(fn + "|" + deviceId);
                            }
                        } finally { Marshal.ReleaseComObject(dev); }
                    }
                } finally { Marshal.ReleaseComObject(col); }
            } finally { Marshal.ReleaseComObject(en); }
            return result.ToArray();
        }

        static float GetPeakFromDevice(IMMDevice dev) {
            object meterObj;
            var iid = typeof(IAudioMeterInformation).GUID;
            if (dev.Activate(iid, CLSCTX_INPROC_SERVER, IntPtr.Zero, out meterObj) != 0 || meterObj == null) return 0f;
            try {
                var meter = (IAudioMeterInformation)meterObj;
                float peak;
                if (meter.GetPeakValue(out peak) != 0) return 0f;
                return peak;
            } finally { Marshal.ReleaseComObject(meterObj); }
        }
    }
}
'@ -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════════════
# MCI: запись и воспроизведение для проверки микрофона
# ═══════════════════════════════════════════════════════════════════════════════
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MciWrapper {
    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    public static extern int mciSendString(string lpstrCommand, StringBuilder lpstrReturnString, int uReturnLength, IntPtr hwndCallback);
    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    public static extern bool mciGetErrorString(int errCode, StringBuilder lpstrBuffer, int uLength);
}
'@ -ErrorAction SilentlyContinue

function Get-MciError {
    param([int] $Code)
    $b = New-Object System.Text.StringBuilder 256
    [void][MciWrapper]::mciGetErrorString($Code, $b, 256)
    return $b.ToString()
}

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace GoodwinAudioTest {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, IntPtr ppDevices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        [PreserveSig] int Activate([MarshalAs(UnmanagedType.LPStruct)] Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, IntPtr ppProperties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        [PreserveSig] int GetState(out int pdwState);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioClient {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, ref Guid audioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint pNumBufferFrames);
        [PreserveSig] int GetStreamLatency(out long phnsLatency);
        [PreserveSig] int GetCurrentPadding(out uint pNumPaddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr ppDeviceFormat);
        [PreserveSig] int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioCaptureClient {
        [PreserveSig] int GetBuffer(out IntPtr ppData, out uint pNumFramesToRead, out uint pdwFlags, out ulong pu64DevicePosition, out ulong pu64QPCPosition);
        [PreserveSig] int ReleaseBuffer(uint NumFramesRead);
        [PreserveSig] int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }

    public static class WasapiRecorder {
        const int eCapture = 1;
        const int eConsole = 0;
        const int CLSCTX_ALL = 23;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
        const ushort WAVE_FORMAT_PCM = 1;
        const ushort WAVE_FORMAT_IEEE_FLOAT = 3;
        const ushort WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

        static readonly Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static readonly Guid IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        static readonly Guid SubtypePcm = new Guid("00000001-0000-0010-8000-00aa00389b71");
        static readonly Guid SubtypeFloat = new Guid("00000003-0000-0010-8000-00aa00389b71");

        class MixFormat {
            public ushort Tag;
            public ushort Channels;
            public int SampleRate;
            public ushort BlockAlign;
            public ushort BitsPerSample;
            public bool IsPcm;
            public bool IsFloat;
        }

        public static void CaptureToWav(string deviceId, string path, int milliseconds) {
            if (milliseconds < 1) milliseconds = 3000;
            object enumObj = null;
            IMMDevice dev = null;
            object clientObj = null;
            object captureObj = null;
            IntPtr formatPtr = IntPtr.Zero;

            try {
                enumObj = new MMDeviceEnumeratorComObject();
                var en = (IMMDeviceEnumerator)enumObj;
                int hr;
                if (string.IsNullOrEmpty(deviceId) || string.Equals(deviceId, "default", StringComparison.OrdinalIgnoreCase)) {
                    hr = en.GetDefaultAudioEndpoint(eCapture, eConsole, out dev);
                } else {
                    hr = en.GetDevice(deviceId, out dev);
                }
                CheckHr(hr, "Get audio capture device");
                if (dev == null) throw new InvalidOperationException("Audio capture device is not available.");

                hr = dev.Activate(IID_IAudioClient, CLSCTX_ALL, IntPtr.Zero, out clientObj);
                CheckHr(hr, "Activate IAudioClient");
                var client = (IAudioClient)clientObj;

                hr = client.GetMixFormat(out formatPtr);
                CheckHr(hr, "GetMixFormat");
                MixFormat fmt = ReadMixFormat(formatPtr);
                if (fmt.Channels == 0 || fmt.BlockAlign == 0 || fmt.SampleRate == 0) {
                    throw new InvalidOperationException("Unsupported audio capture format.");
                }

                Guid session = Guid.Empty;
                hr = client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10000000, 0, formatPtr, ref session);
                CheckHr(hr, "Initialize audio capture");

                Guid captureId = IID_IAudioCaptureClient;
                hr = client.GetService(ref captureId, out captureObj);
                CheckHr(hr, "Get IAudioCaptureClient");
                var capture = (IAudioCaptureClient)captureObj;

                using (var pcm = new MemoryStream()) {
                    CheckHr(client.Start(), "Start audio capture");
                    var sw = Stopwatch.StartNew();
                    try {
                        while (sw.ElapsedMilliseconds < milliseconds) {
                            uint packetFrames;
                            CheckHr(capture.GetNextPacketSize(out packetFrames), "GetNextPacketSize");
                            if (packetFrames == 0) {
                                Thread.Sleep(10);
                                continue;
                            }

                            while (packetFrames > 0) {
                                IntPtr data;
                                uint frames;
                                uint flags;
                                ulong devPos;
                                ulong qpcPos;
                                CheckHr(capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos), "GetBuffer");
                                try {
                                    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == IntPtr.Zero) {
                                        WriteSilence(pcm, frames, fmt.Channels);
                                    } else {
                                        int byteCount = checked((int)(frames * fmt.BlockAlign));
                                        byte[] raw = new byte[byteCount];
                                        Marshal.Copy(data, raw, 0, raw.Length);
                                        ConvertToPcm16(raw, frames, fmt, pcm);
                                    }
                                } finally {
                                    CheckHr(capture.ReleaseBuffer(frames), "ReleaseBuffer");
                                }
                                CheckHr(capture.GetNextPacketSize(out packetFrames), "GetNextPacketSize");
                            }
                        }
                    } finally {
                        try { client.Stop(); } catch { }
                    }

                    WritePcm16Wave(path, fmt.SampleRate, fmt.Channels, pcm.ToArray());
                }
            } finally {
                if (formatPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(formatPtr);
                if (captureObj != null) { try { Marshal.ReleaseComObject(captureObj); } catch { } }
                if (clientObj != null) { try { Marshal.ReleaseComObject(clientObj); } catch { } }
                if (dev != null) { try { Marshal.ReleaseComObject(dev); } catch { } }
                if (enumObj != null) { try { Marshal.ReleaseComObject(enumObj); } catch { } }
            }
        }

        static MixFormat ReadMixFormat(IntPtr ptr) {
            var fmt = new MixFormat();
            fmt.Tag = unchecked((ushort)Marshal.ReadInt16(ptr, 0));
            fmt.Channels = unchecked((ushort)Marshal.ReadInt16(ptr, 2));
            fmt.SampleRate = Marshal.ReadInt32(ptr, 4);
            fmt.BlockAlign = unchecked((ushort)Marshal.ReadInt16(ptr, 12));
            fmt.BitsPerSample = unchecked((ushort)Marshal.ReadInt16(ptr, 14));
            fmt.IsPcm = fmt.Tag == WAVE_FORMAT_PCM;
            fmt.IsFloat = fmt.Tag == WAVE_FORMAT_IEEE_FLOAT;
            if (fmt.Tag == WAVE_FORMAT_EXTENSIBLE) {
                byte[] guidBytes = new byte[16];
                Marshal.Copy(IntPtr.Add(ptr, 24), guidBytes, 0, guidBytes.Length);
                Guid sub = new Guid(guidBytes);
                fmt.IsPcm = sub == SubtypePcm;
                fmt.IsFloat = sub == SubtypeFloat;
            }
            return fmt;
        }

        static void ConvertToPcm16(byte[] raw, uint frames, MixFormat fmt, Stream output) {
            int channels = Math.Max(1, (int)fmt.Channels);
            int bytesPerSample = Math.Max(1, (int)fmt.BitsPerSample / 8);
            int blockAlign = fmt.BlockAlign;
            for (uint frame = 0; frame < frames; frame++) {
                int frameOffset = checked((int)frame * blockAlign);
                for (int ch = 0; ch < channels; ch++) {
                    int offset = frameOffset + (ch * bytesPerSample);
                    short sample = 0;
                    if (offset + bytesPerSample <= raw.Length) {
                        sample = ConvertSample(raw, offset, fmt);
                    }
                    output.WriteByte((byte)(sample & 0xFF));
                    output.WriteByte((byte)((sample >> 8) & 0xFF));
                }
            }
        }

        static short ConvertSample(byte[] raw, int offset, MixFormat fmt) {
            if (fmt.IsFloat && fmt.BitsPerSample == 32) {
                float f = BitConverter.ToSingle(raw, offset);
                if (f > 1f) f = 1f;
                if (f < -1f) f = -1f;
                return (short)(f * 32767f);
            }
            if (fmt.IsFloat && fmt.BitsPerSample == 64) {
                double d = BitConverter.ToDouble(raw, offset);
                if (d > 1.0) d = 1.0;
                if (d < -1.0) d = -1.0;
                return (short)(d * 32767.0);
            }
            if (!fmt.IsPcm) return 0;
            switch (fmt.BitsPerSample) {
                case 8:
                    return (short)((raw[offset] - 128) << 8);
                case 16:
                    return BitConverter.ToInt16(raw, offset);
                case 24:
                    int v24 = raw[offset] | (raw[offset + 1] << 8) | (raw[offset + 2] << 16);
                    if ((v24 & 0x800000) != 0) v24 |= unchecked((int)0xFF000000);
                    return (short)(v24 >> 8);
                case 32:
                    int v32 = BitConverter.ToInt32(raw, offset);
                    return (short)(v32 >> 16);
                default:
                    return 0;
            }
        }

        static void WriteSilence(Stream output, uint frames, ushort channels) {
            int count = checked((int)(frames * Math.Max(1, (int)channels) * 2));
            for (int i = 0; i < count; i++) output.WriteByte(0);
        }

        static void WritePcm16Wave(string path, int sampleRate, ushort channels, byte[] data) {
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var bw = new BinaryWriter(fs)) {
                ushort blockAlign = (ushort)(channels * 2);
                int byteRate = sampleRate * blockAlign;
                bw.Write(new char[] { 'R', 'I', 'F', 'F' });
                bw.Write(36 + data.Length);
                bw.Write(new char[] { 'W', 'A', 'V', 'E' });
                bw.Write(new char[] { 'f', 'm', 't', ' ' });
                bw.Write(16);
                bw.Write((ushort)1);
                bw.Write(channels);
                bw.Write(sampleRate);
                bw.Write(byteRate);
                bw.Write(blockAlign);
                bw.Write((ushort)16);
                bw.Write(new char[] { 'd', 'a', 't', 'a' });
                bw.Write(data.Length);
                bw.Write(data);
            }
        }

        static void CheckHr(int hr, string operation) {
            if (hr < 0) {
                throw new InvalidOperationException(operation + " failed: HRESULT 0x" + hr.ToString("X8"), Marshal.GetExceptionForHR(hr));
            }
        }
    }
}
'@ -ErrorAction SilentlyContinue

function Start-MicrophoneTest {
    param(
        [int] $DurationSec = 3,
        [string] $DeviceId = 'default'
    )
    $tempWav = Join-Path $env:TEMP 'goodwin_mic_test.wav'
    $sb = New-Object System.Text.StringBuilder 256
    if (Test-Path $tempWav) { Remove-Item -LiteralPath $tempWav -Force -ErrorAction SilentlyContinue }

    $playTestFile = {
        param([string] $Path)
        if (Test-Path $Path) {
            $player = New-Object System.Media.SoundPlayer
            try {
                $player.SoundLocation = $Path
                $player.PlaySync()
            }
            finally {
                $player.Dispose()
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $normalizedDeviceId = if ([string]::IsNullOrWhiteSpace($DeviceId)) { 'default' } else { $DeviceId }
    try {
        [GoodwinAudioTest.WasapiRecorder]::CaptureToWav($normalizedDeviceId, $tempWav, [math]::Max(1, $DurationSec) * 1000)
        & $playTestFile $tempWav
        return
    } catch {
        if ($normalizedDeviceId -ne 'default') {
            throw
        }
        Write-Log "WASAPI-тест микрофона не удался, пробуем MCI: $($_.Exception.Message)"
    }

    # Гарантируем, что alias 'mic_test' будет закрыт даже если record/save выкинут исключение —
    # иначе MCI-устройство остаётся открытым и следующий тест валится.
    [MciWrapper]::mciSendString('close mic_test', $sb, 256, [IntPtr]::Zero) | Out-Null
    $rcOpen = [MciWrapper]::mciSendString('open new type waveaudio alias mic_test', $sb, 256, [IntPtr]::Zero)
    if ($rcOpen -ne 0) {
        throw "Не удалось открыть устройство записи (MCI ${rcOpen}: $(Get-MciError $rcOpen))."
    }
    try {
        [MciWrapper]::mciSendString('set mic_test bitspersample 16 channels 1 samplespersec 44100 format tag pcm', $sb, 256, [IntPtr]::Zero) | Out-Null
        $rcRec = [MciWrapper]::mciSendString('record mic_test', $sb, 256, [IntPtr]::Zero)
        if ($rcRec -ne 0) {
            throw "Не удалось начать запись с микрофона (MCI ${rcRec}: $(Get-MciError $rcRec)). Возможно, устройство занято или не подключено."
        }
        Start-Sleep -Seconds $DurationSec
        [MciWrapper]::mciSendString('stop mic_test', $sb, 256, [IntPtr]::Zero) | Out-Null
        [MciWrapper]::mciSendString("save mic_test `"$tempWav`"", $sb, 256, [IntPtr]::Zero) | Out-Null
    }
    finally {
        [MciWrapper]::mciSendString('close mic_test', $sb, 256, [IntPtr]::Zero) | Out-Null
    }
    & $playTestFile $tempWav
}

# ═══════════════════════════════════════════════════════════════════════════════
# DirectShow: живой предпросмотр камеры в окне (HWND нашей панели)
# ═══════════════════════════════════════════════════════════════════════════════
Add-Type -ReferencedAssemblies System.Runtime.InteropServices -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace GoodwinCam {
    // Маркер IBaseFilter — нужен, чтобы COM-маршаллер делал правильный
    // QueryInterface(IBaseFilter) при передаче фильтра в AddFilter/RenderStream.
    // Без него передавался IUnknown*, и AddFilter падал с AccessViolation,
    // потому что у IUnknown и IBaseFilter разные vtable.
    [ComImport, Guid("56A86895-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IBaseFilter { }

    [ComImport, Guid("56A868A9-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IGraphBuilder {
        [PreserveSig] int AddFilter([In] IBaseFilter pFilter, [MarshalAs(UnmanagedType.LPWStr)] string pName);
    }

    [ComImport, Guid("93E5A4E0-2D50-11D2-ABFA-00A0C9C6E38D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ICaptureGraphBuilder2 {
        // Все параметры строго типизированы — у IGraphBuilder и IBaseFilter
        // свои vtable, и без явного QI ICaptureGraphBuilder2 тихо ломается.
        [PreserveSig] int SetFiltergraph([In] IGraphBuilder pfg);
        [PreserveSig] int _GetFiltergraph_NotUsed();
        [PreserveSig] int _SetOutputFileName_NotUsed();
        [PreserveSig] int _FindInterface_NotUsed();
        [PreserveSig] int RenderStream([In, MarshalAs(UnmanagedType.LPStruct)] Guid pCategory, [In, MarshalAs(UnmanagedType.LPStruct)] Guid pType, [In, MarshalAs(UnmanagedType.IUnknown)] object pSource, [In] IBaseFilter pfCompressor, [In] IBaseFilter pfRenderer);
    }

    [ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ICreateDevEnum {
        [PreserveSig] int CreateClassEnumerator([In] ref Guid clsidDeviceClass, out IEnumMoniker ppEnumMoniker, int dwFlags);
    }

    [ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyBag {
        [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string pszPropName, [In, Out, MarshalAs(UnmanagedType.Struct)] ref object pVar, IntPtr pErrorLog);
        [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string pszPropName, [In, MarshalAs(UnmanagedType.Struct)] ref object pVar);
    }

    // IMediaControl — IDispatch (4) + 3 нужных метода
    [ComImport, Guid("56A868B1-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMediaControl {
        [PreserveSig] int _GetTypeInfoCount();
        [PreserveSig] int _GetTypeInfo();
        [PreserveSig] int _GetIDsOfNames();
        [PreserveSig] int _Invoke();
        [PreserveSig] int Run();
        [PreserveSig] int Pause();
        [PreserveSig] int Stop();
    }

    // IVideoWindow — IDispatch (4) + полная vtable до SetWindowPosition
    [ComImport, Guid("56A868B4-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IVideoWindow {
        [PreserveSig] int _GetTypeInfoCount();
        [PreserveSig] int _GetTypeInfo();
        [PreserveSig] int _GetIDsOfNames();
        [PreserveSig] int _Invoke();
        [PreserveSig] int put_Caption([MarshalAs(UnmanagedType.BStr)] string s);
        [PreserveSig] int get_Caption([MarshalAs(UnmanagedType.BStr)] out string s);
        [PreserveSig] int put_WindowStyle(int v);
        [PreserveSig] int get_WindowStyle(out int v);
        [PreserveSig] int put_WindowStyleEx(int v);
        [PreserveSig] int get_WindowStyleEx(out int v);
        [PreserveSig] int put_AutoShow(int v);
        [PreserveSig] int get_AutoShow(out int v);
        [PreserveSig] int put_WindowState(int v);
        [PreserveSig] int get_WindowState(out int v);
        [PreserveSig] int put_BackgroundPalette(int v);
        [PreserveSig] int get_BackgroundPalette(out int v);
        [PreserveSig] int put_Visible(int v);
        [PreserveSig] int get_Visible(out int v);
        [PreserveSig] int put_Left(int v);
        [PreserveSig] int get_Left(out int v);
        [PreserveSig] int put_Width(int v);
        [PreserveSig] int get_Width(out int v);
        [PreserveSig] int put_Top(int v);
        [PreserveSig] int get_Top(out int v);
        [PreserveSig] int put_Height(int v);
        [PreserveSig] int get_Height(out int v);
        [PreserveSig] int put_Owner(IntPtr o);
        [PreserveSig] int get_Owner(out IntPtr o);
        [PreserveSig] int put_MessageDrain(IntPtr d);
        [PreserveSig] int get_MessageDrain(out IntPtr d);
        [PreserveSig] int get_BorderColor(out int c);
        [PreserveSig] int put_BorderColor(int c);
        [PreserveSig] int get_FullScreenMode(out int m);
        [PreserveSig] int put_FullScreenMode(int m);
        [PreserveSig] int SetWindowForeground(int Focus);
        [PreserveSig] int NotifyOwnerMessage(IntPtr hwnd, int msg, IntPtr wparam, IntPtr lparam);
        [PreserveSig] int SetWindowPosition(int Left, int Top, int Width, int Height);
    }

    public static class CameraPreview {
        static readonly Guid CLSID_FilterGraph              = new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770");
        static readonly Guid CLSID_CaptureGraphBuilder      = new Guid("BF87B6E1-8C27-11D0-B3F0-00AA003761C5");
        static readonly Guid CLSID_SystemDeviceEnum         = new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86");
        static readonly Guid CLSID_VideoInputDeviceCategory = new Guid("860BB310-5D01-11D0-BD3B-00A0C911CE86");
        static readonly Guid PIN_CATEGORY_PREVIEW           = new Guid("FB6C4281-0353-11D1-905F-0000C0CC16BA");
        static readonly Guid PIN_CATEGORY_CAPTURE           = new Guid("FB6C4280-0353-11D1-905F-0000C0CC16BA");
        static readonly Guid MEDIATYPE_Video                = new Guid("73646976-0000-0010-8000-00AA00389B71");
        static readonly Guid IID_IPropertyBag               = new Guid("55272A00-42CB-11CE-8135-00AA004BB851");
        static readonly Guid IID_IBaseFilter                = new Guid("56A86895-0AD4-11CE-B03A-0020AF0BA770");

        const int WS_CHILD        = 0x40000000;
        const int WS_CLIPCHILDREN = 0x02000000;
        const int WS_CLIPSIBLINGS = 0x04000000;
        const int OATRUE  = -1;
        const int OAFALSE = 0;

        static object _graph;
        static object _builder;
        static IBaseFilter _filter;
        static IntPtr _hwnd;

        // Возвращает имена всех видеовходов в том же виде, в каком их видит OBS
        // (через DirectShow System Device Enumerator).
        public static string[] EnumerateVideoDevices() {
            var result = new System.Collections.Generic.List<string>();
            object devEnum = null;
            try {
                devEnum = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_SystemDeviceEnum));
                Guid cat = CLSID_VideoInputDeviceCategory;
                IEnumMoniker enumMon;
                ((ICreateDevEnum)devEnum).CreateClassEnumerator(ref cat, out enumMon, 0);
                if (enumMon != null) {
                    try {
                        IMoniker[] arr = new IMoniker[1];
                        while (enumMon.Next(1, arr, IntPtr.Zero) == 0 && arr[0] != null) {
                            try {
                                Guid bagIid = IID_IPropertyBag;
                                object bagObj;
                                arr[0].BindToStorage(null, null, ref bagIid, out bagObj);
                                IPropertyBag bag = (IPropertyBag)bagObj;
                                object friendly = null;
                                bag.Read("FriendlyName", ref friendly, IntPtr.Zero);
                                Marshal.ReleaseComObject(bag);
                                string fn = friendly as string;
                                if (!string.IsNullOrEmpty(fn)) {
                                    result.Add(fn);
                                }
                            } catch { }
                            Marshal.ReleaseComObject(arr[0]);
                            arr[0] = null;
                        }
                    } finally { Marshal.ReleaseComObject(enumMon); }
                }
            } catch { }
            finally {
                if (devEnum != null) { try { Marshal.ReleaseComObject(devEnum); } catch { } }
            }
            return result.ToArray();
        }

        public static void Start(string deviceName, IntPtr hwnd, int width, int height) {
            Stop();
            try {
                _hwnd = hwnd;
                _graph   = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_FilterGraph));
                _builder = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_CaptureGraphBuilder));
                object devEnum = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_SystemDeviceEnum));

                ((ICaptureGraphBuilder2)_builder).SetFiltergraph((IGraphBuilder)_graph);

                Guid cat = CLSID_VideoInputDeviceCategory;
                IEnumMoniker enumMon;
                ((ICreateDevEnum)devEnum).CreateClassEnumerator(ref cat, out enumMon, 0);

                if (enumMon != null) {
                    IMoniker[] arr = new IMoniker[1];
                    while (enumMon.Next(1, arr, IntPtr.Zero) == 0 && arr[0] != null) {
                        bool matched = false;
                        try {
                            Guid bagIid = IID_IPropertyBag;
                            object bagObj;
                            arr[0].BindToStorage(null, null, ref bagIid, out bagObj);
                            IPropertyBag bag = (IPropertyBag)bagObj;
                            object friendly = null;
                            bag.Read("FriendlyName", ref friendly, IntPtr.Zero);
                            Marshal.ReleaseComObject(bag);
                            string fn = friendly as string;
                            if (fn != null && string.Equals(fn, deviceName, StringComparison.OrdinalIgnoreCase)) {
                                Guid filterIid = IID_IBaseFilter;
                                object filterObj;
                                arr[0].BindToObject(null, null, ref filterIid, out filterObj);
                                _filter = (IBaseFilter)filterObj;   // RCW делает QI(IBaseFilter) с правильным vtable
                                matched = true;
                            }
                        } catch { }
                        Marshal.ReleaseComObject(arr[0]);
                        arr[0] = null;
                        if (matched) break;
                    }
                    Marshal.ReleaseComObject(enumMon);
                }
                Marshal.ReleaseComObject(devEnum);

                if (_filter == null) {
                    throw new InvalidOperationException("Камера не найдена: " + deviceName);
                }

                ((IGraphBuilder)_graph).AddFilter(_filter, "Source");

                Guid pinCat = PIN_CATEGORY_PREVIEW;
                Guid mediaType = MEDIATYPE_Video;
                int hr = ((ICaptureGraphBuilder2)_builder).RenderStream(pinCat, mediaType, _filter, null, null);
                if (hr < 0) {
                    pinCat = PIN_CATEGORY_CAPTURE;
                    hr = ((ICaptureGraphBuilder2)_builder).RenderStream(pinCat, mediaType, _filter, null, null);
                    if (hr < 0) {
                        throw new InvalidOperationException("Не удалось построить граф предпросмотра (HRESULT 0x" + hr.ToString("X8") + ")");
                    }
                }

                IVideoWindow vw = (IVideoWindow)_graph;
                vw.put_Owner(hwnd);
                vw.put_WindowStyle(WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);
                vw.SetWindowPosition(0, 0, width, height);
                vw.put_Visible(OATRUE);

                ((IMediaControl)_graph).Run();
            } catch {
                Stop();
                throw;
            }
        }

        public static void Resize(int width, int height) {
            try {
                if (_graph != null) {
                    ((IVideoWindow)_graph).SetWindowPosition(0, 0, width, height);
                }
            } catch { }
        }

        public static void Stop() {
            try { if (_graph != null) ((IMediaControl)_graph).Stop(); } catch { }
            try {
                if (_graph != null) {
                    IVideoWindow vw = (IVideoWindow)_graph;
                    vw.put_Visible(OAFALSE);
                    vw.put_Owner(IntPtr.Zero);
                }
            } catch { }
            if (_filter  != null) { try { Marshal.ReleaseComObject(_filter); } catch { } _filter = null; }
            if (_builder != null) { try { Marshal.ReleaseComObject(_builder); } catch { } _builder = null; }
            if (_graph   != null) { try { Marshal.ReleaseComObject(_graph); } catch { } _graph = null; }
            _hwnd = IntPtr.Zero;
        }
    }
}
'@ -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════════════
# Перечисление устройств
# ═══════════════════════════════════════════════════════════════════════════════
function Get-CameraList {
    # Возвращаем имена видеовходов, которые отдаёт DirectShow System Device Enumerator —
    # ровно то же, что показывает OBS (DroidCam, FIFINE, встроенная веб-камера, и т.д.).
    # Виртуальные камеры (OBS Virtual Camera) намеренно НЕ скрываем, потому что OBS их тоже показывает.
    $list = @()
    try {
        $list = @([GoodwinCam.CameraPreview]::EnumerateVideoDevices())
    } catch {
        Write-Log "Перечисление камер не удалось: $($_.Exception.Message)"
    }
    return $list | Where-Object { $_ } | Sort-Object -Unique
}

function Get-MicrophoneList {
    # Подключённые микрофоны под именами, которые показывает OBS
    # (через GoodwinCoreAudio.AudioMeter::EnumerateCaptureDevices()).
    $list = @((Get-MicrophoneDeviceMap).Keys)
    return $list | Where-Object { $_ } | Sort-Object -Unique
}

# ═══════════════════════════════════════════════════════════════════════════════
# GUI
# ═══════════════════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── Состояние и загрузка сохранённых настроек ──────────────────────────────
$script:SelectedCamera   = $null
$script:SelectedMic      = $null
$script:SelectedNickname = $null

$loaded = Load-LocalSettings
if ($loaded.ContainsKey('nickname'))      { $script:SelectedNickname = [string]$loaded['nickname'] }
if ($loaded.ContainsKey('camera'))        { $script:SelectedCamera   = [string]$loaded['camera'] }
if ($loaded.ContainsKey('mic'))           { $script:SelectedMic      = [string]$loaded['mic'] }
if ($loaded.ContainsKey('recordingRoot') -and -not [string]::IsNullOrWhiteSpace([string]$loaded['recordingRoot'])) {
    $script:RecordingRoot = [string]$loaded['recordingRoot']
    $script:RecordingDir  = $script:RecordingRoot
}
if ([string]::IsNullOrWhiteSpace($script:SelectedNickname)) {
    $script:SelectedNickname = 'untitled'
}

# ── Иконка приложения ──────────────────────────────────────────────────────
# Сборка мультиразмерной .ico (16/24/32/48/64/128/256) из локально рисуемого
# значка в стиле UI-иконок. Так приложение не зависит от внешних картинок.
function New-AppIconBitmap {
    param([Parameter(Mandatory = $true)][int] $Size)

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $bg = $null; $accent = $null; $pen = $null
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        $s = [single]$Size
        $radius = [single]($s * 0.22)
        $rect = New-Object System.Drawing.RectangleF -ArgumentList 1.0, 1.0, ($s - 2.0), ($s - 2.0)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            $d = [single]($radius * 2.0)
            $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
            $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
            $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
            $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
            $path.CloseFigure()

            $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $rect,
                [System.Drawing.Color]::FromArgb(12, 74, 110),
                [System.Drawing.Color]::FromArgb(20, 111, 60),
                [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
            )
            $g.FillPath($bg, $path)
        }
        finally {
            if ($path) { $path.Dispose() }
        }

        $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(186, 230, 253))
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(186, 230, 253), [math]::Max(1.4, $s / 12.0))
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

        $screen = New-Object System.Drawing.RectangleF -ArgumentList ($s*0.18), ($s*0.24), ($s*0.64), ($s*0.44)
        $g.DrawRectangle($pen, $screen.X, $screen.Y, $screen.Width, $screen.Height)
        $g.DrawLine($pen, $s*0.40, $s*0.80, $s*0.60, $s*0.80)
        $g.DrawLine($pen, $s*0.50, $s*0.68, $s*0.50, $s*0.80)

        $pts = @(
            (New-Object System.Drawing.PointF -ArgumentList ($s*0.45), ($s*0.36)),
            (New-Object System.Drawing.PointF -ArgumentList ($s*0.45), ($s*0.56)),
            (New-Object System.Drawing.PointF -ArgumentList ($s*0.62), ($s*0.46))
        )
        $g.FillPolygon($accent, [System.Drawing.PointF[]]$pts)
    }
    finally {
        if ($pen) { $pen.Dispose() }
        if ($accent) { $accent.Dispose() }
        if ($bg) { $bg.Dispose() }
        if ($g) { $g.Dispose() }
    }

    return $bmp
}

function Get-AppIcon {
    try {
        $sizes = @(16, 24, 32, 48, 64, 128, 256)
        $entries = @()
        foreach ($sz in $sizes) {
            $bmp = $null; $bms = $null
            try {
                $bmp = New-AppIconBitmap -Size $sz
                $bms = New-Object IO.MemoryStream
                $bmp.Save($bms, [System.Drawing.Imaging.ImageFormat]::Png)
                $entries += [pscustomobject]@{ Size = $sz; Data = $bms.ToArray() }
            }
            finally {
                if ($bmp) { $bmp.Dispose() }
                if ($bms) { $bms.Dispose() }
            }
        }

        $out = New-Object IO.MemoryStream
        $bw  = New-Object IO.BinaryWriter($out)
        try {
            $bw.Write([uint16]0)
            $bw.Write([uint16]1)
            $bw.Write([uint16]$entries.Count)
            $dataOffset = 6 + 16 * $entries.Count
            foreach ($e in $entries) {
                $dim = if ($e.Size -ge 256) { 0 } else { [byte]$e.Size }
                $bw.Write([byte]$dim)
                $bw.Write([byte]$dim)
                $bw.Write([byte]0)
                $bw.Write([byte]0)
                $bw.Write([uint16]1)
                $bw.Write([uint16]32)
                $bw.Write([uint32]$e.Data.Length)
                $bw.Write([uint32]$dataOffset)
                $dataOffset += $e.Data.Length
            }
            foreach ($e in $entries) { $bw.Write($e.Data) }
            $bw.Flush()
            $icoBytes = $out.ToArray()
        }
        finally {
            $bw.Close()
        }

        $icoMs = New-Object IO.MemoryStream (,$icoBytes)
        return [System.Drawing.Icon]::new($icoMs)
    }
    catch {
        Write-Log ('Не удалось собрать локальную иконку: ' + $_.Exception.Message)
        return $null
    }
}
$script:AppIcon = Get-AppIcon

# ── Форма ──────────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Goodwin OBS'
if ($script:AppIcon) { $form.Icon = $script:AppIcon }
$form.ClientSize = New-Object System.Drawing.Size(860, 324)
$form.MinimumSize = New-Object System.Drawing.Size(880, 364)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(14, 17, 22)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$colorBg       = [System.Drawing.Color]::FromArgb(14, 17, 22)
$colorPanel    = [System.Drawing.Color]::FromArgb(25, 30, 39)
$colorPanel2   = [System.Drawing.Color]::FromArgb(20, 24, 32)
$colorInput    = [System.Drawing.Color]::FromArgb(31, 37, 48)
$colorText     = [System.Drawing.Color]::FromArgb(238, 242, 247)
$colorMuted    = [System.Drawing.Color]::FromArgb(154, 164, 178)
$colorBorder   = [System.Drawing.Color]::FromArgb(50, 59, 74)
$colorAccent   = [System.Drawing.Color]::FromArgb(56, 189, 248)
$colorGreen    = [System.Drawing.Color]::FromArgb(34, 197, 94)
$colorBlue     = [System.Drawing.Color]::FromArgb(59, 130, 246)
$colorAmber    = [System.Drawing.Color]::FromArgb(245, 158, 11)
$colorDanger   = [System.Drawing.Color]::FromArgb(239, 68, 68)
$script:UiImages = New-Object System.Collections.Generic.List[object]
$script:ToolTip = New-Object System.Windows.Forms.ToolTip
$script:ToolTip.AutoPopDelay = 8000
$script:ToolTip.InitialDelay = 350
$script:ToolTip.ReshowDelay = 100

function New-IconBitmap {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('brand','install','play','upload','folder','refresh','trash','edit','gear','mic','camera','logs')][string] $Kind,
        [System.Drawing.Color] $Color = [System.Drawing.Color]::White,
        [int] $Size = 22
    )

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $pen = $null
    $brush = $null
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $pen = New-Object System.Drawing.Pen($Color, [math]::Max(2.0, $Size / 11.0))
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $brush = New-Object System.Drawing.SolidBrush($Color)

        $s = [single]$Size
        $u = {
            param([double] $Value)
            return [single]($s * $Value)
        }
        $pt = {
            param([double] $X, [double] $Y)
            return New-Object System.Drawing.PointF -ArgumentList (& $u $X), (& $u $Y)
        }
        $rect = {
            param([double] $X, [double] $Y, [double] $W, [double] $H)
            return New-Object System.Drawing.RectangleF -ArgumentList (& $u $X), (& $u $Y), (& $u $W), (& $u $H)
        }

        switch ($Kind) {
            'brand' {
                $r = & $rect 0.16 0.20 0.68 0.48
                $g.DrawRectangle($pen, $r.X, $r.Y, $r.Width, $r.Height)
                $g.DrawLine($pen, $s*0.40, $s*0.80, $s*0.60, $s*0.80)
                $g.DrawLine($pen, $s*0.50, $s*0.68, $s*0.50, $s*0.80)
                $pts = @(
                    (& $pt 0.45 0.34),
                    (& $pt 0.45 0.54),
                    (& $pt 0.61 0.44)
                )
                $g.FillPolygon($brush, [System.Drawing.PointF[]]$pts)
            }
            'install' {
                $g.DrawLine($pen, $s*0.50, $s*0.16, $s*0.50, $s*0.58)
                $g.DrawLine($pen, $s*0.32, $s*0.42, $s*0.50, $s*0.60)
                $g.DrawLine($pen, $s*0.68, $s*0.42, $s*0.50, $s*0.60)
                $g.DrawLine($pen, $s*0.22, $s*0.78, $s*0.78, $s*0.78)
                $g.DrawLine($pen, $s*0.22, $s*0.68, $s*0.22, $s*0.78)
                $g.DrawLine($pen, $s*0.78, $s*0.68, $s*0.78, $s*0.78)
            }
            'play' {
                $pts = @(
                    (& $pt 0.32 0.22),
                    (& $pt 0.32 0.78),
                    (& $pt 0.78 0.50)
                )
                $g.FillPolygon($brush, [System.Drawing.PointF[]]$pts)
            }
            'upload' {
                $g.DrawLine($pen, $s*0.50, $s*0.18, $s*0.50, $s*0.62)
                $g.DrawLine($pen, $s*0.32, $s*0.36, $s*0.50, $s*0.18)
                $g.DrawLine($pen, $s*0.68, $s*0.36, $s*0.50, $s*0.18)
                $g.DrawLine($pen, $s*0.22, $s*0.70, $s*0.78, $s*0.70)
                $g.DrawLine($pen, $s*0.22, $s*0.70, $s*0.22, $s*0.82)
                $g.DrawLine($pen, $s*0.78, $s*0.70, $s*0.78, $s*0.82)
                $g.DrawLine($pen, $s*0.22, $s*0.82, $s*0.78, $s*0.82)
            }
            'folder' {
                $pts = @(
                    (& $pt 0.14 0.30),
                    (& $pt 0.36 0.30),
                    (& $pt 0.44 0.40),
                    (& $pt 0.86 0.40),
                    (& $pt 0.86 0.78),
                    (& $pt 0.14 0.78)
                )
                $g.DrawPolygon($pen, [System.Drawing.PointF[]]$pts)
                $g.DrawLine($pen, $s*0.14, $s*0.48, $s*0.86, $s*0.48)
            }
            'refresh' {
                $g.DrawArc($pen, $s*0.18, $s*0.18, $s*0.64, $s*0.64, 42, 282)
                $head = @(
                    (& $pt 0.82 0.22),
                    (& $pt 0.82 0.48),
                    (& $pt 0.62 0.34)
                )
                $g.FillPolygon($brush, [System.Drawing.PointF[]]$head)
            }
            'trash' {
                $g.DrawLine($pen, $s*0.32, $s*0.26, $s*0.68, $s*0.26)
                $g.DrawLine($pen, $s*0.42, $s*0.18, $s*0.58, $s*0.18)
                $g.DrawRectangle($pen, $s*0.28, $s*0.34, $s*0.44, $s*0.46)
                $g.DrawLine($pen, $s*0.42, $s*0.44, $s*0.42, $s*0.70)
                $g.DrawLine($pen, $s*0.58, $s*0.44, $s*0.58, $s*0.70)
            }
            'edit' {
                $g.DrawLine($pen, $s*0.24, $s*0.72, $s*0.66, $s*0.30)
                $g.DrawLine($pen, $s*0.58, $s*0.22, $s*0.76, $s*0.40)
                $g.DrawLine($pen, $s*0.20, $s*0.80, $s*0.38, $s*0.76)
            }
            'gear' {
                $cx = [single]($s * 0.50)
                $cy = [single]($s * 0.50)
                for ($a = 0; $a -lt 360; $a += 45) {
                    $rad = [Math]::PI * $a / 180.0
                    $x1 = [single]($cx + [Math]::Cos($rad) * $s * 0.31)
                    $y1 = [single]($cy + [Math]::Sin($rad) * $s * 0.31)
                    $x2 = [single]($cx + [Math]::Cos($rad) * $s * 0.43)
                    $y2 = [single]($cy + [Math]::Sin($rad) * $s * 0.43)
                    $g.DrawLine($pen, $x1, $y1, $x2, $y2)
                }
                $g.DrawEllipse($pen, $s*0.25, $s*0.25, $s*0.50, $s*0.50)
                $g.DrawEllipse($pen, $s*0.42, $s*0.42, $s*0.16, $s*0.16)
            }
            'mic' {
                $g.DrawArc($pen, $s*0.38, $s*0.14, $s*0.24, $s*0.18, 180, 180)
                $g.DrawLine($pen, $s*0.38, $s*0.23, $s*0.38, $s*0.48)
                $g.DrawLine($pen, $s*0.62, $s*0.23, $s*0.62, $s*0.48)
                $g.DrawArc($pen, $s*0.38, $s*0.39, $s*0.24, $s*0.18, 0, 180)
                $g.DrawArc($pen, $s*0.24, $s*0.34, $s*0.52, $s*0.34, 0, 180)
                $g.DrawLine($pen, $s*0.50, $s*0.70, $s*0.50, $s*0.84)
                $g.DrawLine($pen, $s*0.36, $s*0.84, $s*0.64, $s*0.84)
            }
            'camera' {
                $g.DrawRectangle($pen, $s*0.16, $s*0.28, $s*0.54, $s*0.44)
                $pts = @(
                    (& $pt 0.70 0.42),
                    (& $pt 0.86 0.32),
                    (& $pt 0.86 0.68),
                    (& $pt 0.70 0.58)
                )
                $g.DrawPolygon($pen, [System.Drawing.PointF[]]$pts)
            }
            'logs' {
                $g.DrawRectangle($pen, $s*0.24, $s*0.16, $s*0.52, $s*0.68)
                $g.DrawLine($pen, $s*0.36, $s*0.34, $s*0.64, $s*0.34)
                $g.DrawLine($pen, $s*0.36, $s*0.50, $s*0.64, $s*0.50)
                $g.DrawLine($pen, $s*0.36, $s*0.66, $s*0.56, $s*0.66)
            }
        }
    }
    finally {
        if ($pen) { $pen.Dispose() }
        if ($brush) { $brush.Dispose() }
        if ($g) { $g.Dispose() }
    }
    $script:UiImages.Add($bmp) | Out-Null
    return $bmp
}

function New-PanelBlock {
    param([int] $X, [int] $Y, [int] $W, [int] $H, [System.Drawing.Color] $Color = $colorPanel)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($W, $H)
    $panel.BackColor = $Color
    $form.Controls.Add($panel)
    return $panel
}

function New-UiLabel {
    param(
        [System.Windows.Forms.Control] $Parent,
        [string] $Text,
        [int] $X,
        [int] $Y,
        [int] $W,
        [int] $H = 20,
        [bool] $Bold = $false,
        [System.Drawing.Color] $Color = $colorMuted
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Text = $Text
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $Parent.Controls.Add($label)
    return $label
}

function New-UiTextBox {
    param(
        [System.Windows.Forms.Control] $Parent,
        [int] $X,
        [int] $Y,
        [int] $W,
        [string] $Text = '',
        [bool] $ReadOnly = $false
    )
    $frame = New-Object System.Windows.Forms.Panel
    $frame.Location = New-Object System.Drawing.Point($X, $Y)
    $frame.Size = New-Object System.Drawing.Size($W, 30)
    $frame.BackColor = [System.Drawing.Color]::Transparent

    if ($ReadOnly) {
        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = New-Object System.Drawing.Point(12, 5)
        $txt.Size = New-Object System.Drawing.Size(([math]::Max(20, $W - 24)), 20)
        $txt.TextAlign = 'MiddleLeft'
        $txt.AutoEllipsis = $true
        $txt.BackColor = [System.Drawing.Color]::Transparent
        $txt.ForeColor = [System.Drawing.Color]::FromArgb(218, 226, 238)
        $txt.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
        $txt.Text = $Text
    } else {
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(12, 6)
        $txt.Size = New-Object System.Drawing.Size(([math]::Max(20, $W - 24)), 22)
        $txt.BackColor = [System.Drawing.Color]::FromArgb(24, 31, 42)
        $txt.ForeColor = $colorText
        $txt.BorderStyle = 'None'
        $txt.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
        $txt.ReadOnly = $false
        $txt.Text = $Text
    }
    $frame.Controls.Add($txt)
    $Parent.Controls.Add($frame)
    Set-UiTextFieldStyle -Frame $frame -TextBox $txt -ReadOnly $ReadOnly
    return $txt
}

function Get-ShiftedColor {
    param([System.Drawing.Color] $Color, [int] $Delta)
    return [System.Drawing.Color]::FromArgb(
        $Color.A,
        [math]::Min(255, [math]::Max(0, $Color.R + $Delta)),
        [math]::Min(255, [math]::Max(0, $Color.G + $Delta)),
        [math]::Min(255, [math]::Max(0, $Color.B + $Delta))
    )
}

function New-RoundedRectPath {
    param([System.Drawing.Rectangle] $Rect, [int] $Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = [math]::Max(2, $Radius * 2)
    $arc = New-Object System.Drawing.Rectangle -ArgumentList $Rect.X, $Rect.Y, $diameter, $diameter
    $path.AddArc($arc, 180, 90)
    $arc.X = $Rect.Right - $diameter
    $path.AddArc($arc, 270, 90)
    $arc.Y = $Rect.Bottom - $diameter
    $path.AddArc($arc, 0, 90)
    $arc.X = $Rect.X
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()
    return $path
}

function Paint-GoodwinTextField {
    param([System.Windows.Forms.Panel] $Frame, [System.Windows.Forms.PaintEventArgs] $EventArgs)
    $style = $Frame.Tag
    if (-not $style -or $style.FieldStyle -ne 'GoodwinTextField') { return }

    $g = $EventArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $parentColor = if ($Frame.Parent) { $Frame.Parent.BackColor } else { $colorPanel }
    $g.Clear($parentColor)

    $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ([int]($Frame.Width - 1)), ([int]($Frame.Height - 1))
    $bg = $style.BackColor
    $border = $style.BorderColor
    if (-not $Frame.Enabled) {
        $bg = $style.DisabledBackColor
        $border = $style.DisabledBorderColor
    } elseif ($style.State -eq 'Focus') {
        $border = $style.FocusBorderColor
    } elseif ($style.State -eq 'Hover') {
        $bg = $style.HoverBackColor
        $border = $style.HoverBorderColor
    }

    $path = New-RoundedRectPath $rect $style.Radius
    $brush = New-Object System.Drawing.SolidBrush($bg)
    $pen = New-Object System.Drawing.Pen($border, 1)
    try {
        $g.FillPath($brush, $path)
        $g.DrawPath($pen, $path)
        if ($style.PSObject.Properties['Clickable'] -and $style.Clickable) {
            $accent = if (-not $Frame.Enabled) {
                [System.Drawing.Color]::FromArgb(70, 82, 98)
            } elseif ($style.State -eq 'Hover') {
                [System.Drawing.Color]::FromArgb(125, 211, 252)
            } else {
                [System.Drawing.Color]::FromArgb(56, 189, 248)
            }
            $zoneX = [int]($Frame.Width - 34)
            $separatorPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(56, 68, 86), 1)
            $arrowPen = New-Object System.Drawing.Pen($accent, 2)
            try {
                $g.DrawLine($separatorPen, $zoneX, 7, $zoneX, ($Frame.Height - 8))
                $midY = [single]($Frame.Height / 2)
                $x = [single]($Frame.Width - 21)
                $g.DrawLine($arrowPen, ($x - 4), ($midY - 5), ($x + 2), $midY)
                $g.DrawLine($arrowPen, ($x + 2), $midY, ($x - 4), ($midY + 5))
            }
            finally {
                $arrowPen.Dispose()
                $separatorPen.Dispose()
            }
        }
    }
    finally {
        $pen.Dispose()
        $brush.Dispose()
        $path.Dispose()
    }
}

function Set-UiTextFieldStyle {
    param(
        [System.Windows.Forms.Panel] $Frame,
        [System.Windows.Forms.Control] $TextBox,
        [bool] $ReadOnly
    )
    $baseBack = [System.Drawing.Color]::FromArgb(24, 31, 42)
    $Frame.Tag = [pscustomobject]@{
        FieldStyle          = 'GoodwinTextField'
        State               = 'Normal'
        Radius              = 8
        BackColor           = $baseBack
        HoverBackColor      = [System.Drawing.Color]::FromArgb(28, 36, 49)
        DisabledBackColor   = [System.Drawing.Color]::FromArgb(23, 27, 35)
        BorderColor         = [System.Drawing.Color]::FromArgb(58, 70, 88)
        HoverBorderColor    = [System.Drawing.Color]::FromArgb(80, 96, 120)
        FocusBorderColor    = [System.Drawing.Color]::FromArgb(56, 189, 248)
        DisabledBorderColor = [System.Drawing.Color]::FromArgb(43, 50, 62)
        Clickable           = $false
    }
    $TextBox.BackColor = if ($TextBox -is [System.Windows.Forms.Label]) { [System.Drawing.Color]::Transparent } else { $baseBack }
    $TextBox.ForeColor = if ($ReadOnly) { [System.Drawing.Color]::FromArgb(218, 226, 238) } else { $colorText }
    if ($TextBox -is [System.Windows.Forms.TextBox]) { $TextBox.ReadOnly = $ReadOnly }

    $enter = {
        if ($this -is [System.Windows.Forms.TextBox] -or $this -is [System.Windows.Forms.Label]) { $target = $this.Parent } else { $target = $this }
        if ($target.Tag -and $target.Tag.FieldStyle -eq 'GoodwinTextField') {
            $target.Tag.State = 'Hover'
            $target.Invalidate()
        }
    }
    $leave = {
        if ($this -is [System.Windows.Forms.TextBox] -or $this -is [System.Windows.Forms.Label]) { $target = $this.Parent } else { $target = $this }
        if ($target.Tag -and $target.Tag.FieldStyle -eq 'GoodwinTextField') {
            $target.Tag.State = 'Normal'
            $target.Invalidate()
        }
    }
    $focus = {
        if ($this.Parent.Tag -and $this.Parent.Tag.FieldStyle -eq 'GoodwinTextField') {
            $this.Parent.Tag.State = 'Focus'
            $this.Parent.Invalidate()
        }
    }
    $blur = {
        if ($this.Parent.Tag -and $this.Parent.Tag.FieldStyle -eq 'GoodwinTextField') {
            $this.Parent.Tag.State = 'Normal'
            $this.Parent.Invalidate()
        }
    }

    $Frame.Add_Paint({ param($sender, $e) Paint-GoodwinTextField $sender $e })
    $Frame.Add_MouseEnter($enter)
    $Frame.Add_MouseLeave($leave)
    $TextBox.Add_MouseEnter($enter)
    $TextBox.Add_MouseLeave($leave)
    if ($TextBox -is [System.Windows.Forms.TextBox]) {
        $TextBox.Add_Enter($focus)
        $TextBox.Add_Leave($blur)
    }
    $Frame.Add_EnabledChanged({
        if ($this.Tag -and $this.Tag.FieldStyle -eq 'GoodwinTextField') {
            $this.Tag.State = 'Normal'
            $this.Invalidate()
        }
    })
}

function Set-ClickableTextFieldStyle {
    param([System.Windows.Forms.Control] $Field)

    if (-not $Field -or -not $Field.Parent -or -not $Field.Parent.Tag) { return }
    $frame = $Field.Parent
    $frame.Tag.Clickable = $true
    $frame.Tag.BackColor = [System.Drawing.Color]::FromArgb(27, 35, 48)
    $frame.Tag.HoverBackColor = [System.Drawing.Color]::FromArgb(33, 44, 61)
    $frame.Tag.BorderColor = [System.Drawing.Color]::FromArgb(64, 85, 112)
    $frame.Tag.HoverBorderColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
    $frame.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Field.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Field.Size = New-Object System.Drawing.Size(([math]::Max(20, $frame.Width - 52)), $Field.Height)
    $frame.Invalidate()
}

function Paint-GoodwinButton {
    param([System.Windows.Forms.Button] $Button, [System.Windows.Forms.PaintEventArgs] $EventArgs)
    $style = $Button.Tag
    if (-not $style -or $style.ButtonStyle -ne 'Goodwin') { return }

    $g = $EventArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $parentColor = if ($Button.Parent) { $Button.Parent.BackColor } else { $colorBg }
    $g.Clear($parentColor)

    $outerGlowPadding = if ($style.PSObject.Properties['OuterGlowPadding']) {
        [int]$style.OuterGlowPadding
    } else {
        0
    }
    $rect = New-Object System.Drawing.Rectangle -ArgumentList $outerGlowPadding, $outerGlowPadding, ([int]($Button.Width - (2 * $outerGlowPadding) - 1)), ([int]($Button.Height - (2 * $outerGlowPadding) - 1))
    $bg = $style.BaseColor
    if (-not $Button.Enabled) {
        $bg = $style.DisabledColor
    } elseif ($style.State -eq 'Pressed') {
        $bg = $style.PressedColor
    } elseif ($style.State -eq 'Hover') {
        $bg = $style.HoverColor
    }

    $topColor = $bg
    $bottomColor = $bg
    if ($Button.Enabled) {
        if ($style.State -eq 'Pressed') {
            $topColor = Get-ShiftedColor $bg -10
            $bottomColor = Get-ShiftedColor $bg -22
        } elseif ($style.State -eq 'Hover') {
            $topColor = Get-ShiftedColor $bg 14
            $bottomColor = Get-ShiftedColor $bg -4
        } else {
            $topColor = Get-ShiftedColor $bg 8
            $bottomColor = Get-ShiftedColor $bg -10
        }
    }

    $border = if (-not $Button.Enabled) {
        $style.DisabledBorderColor
    } elseif ($style.State -eq 'Pressed') {
        $style.PressedBorderColor
    } elseif ($style.State -eq 'Hover') {
        $style.HoverBorderColor
    } else {
        $style.BorderColor
    }

    $path = New-RoundedRectPath $rect $style.Radius
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $topColor, $bottomColor, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $borderPen = New-Object System.Drawing.Pen($border, 1)
    try {
        if ($Button.Enabled -and $style.BlinkActive) {
            $pulse = if ($null -ne $script:BlinkPulse) { [double]$script:BlinkPulse } else { 0.0 }
            $blinkBase = $style.BlinkBorderColor
            $glowAlpha = [int](70 + (115 * $pulse))
            $glowColor = [System.Drawing.Color]::FromArgb($glowAlpha, $blinkBase.R, $blinkBase.G, $blinkBase.B)
            $glowPen = New-Object System.Drawing.Pen($glowColor, ([single](6.0 + (4.0 * $pulse))))
            try {
                $glowPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
                $g.DrawPath($glowPen, $path)
            }
            finally {
                $glowPen.Dispose()
            }
        }

        $g.FillPath($brush, $path)

        if ($style.HighlightAlpha -gt 0 -and $Button.Enabled) {
            $innerRect = New-Object System.Drawing.Rectangle -ArgumentList ([int]($rect.X + 2)), ([int]($rect.Y + 2)), ([int]($rect.Width - 4)), ([int]($rect.Height - 4))
            $innerPath = New-RoundedRectPath $innerRect ([math]::Max(2, $style.Radius - 2))
            $topPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(([math]::Min(95, $style.HighlightAlpha + 18)), 255, 255, 255), 1)
            $bottomPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(34, 0, 0, 0), 1)
            try {
                $g.DrawPath($topPen, $innerPath)
                $g.DrawLine($bottomPen, ($rect.X + 8), ($rect.Bottom - 1), ($rect.Right - 8), ($rect.Bottom - 1))
            }
            finally {
                $bottomPen.Dispose()
                $topPen.Dispose()
                $innerPath.Dispose()
            }
        }

        $g.DrawPath($borderPen, $path)

        if ($Button.Enabled -and $style.BlinkActive) {
            $pulse = if ($null -ne $script:BlinkPulse) { [double]$script:BlinkPulse } else { 0.0 }
            $blinkBase = $style.BlinkBorderColor
            $lineAlpha = [int](145 + (110 * $pulse))
            $blinkColor = [System.Drawing.Color]::FromArgb($lineAlpha, $blinkBase.R, $blinkBase.G, $blinkBase.B)
            $blinkPen = New-Object System.Drawing.Pen($blinkColor, ([single](1.4 + (0.8 * $pulse))))
            try { $g.DrawPath($blinkPen, $path) }
            finally {
                $blinkPen.Dispose()
            }
        }

        $textColor = if ($Button.Enabled) { $style.ForeColor } else { $style.DisabledForeColor }
        $hasText = -not [string]::IsNullOrWhiteSpace($Button.Text)
        $textSize = if ($hasText) {
            [System.Windows.Forms.TextRenderer]::MeasureText($Button.Text, $Button.Font)
        } else {
            New-Object System.Drawing.Size -ArgumentList 0, 0
        }
        $gap = if ($Button.Image -and $hasText) { 9 } else { 0 }
        $iconW = if ($Button.Image) { $Button.Image.Width } else { 0 }
        $totalW = $iconW + $gap + $textSize.Width
        $startX = if ($hasText) {
            $rect.X + [math]::Max(12, [int](($rect.Width - $totalW) / 2))
        } else {
            $rect.X + [int](($rect.Width - $totalW) / 2)
        }

        if ($Button.Image) {
            $iconY = [int]($rect.Y + (($rect.Height - $Button.Image.Height) / 2))
            $iconRect = New-Object System.Drawing.Rectangle -ArgumentList $startX, $iconY, $Button.Image.Width, $Button.Image.Height
            $g.DrawImage($Button.Image, $iconRect)
            $startX += $Button.Image.Width + $gap
        }

        if ($hasText) {
            $textRect = New-Object System.Drawing.Rectangle -ArgumentList $startX, $rect.Y, ([int]([math]::Max(20, $rect.Right - $startX - 12))), $rect.Height
            $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                     [System.Windows.Forms.TextFormatFlags]::Left -bor
                     [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
                     [System.Windows.Forms.TextFormatFlags]::EndEllipsis
            [System.Windows.Forms.TextRenderer]::DrawText($g, $Button.Text, $Button.Font, $textRect, $textColor, $flags)
        }
    }
    finally {
        $borderPen.Dispose()
        $brush.Dispose()
        $path.Dispose()
    }
}

function Set-UiButtonStyle {
    param(
        [System.Windows.Forms.Button] $Button,
        [System.Drawing.Color] $Color,
        [System.Drawing.Color] $HoverColor,
        [System.Drawing.Color] $ForeColor = $colorText,
        [bool] $Bold = $false,
        [int] $Radius = 9,
        [System.Drawing.Color] $BorderColor = ([System.Drawing.Color]::FromArgb(78, 91, 112)),
        [int] $HighlightAlpha = 18,
        [int] $OuterGlowPadding = 0
    )
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.FlatAppearance.MouseOverBackColor = $Color
    $Button.FlatAppearance.MouseDownBackColor = $Color
    $Button.BackColor = $Color
    $Button.ForeColor = $ForeColor
    $Button.UseVisualStyleBackColor = $false
    $Button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Tag = [pscustomobject]@{
        ButtonStyle         = 'Goodwin'
        BaseColor           = $Color
        HoverColor          = $HoverColor
        PressedColor        = (Get-ShiftedColor $HoverColor -20)
        DisabledColor       = [System.Drawing.Color]::FromArgb(32, 38, 49)
        ForeColor           = $ForeColor
        DisabledForeColor   = [System.Drawing.Color]::FromArgb(120, 130, 145)
        BorderColor         = $BorderColor
        HoverBorderColor    = (Get-ShiftedColor $BorderColor 26)
        PressedBorderColor  = (Get-ShiftedColor $BorderColor -10)
        DisabledBorderColor = [System.Drawing.Color]::FromArgb(46, 54, 68)
        Radius              = $Radius
        HighlightAlpha      = $HighlightAlpha
        OuterGlowPadding    = [math]::Max(0, $OuterGlowPadding)
        State               = 'Normal'
        BlinkActive         = $false
        BlinkBorderColor    = (Get-ShiftedColor $HoverColor 74)
    }
    $Button.Add_MouseEnter({
        if ($this.Enabled -and $this.Tag -and $this.Tag.ButtonStyle -eq 'Goodwin') {
            $this.Tag.State = 'Hover'
            $this.Invalidate()
        }
    })
    $Button.Add_MouseLeave({
        if ($this.Tag -and $this.Tag.ButtonStyle -eq 'Goodwin') {
            $this.Tag.State = 'Normal'
            $this.Invalidate()
        }
    })
    $Button.Add_MouseDown({
        if ($this.Enabled -and $this.Tag -and $this.Tag.ButtonStyle -eq 'Goodwin') {
            $this.Tag.State = 'Pressed'
            $this.Invalidate()
        }
    })
    $Button.Add_MouseUp({
        if ($this.Enabled -and $this.Tag -and $this.Tag.ButtonStyle -eq 'Goodwin') {
            $this.Tag.State = if ($this.ClientRectangle.Contains($this.PointToClient([System.Windows.Forms.Cursor]::Position))) { 'Hover' } else { 'Normal' }
            $this.Invalidate()
        }
    })
    $Button.Add_EnabledChanged({
        if ($this.Tag -and $this.Tag.ButtonStyle -eq 'Goodwin') {
            $this.Tag.State = 'Normal'
            $this.Invalidate()
        }
    })
    $Button.Add_Paint({ param($sender, $e) Paint-GoodwinButton $sender $e })
}

function Set-ButtonIcon {
    param(
        [System.Windows.Forms.Button] $Button,
        [string] $Kind,
        [System.Drawing.Color] $Color = [System.Drawing.Color]::White
    )
    $Button.Image = New-IconBitmap -Kind $Kind -Color $Color -Size 20
    $Button.ImageAlign = 'MiddleLeft'
    $Button.TextAlign = 'MiddleCenter'
    $Button.TextImageRelation = 'ImageBeforeText'
    $Button.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
}

function New-IconBadge {
    param(
        [System.Windows.Forms.Control] $Parent,
        [string] $Kind,
        [int] $X,
        [int] $Y,
        [System.Drawing.Color] $BackColor,
        [System.Drawing.Color] $IconColor = [System.Drawing.Color]::White,
        [int] $Size = 40,
        [int] $IconSize = 22
    )
    $box = New-Object System.Windows.Forms.PictureBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Size, $Size)
    $box.BackColor = $BackColor
    $box.SizeMode = 'CenterImage'
    $box.Image = New-IconBitmap -Kind $Kind -Color $IconColor -Size $IconSize
    $Parent.Controls.Add($box)
    return $box
}

function New-UtilityButton {
    param([System.Windows.Forms.Control] $Parent, [string] $Text, [int] $X, [int] $Y, [int] $W = 92)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($W, 30)
    $btn.Text = $Text
    Set-UiButtonStyle -Button $btn -Color ([System.Drawing.Color]::FromArgb(34, 41, 54)) -HoverColor ([System.Drawing.Color]::FromArgb(48, 58, 74)) -ForeColor ([System.Drawing.Color]::FromArgb(226, 232, 240)) -Radius 8 -BorderColor ([System.Drawing.Color]::FromArgb(70, 82, 100)) -HighlightAlpha 10
    $Parent.Controls.Add($btn)
    return $btn
}

function New-InnerPanel {
    param(
        [System.Windows.Forms.Control] $Parent,
        [int] $X,
        [int] $Y,
        [int] $W,
        [int] $H,
        [System.Drawing.Color] $Color
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($W, $H)
    $panel.BackColor = $Color
    $Parent.Controls.Add($panel)
    return $panel
}

function New-InfoCard {
    param(
        [System.Windows.Forms.Control] $Parent,
        [string] $Title,
        [int] $X,
        [int] $Y,
        [int] $W,
        [int] $H,
        [System.Drawing.Color] $Accent
    )
    $card = New-InnerPanel $Parent $X $Y $W $H ([System.Drawing.Color]::FromArgb(24, 30, 40))
    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Location = New-Object System.Drawing.Point(0, 0)
    $stripe.Size = New-Object System.Drawing.Size(4, $H)
    $stripe.BackColor = $Accent
    $card.Controls.Add($stripe)
    [void](New-UiLabel $card $Title 16 12 ($W - 32) 18 $true $colorMuted)
    return $card
}

function New-CompactInfoCard {
    param(
        [System.Windows.Forms.Control] $Parent,
        [string] $Title,
        [int] $X,
        [int] $Y,
        [int] $W,
        [System.Drawing.Color] $Accent
    )
    $card = New-InnerPanel $Parent $X $Y $W 44 ([System.Drawing.Color]::FromArgb(24, 30, 40))
    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Location = New-Object System.Drawing.Point(0, 0)
    $stripe.Size = New-Object System.Drawing.Size(3, 44)
    $stripe.BackColor = $Accent
    $card.Controls.Add($stripe)

    $titleLabel = New-UiLabel $card $Title 12 5 ($W - 22) 14 $true $colorMuted
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)

    $stateLabel = New-UiLabel $card '' 12 21 ($W - 22) 18 $true $colorText
    $stateLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5, [System.Drawing.FontStyle]::Bold)
    $stateLabel.AutoEllipsis = $true

    return [pscustomobject]@{
        Card       = $card
        StateLabel = $stateLabel
    }
}

# === Шапка ===
$headerPanel = New-PanelBlock 0 0 860 106 ([System.Drawing.Color]::FromArgb(17, 22, 31))
$brandBadge = New-IconBadge $headerPanel 'brand' 24 12 ([System.Drawing.Color]::FromArgb(12, 74, 110)) ([System.Drawing.Color]::FromArgb(186, 230, 253)) 54 30

$lblTitle = New-UiLabel $headerPanel 'Goodwin OBS' 92 11 205 34 $true $colorText
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 19, [System.Drawing.FontStyle]::Bold)
$lblSubtitle = New-UiLabel $headerPanel 'OBS SETUP' 94 48 180 18 $false $colorMuted
$lblSubtitle.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)

# === Краткое состояние ===
$quickStatusPanel = New-InnerPanel $headerPanel 298 11 538 54 $colorPanel2
$nickMini = New-CompactInfoCard $quickStatusPanel 'НИК' 10 5 140 $colorAccent
$script:NickStateLabel_ref = $nickMini.StateLabel

$dropboxMini = New-CompactInfoCard $quickStatusPanel 'DROPBOX' 160 5 108 $colorBlue
$script:DropboxStateLabel_ref = $dropboxMini.StateLabel

$obsMini = New-CompactInfoCard $quickStatusPanel 'OBS' 278 5 112 $colorGreen
$script:ObsStateLabel_ref = $obsMini.StateLabel

$uploadMini = New-CompactInfoCard $quickStatusPanel 'ЗАГРУЗКА' 400 5 128 $colorAmber
$script:UploadStateLabel_ref = $uploadMini.StateLabel

# === Параметры ===
$settingsPanel = New-PanelBlock 24 118 812 74 $colorPanel

$lblPath = New-UiLabel $settingsPanel 'Путь записи' 18 10 150
$txtPath = New-UiTextBox $settingsPanel 18 32 392 $script:RecordingRoot $true
Set-ClickableTextFieldStyle $txtPath
$script:ToolTip.SetToolTip($txtPath, 'Изменить папку записи')
$script:ToolTip.SetToolTip($txtPath.Parent, 'Изменить папку записи')

$lblMic = New-UiLabel $settingsPanel 'Микрофон' 432 10 150
$txtMicSel = New-UiTextBox $settingsPanel 432 32 170 $(if ($script:SelectedMic) { $script:SelectedMic } else { 'Авто' }) $true
Set-ClickableTextFieldStyle $txtMicSel
$script:ToolTip.SetToolTip($txtMicSel, 'Выбрать микрофон')
$script:ToolTip.SetToolTip($txtMicSel.Parent, 'Выбрать микрофон')

$lblCam = New-UiLabel $settingsPanel 'Камера' 624 10 150
$txtCamSel = New-UiTextBox $settingsPanel 624 32 170 $(if ($script:SelectedCamera) { $script:SelectedCamera } else { 'Авто' }) $true
Set-ClickableTextFieldStyle $txtCamSel
$script:ToolTip.SetToolTip($txtCamSel, 'Выбрать камеру')
$script:ToolTip.SetToolTip($txtCamSel.Parent, 'Выбрать камеру')

# === Статус ===
$statusPanel = New-InnerPanel $headerPanel 24 72 812 22 ([System.Drawing.Color]::FromArgb(18, 23, 31))
$initialObsReady = Test-Path -LiteralPath (Join-Path $InstallDir 'bin\64bit\obs64.exe')
$initialStatusColor = if ($initialObsReady) { $colorGreen } else { $colorMuted }
$statusAccent = $null

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(0, 2)
$lblStatus.Size     = New-Object System.Drawing.Size(812, 18)
$lblStatus.ForeColor = $initialStatusColor
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 8.8)
$lblStatus.TextAlign = 'MiddleCenter'
$lblStatus.Text = if ($initialObsReady) { 'OBS готов к запуску' } else { 'Готов к установке' }
$statusPanel.Controls.Add($lblStatus)
$script:StatusLabel_ref = $lblStatus

# === Основные кнопки ===
function New-MainButton {
    param(
        [string] $Text,
        [int] $X,
        [int] $Y,
        [System.Drawing.Color] $Color,
        [System.Drawing.Color] $HoverColor,
        [bool] $Enabled = $true
    )
    $btn = New-Object System.Windows.Forms.Button
    $glowPadding = 6
    $btn.Location = New-Object System.Drawing.Point(($X - $glowPadding), ($Y - $glowPadding))
    $btn.Size     = New-Object System.Drawing.Size((256 + (2 * $glowPadding)), (50 + (2 * $glowPadding)))
    $btn.Text = $Text
    Set-UiButtonStyle -Button $btn -Color $Color -HoverColor $HoverColor -ForeColor ([System.Drawing.Color]::White) -Bold $true -Radius 11 -BorderColor (Get-ShiftedColor $HoverColor 18) -HighlightAlpha 24 -OuterGlowPadding $glowPadding
    $btn.Enabled = $Enabled
    if (-not $Enabled) { $btn.Invalidate() }
    $form.Controls.Add($btn)
    return $btn
}

function New-SecondaryButton {
    param([string] $Text, [int] $X, [int] $Y, [int] $W = 312)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size     = New-Object System.Drawing.Size($W, 38)
    $btn.Text = $Text
    Set-UiButtonStyle -Button $btn -Color ([System.Drawing.Color]::FromArgb(30, 37, 49)) -HoverColor ([System.Drawing.Color]::FromArgb(43, 52, 68)) -ForeColor ([System.Drawing.Color]::FromArgb(226, 232, 240)) -Radius 10 -BorderColor ([System.Drawing.Color]::FromArgb(62, 74, 92)) -HighlightAlpha 12
    $form.Controls.Add($btn)
    return $btn
}

$btnInstall = New-MainButton 'Установить OBS' 24  204  ([System.Drawing.Color]::FromArgb(20, 111, 60))  ([System.Drawing.Color]::FromArgb(27, 143, 76))
$btnLaunch  = New-MainButton 'Запустить OBS'  302 204  ([System.Drawing.Color]::FromArgb(31, 82, 154))  ([System.Drawing.Color]::FromArgb(43, 105, 196)) $false
$btnUpload  = New-MainButton 'Загрузить запись' 580 204 ([System.Drawing.Color]::FromArgb(145, 88, 22)) ([System.Drawing.Color]::FromArgb(181, 110, 25))
Set-ButtonIcon -Button $btnInstall -Kind 'install'
Set-ButtonIcon -Button $btnLaunch -Kind 'play'
Set-ButtonIcon -Button $btnUpload -Kind 'upload'

# === Вспомогательные кнопки ===
$btnFolder = New-SecondaryButton 'Папка записей'    113 272 198
$btnFresh  = New-SecondaryButton 'Чистая установка' 331 272 198
$btnClean  = $null
$btnLogs   = New-SecondaryButton 'Логи'             549 272 198
Set-ButtonIcon -Button $btnFolder -Kind 'folder' -Color ([System.Drawing.Color]::FromArgb(226, 232, 240))
Set-ButtonIcon -Button $btnFresh -Kind 'refresh' -Color ([System.Drawing.Color]::FromArgb(226, 232, 240))
Set-ButtonIcon -Button $btnLogs -Kind 'logs' -Color ([System.Drawing.Color]::FromArgb(226, 232, 240))

function Set-Status {
    param([string] $Text, [string] $Color = 'Gray')
    $map = @{
        Gray   = @(154,164,178)
        Green  = @(74,222,128)
        Red    = @(248,113,113)
        Yellow = @(251,191,36)
    }
    $c = $map[$Color]
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2])
    if ($statusAccent) { $statusAccent.BackColor = $lblStatus.ForeColor }
    $lblStatus.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-OverviewState {
    $nick = if ([string]::IsNullOrWhiteSpace($script:SelectedNickname) -or $script:SelectedNickname -eq 'untitled') {
        'Не указан'
    } else {
        $script:SelectedNickname
    }
    if ($script:NickStateLabel_ref) { $script:NickStateLabel_ref.Text = Format-UiText $nick 18 }
    if ($script:NickHintLabel_ref) {
        $script:NickHintLabel_ref.Text = if ($nick -eq 'Не указан') {
            'Будет запрошен перед запуском OBS'
        } else {
            'Будет использован в имени записи'
        }
    }

    if ($script:DropboxStateLabel_ref) {
        $script:DropboxStateLabel_ref.Text = if ($script:DropboxAccessState) { $script:DropboxAccessState } else { 'Не проверен' }
    }

    $obsExe = Join-Path $InstallDir 'bin\64bit\obs64.exe'
    if ($script:ObsStateLabel_ref) {
        $script:ObsStateLabel_ref.Text = if (Test-Path -LiteralPath $obsExe) { 'Готов' } else { 'Не установлен' }
    }
    if ($script:ObsHintLabel_ref) {
        $script:ObsHintLabel_ref.Text = if (Test-Path -LiteralPath $obsExe) {
            'Можно запускать запись'
        } else {
            'Нажмите «Установить OBS»'
        }
    }

    if ($script:UploadStateLabel_ref -and -not $script:IsUploading) {
        $script:UploadStateLabel_ref.Text = if ($script:HasNewRecording) { 'Новая запись' } else { 'Нет новых' }
    }
    if ($script:UploadHintLabel_ref -and -not $script:IsUploading) {
        $script:UploadHintLabel_ref.Text = if ($script:HasNewRecording) { 'Можно загружать в Dropbox' } else { 'Новых записей нет' }
    }
}

function Enable-Button  {
    param($b)
    if (-not $b) { return }
    $b.Enabled = $true
    if ($b.Tag -and $b.Tag.ButtonStyle -eq 'Goodwin') {
        $b.BackColor = $b.Tag.BaseColor
        $b.ForeColor = $b.Tag.ForeColor
        $b.Invalidate()
    } elseif ($b.Tag) {
        $b.BackColor = [System.Drawing.Color]::FromArgb([int]$b.Tag)
        $b.ForeColor = $colorText
    } else {
        $b.BackColor = $colorBlue
        $b.ForeColor = $colorText
    }
}
function Disable-Button {
    param($b)
    if (-not $b) { return }
    $b.Enabled = $false
    if ($b.Tag -and $b.Tag.ButtonStyle -eq 'Goodwin') {
        $b.BackColor = $b.Tag.DisabledColor
        $b.ForeColor = $b.Tag.DisabledForeColor
        $b.Invalidate()
    } else {
        $b.BackColor = [System.Drawing.Color]::FromArgb(33, 38, 48)
        $b.ForeColor = [System.Drawing.Color]::FromArgb(118, 128, 142)
    }
}

function Test-PortableObsReady {
    return (Test-Path -LiteralPath (Join-Path $InstallDir 'bin\64bit\obs64.exe'))
}

function Set-ButtonBlink {
    param($Button, [bool] $Active)
    if (-not $Button -or -not $Button.Tag -or $Button.Tag.ButtonStyle -ne 'Goodwin') { return }
    $changed = ($Button.Tag.BlinkActive -ne $Active)
    $Button.Tag.BlinkActive = $Active
    if ($changed -or $Active) { $Button.Invalidate() }
}

function Get-RecordingFileSnapshot {
    $snapshot = @{}
    try {
        if ([string]::IsNullOrWhiteSpace($script:RecordingRoot) -or -not (Test-Path -LiteralPath $script:RecordingRoot)) {
            return $snapshot
        }
        $patterns = @('*.mp4','*.mkv','*.mov','*.flv')
        $files = @(Get-ChildItem -Path (Join-Path $script:RecordingRoot '*') -File -Include $patterns -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            if ($file.Length -le 0) { continue }
            $snapshot[$file.FullName] = "{0}|{1}" -f $file.Length, $file.LastWriteTimeUtc.Ticks
        }
    }
    catch {
        Write-Log ('Не удалось прочитать папку записей: ' + $_.Exception.Message)
    }
    return $snapshot
}

function Reset-RecordingMonitor {
    $script:RecordingFileSnapshot = Get-RecordingFileSnapshot
    $script:HasNewRecording = $false
    if ($script:UploadStateLabel_ref -and -not $script:IsUploading) { $script:UploadStateLabel_ref.Text = 'Нет новых' }
    if ($script:UploadHintLabel_ref -and -not $script:IsUploading) { $script:UploadHintLabel_ref.Text = 'Новых записей нет' }
}

function Scan-RecordingFolderForNewFiles {
    $current = Get-RecordingFileSnapshot
    if ($null -eq $script:RecordingFileSnapshot) {
        $script:RecordingFileSnapshot = $current
        return
    }

    foreach ($path in $current.Keys) {
        if (-not $script:RecordingFileSnapshot.ContainsKey($path)) {
            if (-not $script:HasNewRecording) {
                Write-Step ('Найдена новая запись: ' + [IO.Path]::GetFileName($path))
            }
            $script:HasNewRecording = $true
            if ($script:UploadStateLabel_ref -and -not $script:IsUploading) { $script:UploadStateLabel_ref.Text = 'Новая запись' }
            if ($script:UploadHintLabel_ref -and -not $script:IsUploading) { $script:UploadHintLabel_ref.Text = 'Можно загружать в Dropbox' }
            return
        }
    }
}

function Update-BlinkTargets {
    $obsReady = Test-PortableObsReady
    if (-not $obsReady) { $script:ObsLaunchCompleted = $false }
    $allowBlink = (-not $script:IsBusy)
    Set-ButtonBlink $btnInstall ($allowBlink -and -not $obsReady)
    Set-ButtonBlink $btnLaunch  ($allowBlink -and $obsReady -and -not $script:ObsLaunchCompleted)
    Set-ButtonBlink $btnUpload  ($allowBlink -and $script:HasNewRecording -and -not $script:IsUploading)
}

if (Test-Path -LiteralPath (Join-Path $InstallDir 'bin\64bit\obs64.exe')) {
    Enable-Button $btnLaunch
}

function Set-AuxControlsEnabled {
    # Включает/выключает второстепенные элементы (выбор устройств, путь записи,
    # «Открыть папку») на время длительной операции — чтобы их нельзя было
    # дёрнуть и устроить гонку с установкой/распаковкой.
    param([bool] $Enabled)
    foreach ($c in @($txtCamSel, $txtCamSel.Parent, $txtMicSel, $txtMicSel.Parent, $txtPath, $txtPath.Parent, $btnFolder)) {
        if ($c) { $c.Enabled = $Enabled }
    }
}

Reset-RecordingMonitor
Update-OverviewState

$script:ObsLaunchCompleted = $false
$script:BlinkPulse = 0.0
$script:BlinkStartTicks = [Environment]::TickCount
$script:LastRecordingScanUtc = [DateTime]::MinValue
$script:StateTimer = New-Object System.Windows.Forms.Timer
$script:StateTimer.Interval = 50
$script:StateTimer.Add_Tick({
    try {
        $elapsedMs = [Environment]::TickCount - $script:BlinkStartTicks
        $script:BlinkPulse = ([Math]::Sin((2.0 * [Math]::PI * $elapsedMs) / 1600.0) + 1.0) / 2.0
        $now = [DateTime]::UtcNow
        if (($now - $script:LastRecordingScanUtc).TotalSeconds -ge 2) {
            $script:LastRecordingScanUtc = $now
            Scan-RecordingFolderForNewFiles
            Update-OverviewState
        }
        Update-BlinkTargets
    }
    catch {
        Write-Log ('Ошибка таймера состояния: ' + $_.Exception.Message)
    }
})
$script:StateTimer.Start()

# ── Диалог выбора камеры (отдельное окно с кнопкой предпросмотра) ──────────
function Show-CameraSelectionDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Выбор камеры'
    $dlg.Size = New-Object System.Drawing.Size(720, 570)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $colorBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'Камера:'
    $l.Location = New-Object System.Drawing.Point(12, 18)
    $l.Size     = New-Object System.Drawing.Size(70, 20)
    $l.ForeColor = $colorText
    $dlg.Controls.Add($l)

    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Location = New-Object System.Drawing.Point(85, 14)
    $cmb.Size     = New-Object System.Drawing.Size(500, 25)
    $cmb.DropDownStyle = 'DropDownList'
    $cmb.BackColor = $colorInput
    $cmb.ForeColor = $colorText
    $cmb.Items.Add('Авто') | Out-Null
    $camList = @(Get-CameraList)
    foreach ($c in $camList) { $cmb.Items.Add($c) | Out-Null }
    if ($camList.Count -eq 0) { Write-Step 'Камеры не обнаружены — проверьте подключение и доступ к камере в параметрах конфиденциальности Windows.' }
    if ($script:SelectedCamera -and $cmb.Items.Contains($script:SelectedCamera)) {
        $cmb.SelectedItem = $script:SelectedCamera
    } else {
        $cmb.SelectedIndex = 0
    }
    $dlg.Controls.Add($cmb)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Location = New-Object System.Drawing.Point(595, 13)
    $btnRefresh.Size     = New-Object System.Drawing.Size(95, 27)
    $btnRefresh.Text = 'Обновить'
    Set-UiButtonStyle -Button $btnRefresh -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnRefresh)

    # Панель-контейнер для DirectShow VideoWindow
    $pnlPreview = New-Object System.Windows.Forms.Panel
    $pnlPreview.Location = New-Object System.Drawing.Point(12, 52)
    $pnlPreview.Size     = New-Object System.Drawing.Size(678, 410)
    $pnlPreview.BackColor = [System.Drawing.Color]::FromArgb(9, 12, 18)
    $pnlPreview.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($pnlPreview)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = 'Выберите камеру для предпросмотра'
    $lblHint.Location = New-Object System.Drawing.Point(0, 190)
    $lblHint.Size = New-Object System.Drawing.Size(678, 30)
    $lblHint.TextAlign = 'MiddleCenter'
    $lblHint.ForeColor = $colorMuted
    $lblHint.BackColor = [System.Drawing.Color]::Transparent
    $pnlPreview.Controls.Add($lblHint)

    $startPreview = {
        param([string] $deviceName)
        try {
            [GoodwinCam.CameraPreview]::Start($deviceName, $pnlPreview.Handle, $pnlPreview.ClientSize.Width, $pnlPreview.ClientSize.Height)
            $lblHint.Visible = $false
        } catch {
            $lblHint.Text = "Не удалось показать предпросмотр:`r`n$($_.Exception.Message)"
            $lblHint.Visible = $true
        }
    }

    $stopPreview = {
        try { [GoodwinCam.CameraPreview]::Stop() } catch {}
    }

    $cmb.Add_SelectedIndexChanged({
        & $stopPreview
        if ($cmb.SelectedIndex -gt 0) {
            $lblHint.Text = 'Запуск предпросмотра…'
            $lblHint.Visible = $true
            [System.Windows.Forms.Application]::DoEvents()
            & $startPreview ([string]$cmb.SelectedItem)
        } else {
            $lblHint.Text = 'Выберите камеру для предпросмотра'
            $lblHint.Visible = $true
        }
    })

    $btnRefresh.Add_Click({
        & $stopPreview
        $current = if ($cmb.SelectedIndex -gt 0) { [string]$cmb.SelectedItem } else { $null }
        $cmb.Items.Clear()
        $cmb.Items.Add('Авто') | Out-Null
        foreach ($c in (Get-CameraList)) { $cmb.Items.Add($c) | Out-Null }
        if ($current -and $cmb.Items.Contains($current)) {
            $cmb.SelectedItem = $current
        } else {
            $cmb.SelectedIndex = 0
        }
    })

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(504, 478)
    $btnOk.Size     = New-Object System.Drawing.Size(80, 32)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    Set-UiButtonStyle -Button $btnOk -Color $colorBlue -HoverColor ([System.Drawing.Color]::FromArgb(87, 150, 255)) -ForeColor ([System.Drawing.Color]::White) -Bold $true
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Отменить'
    $btnCancel.Location = New-Object System.Drawing.Point(594, 478)
    $btnCancel.Size     = New-Object System.Drawing.Size(96, 32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-UiButtonStyle -Button $btnCancel -Color ([System.Drawing.Color]::FromArgb(37, 44, 57)) -HoverColor ([System.Drawing.Color]::FromArgb(51, 61, 78))
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $dlg.Add_Shown({
        if ($cmb.SelectedIndex -gt 0) {
            & $startPreview ([string]$cmb.SelectedItem)
        }
    })
    $dlg.Add_FormClosing({ & $stopPreview })

    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        if ($cmb.SelectedIndex -le 0) {
            $script:SelectedCamera = $null
            $txtCamSel.Text = 'Авто'
        } else {
            $script:SelectedCamera = [string]$cmb.SelectedItem
            $txtCamSel.Text = $script:SelectedCamera
        }
        Save-CurrentSettings
        Write-Step "Выбрана камера: $(if($script:SelectedCamera){$script:SelectedCamera}else{'Авто'})"
    }
    $dlg.Dispose()
}

# ── Диалог выбора микрофона (отдельное окно с полоской уровня и Прослушать) ─
function Show-MicrophoneSelectionDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Выбор микрофона'
    $dlg.Size = New-Object System.Drawing.Size(560, 280)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $colorBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'Микрофон:'
    $l.Location = New-Object System.Drawing.Point(12, 18)
    $l.Size     = New-Object System.Drawing.Size(80, 20)
    $l.ForeColor = $colorText
    $dlg.Controls.Add($l)

    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Location = New-Object System.Drawing.Point(95, 14)
    $cmb.Size     = New-Object System.Drawing.Size(440, 25)
    $cmb.DropDownStyle = 'DropDownList'
    $cmb.BackColor = $colorInput
    $cmb.ForeColor = $colorText
    $cmb.Items.Add('Авто') | Out-Null
    $micList = @(Get-MicrophoneList)
    foreach ($m in $micList) { $cmb.Items.Add($m) | Out-Null }
    if ($micList.Count -eq 0) { Write-Step 'Микрофоны не обнаружены — проверьте подключение и доступ к микрофону в параметрах конфиденциальности Windows.' }
    if ($script:SelectedMic -and $cmb.Items.Contains($script:SelectedMic)) {
        $cmb.SelectedItem = $script:SelectedMic
    } else {
        $cmb.SelectedIndex = 0
    }
    $dlg.Controls.Add($cmb)

    $lblLevel = New-Object System.Windows.Forms.Label
    $lblLevel.Text = 'Уровень сигнала:'
    $lblLevel.Location = New-Object System.Drawing.Point(12, 56)
    $lblLevel.Size     = New-Object System.Drawing.Size(150, 20)
    $lblLevel.ForeColor = $colorText
    $dlg.Controls.Add($lblLevel)

    $pnlLevel = New-Object System.Windows.Forms.Panel
    $pnlLevel.Location = New-Object System.Drawing.Point(12, 80)
    $pnlLevel.Size     = New-Object System.Drawing.Size(523, 24)
    $pnlLevel.BackColor = $colorInput
    $pnlLevel.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($pnlLevel)

    $script:DlgMicLevel = 0.0
    $pnlLevel.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $w = $s.ClientSize.Width
        $h = $s.ClientSize.Height
        $level = [math]::Min(1.0, [math]::Max(0.0, [double]$script:DlgMicLevel))
        $filled = [int]($w * $level)
        if ($filled -le 0) { return }
        $greenEnd  = [int]($w * 0.60)
        $yellowEnd = [int]($w * 0.85)
        $brushG = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 200, 80))
        $brushY = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 200, 60))
        $brushR = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 80, 80))
        try {
            $gFill = [math]::Min($filled, $greenEnd)
            if ($gFill -gt 0) { $g.FillRectangle($brushG, 0, 0, $gFill, $h) }
            if ($filled -gt $greenEnd) {
                $yFill = [math]::Min($filled, $yellowEnd) - $greenEnd
                if ($yFill -gt 0) { $g.FillRectangle($brushY, $greenEnd, 0, $yFill, $h) }
            }
            if ($filled -gt $yellowEnd) {
                $rFill = $filled - $yellowEnd
                if ($rFill -gt 0) { $g.FillRectangle($brushR, $yellowEnd, 0, $rFill, $h) }
            }
        } finally {
            $brushG.Dispose(); $brushY.Dispose(); $brushR.Dispose()
        }
    })

    $btnListen = New-Object System.Windows.Forms.Button
    $btnListen.Location = New-Object System.Drawing.Point(12, 120)
    $btnListen.Size     = New-Object System.Drawing.Size(200, 36)
    $btnListen.Text = 'Прослушать (3 сек)'
    Set-UiButtonStyle -Button $btnListen -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnListen)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Полоска и тест звука используют выбранный микрофон.`nЕсли устройство не слышно, выберите другое в списке."
    $lblHint.Location = New-Object System.Drawing.Point(220, 122)
    $lblHint.Size     = New-Object System.Drawing.Size(315, 36)
    $lblHint.ForeColor = $colorMuted
    $dlg.Controls.Add($lblHint)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(336, 195)
    $btnOk.Size     = New-Object System.Drawing.Size(86, 30)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    Set-UiButtonStyle -Button $btnOk -Color $colorBlue -HoverColor ([System.Drawing.Color]::FromArgb(87, 150, 255)) -ForeColor ([System.Drawing.Color]::White) -Bold $true
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Отменить'
    $btnCancel.Location = New-Object System.Drawing.Point(432, 195)
    $btnCancel.Size     = New-Object System.Drawing.Size(104, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-UiButtonStyle -Button $btnCancel -Color ([System.Drawing.Color]::FromArgb(37, 44, 57)) -HoverColor ([System.Drawing.Color]::FromArgb(51, 61, 78))
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    # Кэш разрешённого устройства, чтобы не перечислять все микрофоны на каждый тик.
    $script:DlgMicCachedName = $null
    $script:DlgMicCachedId   = $null

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 80
    $timer.Add_Tick({
        try {
            $peak = 0.0
            if ($cmb.SelectedIndex -le 0) {
                $peak = [double][GoodwinCoreAudio.AudioMeter]::GetDefaultCapturePeak()
            } else {
                $name = [string]$cmb.SelectedItem
                # Разрешаем id один раз — пока выбор не сменился (раньше перебор шёл каждый тик).
                if ($name -ne $script:DlgMicCachedName) {
                    $script:DlgMicCachedName = $name
                    $script:DlgMicCachedId   = Get-MicrophoneDeviceIdByName -FriendlyName $name
                }
                if ($script:DlgMicCachedId -and $script:DlgMicCachedId -ne 'default') {
                    $peak = [double][GoodwinCoreAudio.AudioMeter]::GetPeakById($script:DlgMicCachedId)
                } else {
                    $peak = [double][GoodwinCoreAudio.AudioMeter]::GetPeakByName($name)
                }
            }
            $script:DlgMicLevel = $peak
        } catch {
            $script:DlgMicLevel = 0.0
        }
        $pnlLevel.Invalidate()
    })

    $btnListen.Add_Click({
        $btnListen.Enabled = $false
        $orig = $btnListen.Text
        $btnListen.Text = 'Запись… 3 сек'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $deviceId = 'default'
            if ($cmb.SelectedIndex -gt 0) {
                $deviceId = Get-MicrophoneDeviceIdByName -FriendlyName ([string]$cmb.SelectedItem)
            }
            Start-MicrophoneTest -DurationSec 3 -DeviceId $deviceId
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Не удалось записать/воспроизвести: $($_.Exception.Message)", 'Ошибка', 'OK', 'Error') | Out-Null
        }
        $btnListen.Text = $orig
        $btnListen.Enabled = $true
    })

    $dlg.Add_Shown({ $timer.Start() })
    $dlg.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        if ($cmb.SelectedIndex -le 0) {
            $script:SelectedMic = $null
            $txtMicSel.Text = 'Авто'
        } else {
            $script:SelectedMic = [string]$cmb.SelectedItem
            $txtMicSel.Text = $script:SelectedMic
        }
        Save-CurrentSettings
        Write-Step "Выбран микрофон: $(if($script:SelectedMic){$script:SelectedMic}else{'Авто'})"
    }
    $dlg.Dispose()
}

function Show-PreLaunchDeviceCheckDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Проверка камеры и микрофона'
    $dlg.Size = New-Object System.Drawing.Size(760, 680)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $colorBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    $lblCam = New-Object System.Windows.Forms.Label
    $lblCam.Text = 'Камера:'
    $lblCam.Location = New-Object System.Drawing.Point(16, 18)
    $lblCam.Size = New-Object System.Drawing.Size(70, 20)
    $lblCam.ForeColor = $colorText
    $dlg.Controls.Add($lblCam)

    $cmbCam = New-Object System.Windows.Forms.ComboBox
    $cmbCam.Location = New-Object System.Drawing.Point(92, 14)
    $cmbCam.Size = New-Object System.Drawing.Size(520, 25)
    $cmbCam.DropDownStyle = 'DropDownList'
    $cmbCam.BackColor = $colorInput
    $cmbCam.ForeColor = $colorText
    $dlg.Controls.Add($cmbCam)

    $btnRefreshCam = New-Object System.Windows.Forms.Button
    $btnRefreshCam.Text = 'Обновить'
    $btnRefreshCam.Location = New-Object System.Drawing.Point(624, 13)
    $btnRefreshCam.Size = New-Object System.Drawing.Size(100, 27)
    Set-UiButtonStyle -Button $btnRefreshCam -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnRefreshCam)

    $pnlPreview = New-Object System.Windows.Forms.Panel
    $pnlPreview.Location = New-Object System.Drawing.Point(16, 52)
    $pnlPreview.Size = New-Object System.Drawing.Size(708, 398)
    $pnlPreview.BackColor = [System.Drawing.Color]::FromArgb(9, 12, 18)
    $pnlPreview.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($pnlPreview)

    $lblPreview = New-Object System.Windows.Forms.Label
    $lblPreview.Text = 'Запуск предпросмотра камеры...'
    $lblPreview.Location = New-Object System.Drawing.Point(0, 178)
    $lblPreview.Size = New-Object System.Drawing.Size(708, 42)
    $lblPreview.TextAlign = 'MiddleCenter'
    $lblPreview.ForeColor = $colorMuted
    $lblPreview.BackColor = [System.Drawing.Color]::Transparent
    $pnlPreview.Controls.Add($lblPreview)

    $lblMic = New-Object System.Windows.Forms.Label
    $lblMic.Text = 'Микрофон:'
    $lblMic.Location = New-Object System.Drawing.Point(16, 470)
    $lblMic.Size = New-Object System.Drawing.Size(70, 20)
    $lblMic.ForeColor = $colorText
    $dlg.Controls.Add($lblMic)

    $cmbMic = New-Object System.Windows.Forms.ComboBox
    $cmbMic.Location = New-Object System.Drawing.Point(92, 466)
    $cmbMic.Size = New-Object System.Drawing.Size(520, 25)
    $cmbMic.DropDownStyle = 'DropDownList'
    $cmbMic.BackColor = $colorInput
    $cmbMic.ForeColor = $colorText
    $dlg.Controls.Add($cmbMic)

    $btnRefreshMic = New-Object System.Windows.Forms.Button
    $btnRefreshMic.Text = 'Обновить'
    $btnRefreshMic.Location = New-Object System.Drawing.Point(624, 465)
    $btnRefreshMic.Size = New-Object System.Drawing.Size(100, 27)
    Set-UiButtonStyle -Button $btnRefreshMic -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnRefreshMic)

    $lblLevel = New-Object System.Windows.Forms.Label
    $lblLevel.Text = 'Уровень:'
    $lblLevel.Location = New-Object System.Drawing.Point(16, 507)
    $lblLevel.Size = New-Object System.Drawing.Size(70, 20)
    $lblLevel.ForeColor = $colorText
    $dlg.Controls.Add($lblLevel)

    $pnlLevel = New-Object System.Windows.Forms.Panel
    $pnlLevel.Location = New-Object System.Drawing.Point(92, 503)
    $pnlLevel.Size = New-Object System.Drawing.Size(330, 24)
    $pnlLevel.BackColor = $colorInput
    $pnlLevel.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($pnlLevel)

    $btnSoundTest = New-Object System.Windows.Forms.Button
    $btnSoundTest.Text = 'Тест звука (3 сек)'
    $btnSoundTest.Location = New-Object System.Drawing.Point(444, 498)
    $btnSoundTest.Size = New-Object System.Drawing.Size(168, 34)
    Set-UiButtonStyle -Button $btnSoundTest -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnSoundTest)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = 'Проверьте картинку и звук. Если устройство выбрано неверно, смените его в списке перед запуском OBS.'
    $lblHint.Location = New-Object System.Drawing.Point(16, 542)
    $lblHint.Size = New-Object System.Drawing.Size(708, 34)
    $lblHint.ForeColor = $colorMuted
    $lblHint.BackColor = [System.Drawing.Color]::Transparent
    $dlg.Controls.Add($lblHint)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Продолжить'
    $btnOk.Location = New-Object System.Drawing.Point(472, 590)
    $btnOk.Size = New-Object System.Drawing.Size(144, 34)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    Set-UiButtonStyle -Button $btnOk -Color $colorBlue -HoverColor ([System.Drawing.Color]::FromArgb(87, 150, 255)) -ForeColor ([System.Drawing.Color]::White) -Bold $true
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Отмена'
    $btnCancel.Location = New-Object System.Drawing.Point(626, 590)
    $btnCancel.Size = New-Object System.Drawing.Size(98, 34)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-UiButtonStyle -Button $btnCancel -Color ([System.Drawing.Color]::FromArgb(37, 44, 57)) -HoverColor ([System.Drawing.Color]::FromArgb(51, 61, 78))
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $script:PreLaunchCameraPopulating = $false
    $populateCameras = {
        param([string] $Preferred)
        $script:PreLaunchCameraPopulating = $true
        try {
            $cmbCam.Items.Clear()
            $cmbCam.Items.Add('Авто') | Out-Null
            $cams = @(Get-CameraList)
            foreach ($c in $cams) { $cmbCam.Items.Add($c) | Out-Null }
            if ($Preferred -and $cmbCam.Items.Contains($Preferred)) {
                $cmbCam.SelectedItem = $Preferred
            } else {
                $cmbCam.SelectedIndex = 0
            }
            if ($cams.Count -eq 0) {
                $lblPreview.Text = 'Камера не обнаружена'
                $lblPreview.Visible = $true
            }
        } finally {
            $script:PreLaunchCameraPopulating = $false
        }
    }

    $getCameraItems = {
        $items = @()
        for ($i = 1; $i -lt $cmbCam.Items.Count; $i++) {
            $items += [string]$cmbCam.Items[$i]
        }
        return $items
    }

    $resolvePreviewCamera = {
        if ($cmbCam.SelectedIndex -gt 0) { return [string]$cmbCam.SelectedItem }
        $items = @(& $getCameraItems)
        if ($items.Count -eq 0) { return $null }
        $auto = Get-WindowsCameraName
        if ($auto -and ($items -contains $auto)) { return $auto }
        return [string]$items[0]
    }

    $stopPreview = {
        try { [GoodwinCam.CameraPreview]::Stop() } catch {}
    }

    $startPreview = {
        if ($script:PreLaunchCameraPopulating) { return }
        & $stopPreview
        $deviceName = & $resolvePreviewCamera
        if ([string]::IsNullOrWhiteSpace($deviceName)) {
            $lblPreview.Text = 'Камера не обнаружена'
            $lblPreview.Visible = $true
            return
        }
        $lblPreview.Text = "Запуск предпросмотра: $deviceName"
        $lblPreview.Visible = $true
        [System.Windows.Forms.Application]::DoEvents()
        try {
            [GoodwinCam.CameraPreview]::Start($deviceName, $pnlPreview.Handle, $pnlPreview.ClientSize.Width, $pnlPreview.ClientSize.Height)
            $lblPreview.Visible = $false
        } catch {
            $lblPreview.Text = "Не удалось показать предпросмотр:`r`n$($_.Exception.Message)"
            $lblPreview.Visible = $true
        }
    }

    $populateMicrophones = {
        param([string] $Preferred)
        $cmbMic.Items.Clear()
        $cmbMic.Items.Add('Авто') | Out-Null
        $mics = @(Get-MicrophoneList)
        foreach ($m in $mics) { $cmbMic.Items.Add($m) | Out-Null }
        if ($Preferred -and $cmbMic.Items.Contains($Preferred)) {
            $cmbMic.SelectedItem = $Preferred
        } else {
            $cmbMic.SelectedIndex = 0
        }
    }

    $script:PreLaunchMicLevel = 0.0
    $script:PreLaunchMicCachedName = $null
    $script:PreLaunchMicCachedId = $null

    $pnlLevel.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $w = $s.ClientSize.Width
        $h = $s.ClientSize.Height
        $level = [math]::Min(1.0, [math]::Max(0.0, [double]$script:PreLaunchMicLevel))
        $filled = [int]($w * $level)
        if ($filled -le 0) { return }
        $greenEnd = [int]($w * 0.60)
        $yellowEnd = [int]($w * 0.85)
        $brushG = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 200, 80))
        $brushY = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 200, 60))
        $brushR = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 80, 80))
        try {
            $gFill = [math]::Min($filled, $greenEnd)
            if ($gFill -gt 0) { $g.FillRectangle($brushG, 0, 0, $gFill, $h) }
            if ($filled -gt $greenEnd) {
                $yFill = [math]::Min($filled, $yellowEnd) - $greenEnd
                if ($yFill -gt 0) { $g.FillRectangle($brushY, $greenEnd, 0, $yFill, $h) }
            }
            if ($filled -gt $yellowEnd) {
                $rFill = $filled - $yellowEnd
                if ($rFill -gt 0) { $g.FillRectangle($brushR, $yellowEnd, 0, $rFill, $h) }
            }
        } finally {
            $brushG.Dispose(); $brushY.Dispose(); $brushR.Dispose()
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 80
    $timer.Add_Tick({
        try {
            $peak = 0.0
            if ($cmbMic.SelectedIndex -le 0) {
                $peak = [double][GoodwinCoreAudio.AudioMeter]::GetDefaultCapturePeak()
            } else {
                $name = [string]$cmbMic.SelectedItem
                if ($name -ne $script:PreLaunchMicCachedName) {
                    $script:PreLaunchMicCachedName = $name
                    $script:PreLaunchMicCachedId = Get-MicrophoneDeviceIdByName -FriendlyName $name
                }
                if ($script:PreLaunchMicCachedId -and $script:PreLaunchMicCachedId -ne 'default') {
                    $peak = [double][GoodwinCoreAudio.AudioMeter]::GetPeakById($script:PreLaunchMicCachedId)
                } else {
                    $peak = [double][GoodwinCoreAudio.AudioMeter]::GetPeakByName($name)
                }
            }
            $script:PreLaunchMicLevel = $peak
        } catch {
            $script:PreLaunchMicLevel = 0.0
        }
        $pnlLevel.Invalidate()
    })

    $cmbCam.Add_SelectedIndexChanged({ & $startPreview })
    $cmbMic.Add_SelectedIndexChanged({
        $script:PreLaunchMicCachedName = $null
        $script:PreLaunchMicCachedId = $null
    })
    $btnRefreshCam.Add_Click({
        $preferred = if ($cmbCam.SelectedIndex -gt 0) { [string]$cmbCam.SelectedItem } else { $script:SelectedCamera }
        & $populateCameras $preferred
        & $startPreview
    })
    $btnRefreshMic.Add_Click({
        $preferred = if ($cmbMic.SelectedIndex -gt 0) { [string]$cmbMic.SelectedItem } else { $script:SelectedMic }
        & $populateMicrophones $preferred
    })
    $btnSoundTest.Add_Click({
        $btnSoundTest.Enabled = $false
        $origText = $btnSoundTest.Text
        $btnSoundTest.Text = 'Запись...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $deviceId = 'default'
            if ($cmbMic.SelectedIndex -gt 0) {
                $deviceId = Get-MicrophoneDeviceIdByName -FriendlyName ([string]$cmbMic.SelectedItem)
            }
            Start-MicrophoneTest -DurationSec 3 -DeviceId $deviceId
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Не удалось записать/воспроизвести: $($_.Exception.Message)", 'Ошибка', 'OK', 'Error') | Out-Null
        } finally {
            $btnSoundTest.Text = $origText
            $btnSoundTest.Enabled = $true
        }
    })

    & $populateCameras $script:SelectedCamera
    & $populateMicrophones $script:SelectedMic

    $dlg.Add_Shown({
        & $startPreview
        $timer.Start()
    })
    $dlg.Add_FormClosed({
        try { $timer.Stop(); $timer.Dispose() } catch {}
        & $stopPreview
    })

    try {
        if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
            return $false
        }

        if ($cmbCam.SelectedIndex -le 0) {
            $script:SelectedCamera = $null
            $txtCamSel.Text = 'Авто'
        } else {
            $script:SelectedCamera = [string]$cmbCam.SelectedItem
            $txtCamSel.Text = $script:SelectedCamera
        }

        if ($cmbMic.SelectedIndex -le 0) {
            $script:SelectedMic = $null
            $txtMicSel.Text = 'Авто'
        } else {
            $script:SelectedMic = [string]$cmbMic.SelectedItem
            $txtMicSel.Text = $script:SelectedMic
        }

        Save-CurrentSettings
        Update-OverviewState
        Write-Step "Проверка устройств завершена: камера=$(if($script:SelectedCamera){$script:SelectedCamera}else{'Авто'}), микрофон=$(if($script:SelectedMic){$script:SelectedMic}else{'Авто'})"
        return $true
    } finally {
        $dlg.Dispose()
    }
}

function Set-SettingsFieldClick {
    param(
        [System.Windows.Forms.Control] $Field,
        [scriptblock] $Action
    )
    foreach ($target in @($Field, $Field.Parent)) {
        if (-not $target) { continue }
        $target.Cursor = [System.Windows.Forms.Cursors]::Hand
        $target.Add_Click($Action)
    }
}

# ── Обработчики выбора устройств / пути / никнейма ─────────────────────────
$openCameraSettings = {
    if ($script:IsBusy) { return }
    try { Show-CameraSelectionDialog }
    catch { Write-ErrorDetails -Context 'Выбор камеры' -ErrorRecord $_ }
}
Set-SettingsFieldClick $txtCamSel $openCameraSettings

$openMicrophoneSettings = {
    if ($script:IsBusy) { return }
    try { Show-MicrophoneSelectionDialog }
    catch { Write-ErrorDetails -Context 'Выбор микрофона' -ErrorRecord $_ }
}
Set-SettingsFieldClick $txtMicSel $openMicrophoneSettings

function Sanitize-Nickname {
    param([string] $Value)
    $raw = if ($Value) { $Value.Trim() } else { '' }
    $cleaned = $raw -replace '[<>:"/\\|?*]', ''
    $cleaned = $cleaned -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($cleaned)) { $cleaned = 'untitled' }
    return $cleaned
}

function Set-SelectedNickname {
    param([string] $Nickname)
    $cleaned = Sanitize-Nickname $Nickname
    $script:SelectedNickname = $cleaned
    Save-CurrentSettings
    Update-OverviewState
    Write-Step "Ник записи: $script:SelectedNickname"
    return $cleaned
}

function Show-NicknameDialog {
    param(
        [string] $Title = 'Ник записи',
        [string] $Prompt = 'Введите никнейм, который будет добавлен в имя файлов записи.'
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(460, 220)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $colorBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.Location = New-Object System.Drawing.Point(18, 18)
    $label.Size = New-Object System.Drawing.Size(404, 38)
    $label.ForeColor = $colorText
    $label.BackColor = [System.Drawing.Color]::Transparent
    $dlg.Controls.Add($label)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(18, 68)
    $txt.Size = New-Object System.Drawing.Size(404, 30)
    $txt.BackColor = $colorInput
    $txt.ForeColor = $colorText
    $txt.BorderStyle = 'FixedSingle'
    $txt.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $txt.Text = if ($script:SelectedNickname -and $script:SelectedNickname -ne 'untitled') { $script:SelectedNickname } else { '' }
    $dlg.Controls.Add($txt)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Недопустимые символы будут удалены, пробелы заменятся на _.'
    $hint.Location = New-Object System.Drawing.Point(18, 104)
    $hint.Size = New-Object System.Drawing.Size(404, 20)
    $hint.ForeColor = $colorMuted
    $hint.BackColor = [System.Drawing.Color]::Transparent
    $dlg.Controls.Add($hint)

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text = 'Продолжить'
$btnOk.Location = New-Object System.Drawing.Point(202, 136)
$btnOk.Size = New-Object System.Drawing.Size(124, 32)
    Set-UiButtonStyle -Button $btnOk -Color $colorBlue -HoverColor ([System.Drawing.Color]::FromArgb(87, 150, 255)) -ForeColor ([System.Drawing.Color]::White) -Bold $true
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Отмена'
    $btnCancel.Location = New-Object System.Drawing.Point(328, 136)
    $btnCancel.Size = New-Object System.Drawing.Size(94, 32)
    Set-UiButtonStyle -Button $btnCancel -Color ([System.Drawing.Color]::FromArgb(37, 44, 57)) -HoverColor ([System.Drawing.Color]::FromArgb(51, 61, 78))
    $dlg.Controls.Add($btnCancel)

    $btnOk.Add_Click({
        $cleaned = Sanitize-Nickname $txt.Text
        if ($cleaned -eq 'untitled') {
            [System.Windows.Forms.MessageBox]::Show(
                'Введите никнейм перед запуском OBS.',
                'Ник не указан',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        if ($cleaned -ne $txt.Text.Trim()) { $txt.Text = $cleaned }
        $dlg.Tag = $cleaned
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    })
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $dlg.Add_Shown({ $txt.Focus(); $txt.SelectAll() })

    try {
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            return (Set-SelectedNickname ([string]$dlg.Tag))
        }
        return $null
    }
    finally {
        $dlg.Dispose()
    }
}

function Show-LogViewerDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Логи Goodwin OBS'
    $dlg.Size = New-Object System.Drawing.Size(900, 620)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $colorBg
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = $script:LogFile
    $pathLabel.Location = New-Object System.Drawing.Point(16, 14)
    $pathLabel.Size = New-Object System.Drawing.Size(850, 20)
    $pathLabel.ForeColor = $colorMuted
    $pathLabel.BackColor = [System.Drawing.Color]::Transparent
    $dlg.Controls.Add($pathLabel)

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Location = New-Object System.Drawing.Point(16, 42)
    $box.Size = New-Object System.Drawing.Size(850, 468)
    $box.ReadOnly = $true
    $box.BackColor = [System.Drawing.Color]::FromArgb(9, 12, 18)
    $box.ForeColor = [System.Drawing.Color]::FromArgb(220, 226, 235)
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.ScrollBars = 'Both'
    $box.WordWrap = $false
    $box.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($box)

    $loadLog = {
        try {
            if (Test-Path -LiteralPath $script:LogFile) {
                $box.Text = Get-Content -Raw -Path $script:LogFile -Encoding UTF8
            } else {
                $box.Text = 'Лог-файл пока не создан.'
            }
            $box.SelectionStart = $box.TextLength
            try { $box.ScrollToCaret() } catch {}
        }
        catch {
            $box.Text = 'Не удалось прочитать лог: ' + $_.Exception.Message
        }
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Обновить'
    $btnRefresh.Location = New-Object System.Drawing.Point(516, 526)
    $btnRefresh.Size = New-Object System.Drawing.Size(100, 32)
    Set-UiButtonStyle -Button $btnRefresh -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnRefresh)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = 'Открыть файл'
    $btnOpen.Location = New-Object System.Drawing.Point(624, 526)
    $btnOpen.Size = New-Object System.Drawing.Size(134, 32)
    Set-UiButtonStyle -Button $btnOpen -Color ([System.Drawing.Color]::FromArgb(47, 55, 70)) -HoverColor ([System.Drawing.Color]::FromArgb(62, 72, 90))
    $dlg.Controls.Add($btnOpen)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Закрыть'
    $btnClose.Location = New-Object System.Drawing.Point(764, 526)
    $btnClose.Size = New-Object System.Drawing.Size(102, 32)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    Set-UiButtonStyle -Button $btnClose -Color $colorBlue -HoverColor ([System.Drawing.Color]::FromArgb(87, 150, 255)) -ForeColor ([System.Drawing.Color]::White) -Bold $true
    $dlg.Controls.Add($btnClose)

    $btnRefresh.Add_Click({ & $loadLog })
    $btnOpen.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $script:LogFile)) {
                Add-LogFileLine ("[{0}] Лог-файл создан по запросу пользователя." -f (Get-Date -Format 'HH:mm:ss'))
            }
            Start-Process -FilePath notepad.exe -ArgumentList $script:LogFile
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                ('Не удалось открыть лог-файл: ' + $_.Exception.Message),
                'Логи',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    & $loadLog
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

$openRecordingFolderSettings = {
    if ($script:IsBusy) { return }
    try {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = 'Выберите папку для записей'
        if (Test-Path $script:RecordingRoot) { $fbd.SelectedPath = $script:RecordingRoot }
        if ($fbd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:RecordingRoot = $fbd.SelectedPath
            $script:RecordingDir  = $script:RecordingRoot
            $txtPath.Text = $script:RecordingRoot
            Save-CurrentSettings
            Reset-RecordingMonitor
            Update-OverviewState
            Write-Step "Папка записей изменена: $script:RecordingRoot"
        }
    }
    catch { Write-ErrorDetails -Context 'Выбор папки записей' -ErrorRecord $_ }
}
Set-SettingsFieldClick $txtPath $openRecordingFolderSettings

# ── Проверка доступности выбранных устройств ───────────────────────────────
function Confirm-DeviceAvailability {
    # Возвращает $true, если можно продолжать установку, $false — если пользователь отказался.
    $warnings = @()

    if ($script:SelectedMic) {
        $mics = @(Get-MicrophoneList)
        if ($mics -notcontains $script:SelectedMic) {
            $warnings += "Микрофон «$script:SelectedMic» не подключён или отключён."
        }
    }
    if ($script:SelectedCamera) {
        $cams = @(Get-CameraList)
        if ($cams -notcontains $script:SelectedCamera) {
            $warnings += "Камера «$script:SelectedCamera» не подключена или отключена."
        }
    }

    if ($warnings.Count -eq 0) { return $true }

    $msg = ($warnings -join "`r`n") + "`r`n`r`nПродолжить установку? OBS будет использовать устройство по умолчанию."
    $res = [System.Windows.Forms.MessageBox]::Show(
        $msg,
        'Устройство недоступно',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($res -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ── Кнопка «Установить» ────────────────────────────────────────────────────
$btnInstall.Add_Click({
    if ($script:IsBusy) { return }

    if ([string]::IsNullOrWhiteSpace($script:SelectedNickname)) {
        $script:SelectedNickname = 'untitled'
    }
    Save-CurrentSettings
    Update-OverviewState

    if (-not (Confirm-DeviceAvailability)) {
        Set-Status 'Установка отменена: устройство недоступно.' 'Yellow'
        return
    }

    $script:IsBusy = $true
    Set-AuxControlsEnabled $false
    Disable-Button $btnInstall
    Set-Status 'Установка OBS...' 'Yellow'
    try {
        Ensure-Tls12
        New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
        Install-ObsPortable
        Install-PortableSettings

        Write-Step 'Проверяем доступ к Dropbox'
        if (Test-DropboxAccess) {
            Write-Step '✓ Доступ к Dropbox подтверждён'
        } else {
            Write-Step 'Не удалось подтвердить доступ к Dropbox. Подробности доступны через «Логи».'
        }

        Set-Status 'OBS установлен. Нажмите «Запустить».' 'Green'
        $script:ObsLaunchCompleted = $false
        Enable-Button $btnLaunch
        Update-OverviewState
    }
    catch {
        Write-ErrorDetails -Context 'Установка OBS' -ErrorRecord $_
        Set-Status ('Ошибка установки: ' + $_.Exception.Message) 'Red'
    }
    finally {
        $script:IsBusy = $false
        Set-AuxControlsEnabled $true
        Enable-Button $btnInstall
    }
})

# ── Кнопка «Запустить» ─────────────────────────────────────────────────────
$btnLaunch.Add_Click({
    if ($script:IsBusy) { return }

    $nickname = Show-NicknameDialog
    if ([string]::IsNullOrWhiteSpace($nickname)) {
        Set-Status 'Запуск отменён: ник не указан.' 'Yellow'
        return
    }

    if (-not (Show-PreLaunchDeviceCheckDialog)) {
        Set-Status 'Запуск отменён: проверка устройств не завершена.' 'Yellow'
        return
    }

    $script:IsBusy = $true
    Disable-Button $btnLaunch
    Set-Status 'Применяем настройки OBS...' 'Yellow'
    try {
        $obsRunning = Get-Process -Name 'obs64' -ErrorAction SilentlyContinue
        if ($obsRunning) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "OBS уже запущен. Чтобы стартовать портативную версию, нужно закрыть текущий процесс.`n`n" +
                "ВНИМАНИЕ: если в OBS идёт запись или стрим, они прервутся, несохранённые изменения могут пропасть.`n`n" +
                "Закрыть запущенный OBS?",
                'OBS уже запущен',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Step 'Запуск отменён пользователем (OBS уже работает).'
                Set-Status 'Запуск отменён.' 'Yellow'
                return
            }
            Write-Step 'Закрываем запущенный OBS по согласию пользователя'
            $obsRunning | Stop-Process -Force
            Start-Sleep -Seconds 2
        }
        $configDir = Join-Path $InstallDir 'config\obs-studio'
        Install-PortableRepoObsFiles -ConfigDir $configDir
        Install-PortableRepoObsProfiles -ConfigDir $configDir
        Set-PortableObsConfig
        Set-Status 'Запускаем OBS...' 'Yellow'
        Start-PortableObs
        $script:ObsLaunchCompleted = $true
        Set-ButtonBlink $btnLaunch $false
        Set-Status 'OBS запущен. После записи нажмите «Загрузить».' 'Green'
        Enable-Button $btnUpload
        Update-OverviewState
    }
    catch {
        Write-ErrorDetails -Context 'Запуск OBS' -ErrorRecord $_
        Set-Status ('Ошибка запуска: ' + $_.Exception.Message) 'Red'
    }
    finally {
        $script:IsBusy = $false
        Enable-Button $btnLaunch
    }
})

# ── Кнопка «Загрузить» (выбор файлов по префиксу никнейма) ─────────────────
$btnUpload.Add_Click({
    if ($script:IsBusy) { return }

    $cleaned = Sanitize-Nickname $script:SelectedNickname
    if ($cleaned -eq 'untitled') {
        $cleaned = Show-NicknameDialog -Title 'Ник записей' -Prompt 'Введите никнейм, по которому будут выбраны файлы записи.'
        if ([string]::IsNullOrWhiteSpace($cleaned)) {
            Set-Status 'Загрузка отменена: ник не указан.' 'Yellow'
            return
        }
    } else {
        $script:SelectedNickname = $cleaned
        Save-CurrentSettings
        Update-OverviewState
    }
    $prefix = $cleaned

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Выберите записи с префиксом «$prefix»"
    if (Test-Path $script:RecordingRoot) { $ofd.InitialDirectory = $script:RecordingRoot }
    $ofd.Multiselect = $true
    # Жёсткий фильтр — только файлы с правильным префиксом, без «Все файлы»
    $patterns = "${prefix}*.mp4;${prefix}*.mkv;${prefix}*.mov;${prefix}*.flv"
    $ofd.Filter = "Записи «$prefix» ($patterns)|$patterns"

    if ($ofd.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Step 'Загрузка отменена пользователем.'
        return
    }

    # Двойная защита: даже если бы пользователь ввёл путь вручную, отсеиваем не подходящие
    $selectedPaths = @($ofd.FileNames | Where-Object {
        [IO.Path]::GetFileName($_).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })

    if ($selectedPaths.Count -eq 0) {
        Set-Status "Не выбраны файлы с префиксом «$prefix»." 'Yellow'
        return
    }

    $filesToUpload = @($selectedPaths |
        ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_ -and $_.Length -gt 0 })

    if ($filesToUpload.Count -eq 0) {
        Set-Status 'Выбранные файлы недоступны или пусты.' 'Red'
        return
    }

    # ── Дедуп: отсекаем то, что уже загружено (по локальному логу + по Dropbox)
    Write-Step 'Проверяем, какие файлы уже загружены…'
    $history = Load-UploadHistory
    $skipped = @()
    $pending = @()
    $remoteToken = $null
    try {
        $remoteToken = Get-DropboxAccessToken
    } catch {
        Write-Log "Не удалось получить access token для дедупа: $($_.Exception.Message)"
    }
    foreach ($f in $filesToUpload) {
        $key = Get-FileDedupSignature -Path $f.FullName
        $alreadyLocal  = $key -and $history.ContainsKey($key)
        $alreadyRemote = $false
        if (-not $alreadyLocal -and $remoteToken) {
            $alreadyRemote = Test-UploadedOnDropbox -AccessToken $remoteToken -File $f -Size $f.Length -Path $f.FullName
            if ($alreadyRemote) {
                # Записываем в локальный лог, чтобы в следующий раз не дёргать Dropbox
                Add-UploadHistoryEntry -Key $key -File $f -DropboxId $null -DropboxPath (Get-DropboxUploadPath -File $f)
                $history = Load-UploadHistory
            }
        }
        if ($alreadyLocal -or $alreadyRemote) {
            $reason = if ($alreadyLocal) { 'локально' } else { 'в Dropbox' }
            Write-Log "Пропуск дубля ($reason): $($f.Name)"
            $skipped += $f
        } else {
            $pending += [pscustomobject]@{ File = $f; Key = $key }
        }
    }
    if ($skipped.Count -gt 0) {
        Write-Step ("Пропущено уже загруженных: {0}" -f $skipped.Count)
    }
    $filesToUpload = @($pending | ForEach-Object { $_.File })
    if ($filesToUpload.Count -eq 0) {
        Set-Status 'Все выбранные файлы уже загружены ранее.' 'Green'
        Write-Step '✓ Новых файлов для загрузки нет.'
        return
    }
    # Передадим $pending в Upload-RecordedFiles через скриптовый словарь — там по File берётся Key
    $script:UploadDedupKeys = @{}
    foreach ($p in $pending) { $script:UploadDedupKeys[$p.File.FullName] = $p.Key }

    $script:IsBusy = $true
    Set-AuxControlsEnabled $false
    Disable-Button $btnUpload
    Disable-Button $btnInstall
    Disable-Button $btnLaunch
    Disable-Button $btnFresh
    Disable-Button $btnClean
    $script:IsUploading = $true
    $form.Text = '⚠ ЗАГРУЗКА — НЕ ЗАКРЫВАЙТЕ!'
    Set-Status '⚠ НЕ ЗАКРЫВАЙТЕ ОКНО! Идёт загрузка записей...' 'Yellow'
    if ($script:UploadStateLabel_ref) { $script:UploadStateLabel_ref.Text = 'Загрузка' }
    if ($script:UploadHintLabel_ref) { $script:UploadHintLabel_ref.Text = "Файлов: $($filesToUpload.Count)" }

    Write-Step 'Не закрывайте окно до конца загрузки. Загрузка может занять от 10 до 60 минут.'

    try {
        $uploadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Upload-RecordedFiles -Files $filesToUpload
        $uploadStopwatch.Stop()

        $elapsed = $uploadStopwatch.Elapsed
        $elapsedStr = '{0:00}:{1:00}:{2:00}' -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds
        Write-Step "Время загрузки: $elapsedStr"

        Reset-RecordingMonitor
        Set-Status '✓ Все записи успешно загружены!' 'Green'
        if ($script:UploadStateLabel_ref) { $script:UploadStateLabel_ref.Text = 'Загружено' }
        if ($script:UploadHintLabel_ref) { $script:UploadHintLabel_ref.Text = "Время загрузки: $elapsedStr" }
        Write-Step 'Готово!'
    }
    catch {
        Clear-UploadProgress
        Write-ErrorDetails -Context 'Загрузка записей' -ErrorRecord $_
        Set-Status 'Ошибка загрузки. Можно нажать повторно.' 'Red'
        if ($script:UploadStateLabel_ref) { $script:UploadStateLabel_ref.Text = 'Ошибка загрузки' }
        if ($script:UploadHintLabel_ref) { $script:UploadHintLabel_ref.Text = 'Подробности доступны через кнопку «Логи»' }
    }
    finally {
        $script:IsUploading = $false
        $script:IsBusy = $false
        Set-AuxControlsEnabled $true
        $form.Text = 'Goodwin OBS'
        Enable-Button $btnUpload
        Enable-Button $btnInstall
        Enable-Button $btnLaunch
        Enable-Button $btnFresh
        Enable-Button $btnClean
        if (Test-Path $TempRoot) {
            Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Update-OverviewState
    }
})

# ── Кнопка «Чистая установка» ──────────────────────────────────────────────
$btnFresh.Add_Click({
    if ($script:IsBusy) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show('Удалить текущую установку OBS и установить заново?','Чистая установка',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $script:IsBusy = $true
    Set-AuxControlsEnabled $false
    Disable-Button $btnFresh
    Set-Status 'Чистая установка...' 'Yellow'
    try {
        if (Test-Path $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop }
        Ensure-Tls12
        New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
        Install-ObsPortable -ForceDownload
        Install-PortableSettings

        Write-Step 'Проверяем доступ к Dropbox'
        if (Test-DropboxAccess) {
            Write-Step '✓ Доступ к Dropbox подтверждён'
        } else {
            Write-Step 'Не удалось подтвердить доступ к Dropbox. Подробности доступны через «Логи».'
        }

        Set-Status 'OBS установлен чисто.' 'Green'
        $script:ObsLaunchCompleted = $false
        Enable-Button $btnLaunch
        Update-OverviewState
    } catch {
        Write-ErrorDetails -Context 'Чистая установка OBS' -ErrorRecord $_
        Set-Status ('Ошибка чистой установки: ' + $_.Exception.Message) 'Red'
    } finally {
        $script:IsBusy = $false
        Set-AuxControlsEnabled $true
        Enable-Button $btnFresh
    }
})

function Invoke-CleanObs {
    if ($script:IsBusy) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show('Удалить папку OBS и временные файлы?','Очистить',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (Test-Path $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Step "Удалено $InstallDir" }
    if (Test-Path $TempRoot)   { Remove-Item -LiteralPath $TempRoot   -Recurse -Force -ErrorAction SilentlyContinue }
    Set-Status 'Очистка выполнена.' 'Green'
    $script:ObsLaunchCompleted = $false
    Disable-Button $btnLaunch
    Update-OverviewState
}

# ── Кнопка «Открыть папку записей» ─────────────────────────────────────────
$btnFolder.Add_Click({
    if ($script:IsBusy) { return }
    try {
        if (Test-Path $script:RecordingRoot) {
            Start-Process explorer.exe $script:RecordingRoot
        } else {
            Write-Step ('Папка записей не существует: ' + $script:RecordingRoot)
            Set-Status ('Папка записей не существует: ' + $script:RecordingRoot) 'Red'
        }
    }
    catch { Write-ErrorDetails -Context 'Открыть папку записей' -ErrorRecord $_ }
})

# ── Кнопка «Логи» ───────────────────────────────────────────────────────────
$btnLogs.Add_Click({
    try { Show-LogViewerDialog }
    catch {
        Write-ErrorDetails -Context 'Просмотр логов' -ErrorRecord $_
        Set-Status ('Не удалось открыть логи: ' + $_.Exception.Message) 'Red'
    }
})

# ── Закрытие окна (защита от закрытия во время загрузки) ──────────────────
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:IsUploading) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Идёт загрузка файлов в Dropbox!`n`nЕсли закрыть сейчас, загрузка прервётся.`nПри следующем запуске можно будет повторить загрузку.`n`nВы уверены?",
            '⚠ Загрузка не завершена',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
    }
    elseif ($script:IsBusy) {
        # Любая другая операция (установка/настройка) — тоже не закрываем молча,
        # иначе получим полузаписанную папку OBS.
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Идёт операция (установка или настройка).`n`nЕсли закрыть сейчас, она прервётся и установка может остаться неполной.`n`nВсё равно закрыть?",
            '⚠ Операция не завершена',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
    }
    # Гарантированно останавливаем предпросмотр камеры (освобождаем COM-граф/устройство).
    try { [GoodwinCam.CameraPreview]::Stop() } catch {}
    try { if ($script:StateTimer) { $script:StateTimer.Stop(); $script:StateTimer.Dispose() } } catch {}
    if (Test-Path $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
})

# Привязываем иконку и предупреждение к окну PowerShell-консоли, после чего сворачиваем его
try {
    if ($script:AppIcon) { [ConsoleHelper]::SetConsoleIcon($script:AppIcon.Handle) }
    try { $Host.UI.RawUI.WindowTitle = 'Goodwin OBS — процесс приложения' } catch {}
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
    Write-Host '║  НЕ ЗАКРЫВАЙТЕ ЭТО ОКНО!                                 ║' -ForegroundColor Yellow
    Write-Host '║  Основные логи пишутся в файл и доступны кнопкой Логи.   ║' -ForegroundColor Yellow
    Write-Host '║  Окно можно свернуть — но не закрывайте,                 ║' -ForegroundColor Yellow
    Write-Host '║  иначе приложение завершится.                            ║' -ForegroundColor Yellow
    Write-Host '╚══════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
    Write-Host ''
    [ConsoleHelper]::MinimizeConsole()
} catch {}

Write-Log 'Goodwin OBS запущен'
Write-Step "Debug версия программы: $script:DebugVersion"
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log ("Process status: elevatedAdmin={0}; user={1}; pid={2}; sta={3}" -f (Test-GoodwinAdministrator), $identity.Name, $PID, ([Threading.Thread]::CurrentThread.GetApartmentState()))
}
catch {
    Write-Log ("Process status: elevatedAdmin={0}; pid={1}; sta={2}" -f (Test-GoodwinAdministrator), $PID, ([Threading.Thread]::CurrentThread.GetApartmentState()))
}
if ($script:SelectedNickname -and $script:SelectedNickname -ne 'untitled') {
    Write-Step "Загружены настройки: никнейм = $script:SelectedNickname"
}
Write-Step 'Готов к работе. Нажмите «Установить» для начала.'
[System.Windows.Forms.Application]::Run($form)
