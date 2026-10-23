#Requires -Version 7
<#
.SYNOPSIS
    Скачивает звук из YouTube готовым yt.cmd (NoDPI) и разделяет на дорожки (Demucs).

.DESCRIPTION
    Обёртка над системным yt.cmd из PATH (D:\Appz\yt.cmd): он качает через
    локальный NoDPI-прокси. Здесь мы просим у него только аудио (WAV), забираем
    путь к файлу и прогоняем через separate.ps1.

.EXAMPLE
    .\ytsep.cmd "https://youtu.be/XXXX"
    .\ytsep.cmd "https://youtu.be/XXXX" -HQ
    .\ytsep.cmd "https://youtu.be/XXXX" -SixStems -KeepAudio
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Urls,

    [string]$DlDir = 'downloads',

    [string]$Model = 'htdemucs',

    [string]$Out = '',

    [ValidateSet('', 'vocals', 'drums', 'bass', 'other', 'guitar', 'piano')]
    [string]$TwoStems = '',

    [ValidateSet('vocals', 'drums', 'bass', 'other', 'guitar', 'piano')]
    [string[]]$Stems = @(),

    [ValidateSet('', 'cuda', 'cpu')]
    [string]$Device = '',

    [int]$Segment = 0,

    [int]$Shifts = 0,

    [ValidateSet('mp3', 'wav')]
    [string]$Format = 'mp3',

    [ValidateRange(0.0, 100.0)]
    [double]$StemGain = 2,

    [switch]$Mp3,

    [switch]$HQ,

    [switch]$SixStems,

    [string[]]$Extra,

    [switch]$Playlist,

    [switch]$KeepAudio,

    [string]$Proxy = '',

    [switch]$NoProxy,

    [string[]]$YtdlpArgs,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Show-Usage {
    Write-Host @'
ytsep.ps1 / ytsep.cmd — скачать звук из YouTube (через yt.cmd, NoDPI) и разделить.

Использование:
  .\ytsep.cmd <URL> [параметры]

Скачивание (использует системный yt.cmd из PATH; нужен запущенный NoDPI):
  -DlDir <папка>        Куда качать аудио (по умолчанию downloads).
  -Playlist             Скачать весь плейлист.
  -KeepAudio            Оставить скачанный WAV.
  -Proxy <url>          Задать YT_PROXY для yt.cmd (по умолчанию http://127.0.0.1:8881).
  -NoProxy              Отключить прокси (YT_PROXY=none).
  -YtdlpArgs <а...>     Доп. аргументы yt-dlp (передаются в yt.cmd).

Разделение (передаётся в separate.ps1):
  -HQ                   htdemucs_ft + htdemucs_6s -> + guitar, piano (качество).
  -SixStems             htdemucs_6s -> 6 стемов за один проход.
  -Model <имя>          Модель (по умолчанию htdemucs).
  -Out <папка>          Куда сохранять стемы (по умолчанию separated/separated_hq).
  -TwoStems <stem>      Только выбранный stem и "минус".
  -Stems <s...>         Сохранять только перечисленные стемы (по умолчанию все).
  -Device <dev>         cuda или cpu.
  -Segment <сек>        Размер чанка при нехватке видеопамяти.
  -Shifts <n>           Больше сдвигов = лучше/медленнее.
  -Format <fmt>         Формат стемов: mp3 или wav (по умолчанию mp3).
  -StemGain <коэф>      Вес стема в миксе «оригинал + стем» (по умолчанию 2 = 2:1).
  -Help                 Показать эту справку.

Примеры:
  .\ytsep.cmd "https://youtu.be/XXXX"
  .\ytsep.cmd "https://youtu.be/XXXX" -HQ
  .\ytsep.cmd "https://youtu.be/XXXX" -SixStems -KeepAudio
'@
}

function Resolve-ProjectRoot {
    <#
    .SYNOPSIS
        Ищет корень проекта (где лежат separate.ps1 и .venv).
    .DESCRIPTION
        Нужен, потому что скрипт могут запускать и копией из другого места
        (например, shim-ы в PATH), и тогда $PSScriptRoot — не корень проекта.
        Порядок: $env:SOUND_SEPARATE_HOME -> $PSScriptRoot -> текущая папка ->
        путь проекта по умолчанию.
    #>
    $candidates = @()
    if ($env:SOUND_SEPARATE_HOME) { $candidates += $env:SOUND_SEPARATE_HOME }
    $candidates += $PSScriptRoot
    $candidates += (Get-Location).Path
    $candidates += 'D:\Dev\sound-separate'

    $ordered = @()
    $seen = @{}
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $full = try { [IO.Path]::GetFullPath($c) } catch { $c }
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        $ordered += $full
    }

    foreach ($full in $ordered) {
        if ((Test-Path -LiteralPath (Join-Path $full 'separate.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $full '.venv\Scripts\python.exe'))) { return $full }
    }
    foreach ($full in $ordered) {
        if (Test-Path -LiteralPath (Join-Path $full 'separate.ps1')) { return $full }
    }
    return $PSScriptRoot
}

if ($Help -or -not $Urls) {
    Show-Usage
    exit 0
}

$bad = @($Urls | Where-Object { $_ -notmatch '^https?://' })
if ($bad) {
    throw ("Не URL (проверьте параметры, напр. -Out/-DlDir): " + ($bad -join ', '))
}

$root = Resolve-ProjectRoot

$ytcmd = (Get-Command yt.cmd -ErrorAction SilentlyContinue)
if (-not $ytcmd) {
    throw 'yt.cmd не найден в PATH. Используется готовый загрузчик (D:\Appz\yt.cmd).'
}
$ytcmdPath = $ytcmd.Source

$dlDirFull = Join-Path $root $DlDir
New-Item -ItemType Directory -Force -Path $dlDirFull | Out-Null

# yt.cmd не должен ждать нажатия клавиши
$env:YT_NOPAUSE = '1'
if ($NoProxy) { $env:YT_PROXY = 'none' }
elseif ($Proxy) { $env:YT_PROXY = $Proxy }

# Просим у yt.cmd только аудио (WAV) и печать итогового пути.
$ytExtra = @(
    '-f', 'bestaudio/best',
    '-x', '--audio-format', 'wav', '--audio-quality', '0',
    '-P', $dlDirFull,
    '--print', 'after_move:filepath',
    '--no-simulate'
)
if (-not $Playlist) { $ytExtra += '--no-playlist' }
if ($YtdlpArgs) { $ytExtra += $YtdlpArgs }

Write-Host "yt.cmd: $ytcmdPath" -ForegroundColor Cyan
Write-Host ("Скачивание в: {0}" -f $dlDirFull) -ForegroundColor Cyan
Write-Host ''

$output = & $ytcmdPath @ytExtra @Urls
$files = @($output | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
if (-not $files) {
    Write-Host ($output | Out-String) -ForegroundColor DarkYellow
    Write-Warning @'
Не удалось скачать аудио через yt.cmd.
Проверьте:
  • запущен ли NoDPI на 127.0.0.1:8881 (или задайте -Proxy/-NoProxy);
  • доступна ли ссылка и cookies Firefox (yt.cmd использует --cookies-from-browser firefox);
  • для отладки: -YtdlpArgs -v
'@
    throw 'Скачивание не удалось.'
}

Write-Host ''
Write-Host 'Скачано:' -ForegroundColor Green
$files | ForEach-Object { Write-Host ("  {0}" -f $_) }

$sepScript = Join-Path $root 'separate.ps1'
$sepParams = @{}
if ($Model) { $sepParams['Model'] = $Model }
if ($Out) { $sepParams['Out'] = $Out }
if ($TwoStems) { $sepParams['TwoStems'] = $TwoStems }
if ($Stems) { $sepParams['Stems'] = $Stems }
if ($Device) { $sepParams['Device'] = $Device }
if ($Segment -gt 0) { $sepParams['Segment'] = $Segment }
if ($Shifts -gt 0) { $sepParams['Shifts'] = $Shifts }
if ($Format) { $sepParams['Format'] = $Format }
$sepParams['StemGain'] = $StemGain
if ($Mp3) { $sepParams['Mp3'] = $true }
if ($HQ) { $sepParams['HQ'] = $true }
if ($SixStems) { $sepParams['SixStems'] = $true }
if ($Extra) { $sepParams['Extra'] = $Extra }

$lastCode = 0
foreach ($f in $files) {
    Write-Host ''
    Write-Host ("=== Разделение: {0} ===" -f (Split-Path $f -Leaf)) -ForegroundColor Cyan
    & $sepScript -Tracks $f @sepParams
    if ($LASTEXITCODE -ne 0) { $lastCode = $LASTEXITCODE }
    if (-not $KeepAudio) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}
exit $lastCode
