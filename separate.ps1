#Requires -Version 7
<#
.SYNOPSIS
    Обёртка над Demucs: разделение аудио на дорожки (stems), включая гитару.

.EXAMPLE
    .\separate.ps1 test.mp3
    .\separate.ps1 "song.mp3" -HQ
    .\separate.ps1 "song.mp3" -SixStems
    .\separate.ps1 "song.mp3" -TwoStems vocals
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Tracks,

    [string]$Model = 'htdemucs',

    [string]$Out = '',

    [ValidateSet('', 'vocals', 'drums', 'bass', 'other', 'guitar', 'piano')]
    [string]$TwoStems = '',

    [ValidateSet('', 'cuda', 'cpu')]
    [string]$Device = '',

    [int]$Segment = 0,

    [int]$Shifts = 0,

    [switch]$Mp3,

    [switch]$HQ,

    [switch]$SixStems,

    [string[]]$Extra,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Show-Usage {
    Write-Host @'
separate.ps1 — разделение аудио на дорожки (stems) через Demucs (бесплатно, локально).

Использование:
  .\separate.ps1 <файлы> [параметры]

Режимы:
  (по умолчанию)    htdemucs: vocals, drums, bass, other. Быстро.
  -HQ               htdemucs_ft + htdemucs_6s -> vocals, drums, bass, guitar,
                    piano, other. Повышенное качество + гитара/пиано. Медленнее
                    (несколько минут на трек). Пишет 24-бит WAV.
  -SixStems         htdemucs_6s: vocals, drums, bass, guitar, piano, other.
                    Один проход, быстрее, но качество базовое.

Параметры:
  -Model <имя>      Модель (по умолчанию htdemucs). Пример: htdemucs_ft, htdemucs_6s.
  -Out <папка>      Куда сохранять. По умолчанию: separated (или separated_hq для -HQ).
  -TwoStems <stem>  Только выбранный stem и "минус" (vocals|drums|bass|other|guitar|piano).
  -Device <dev>     cuda или cpu (по умолчанию авто).
  -Segment <сек>    Размер чанка; уменьшить при нехватке видеопамяти.
  -Shifts <n>       Больше сдвигов = лучше, но медленнее (HQ по умолчанию 2).
  -Mp3              Сохранять в mp3 вместо wav (только обычный режим).
  -Extra <арг...>   Доп. аргументы Demucs в обычном режиме.
  -Help             Показать эту справку.

Примеры:
  .\separate.ps1 test.mp3
  .\separate.ps1 "song.mp3" -HQ
  .\separate.ps1 "song.mp3" -SixStems -Mp3
  .\separate.ps1 "song.mp3" -TwoStems vocals
'@
}

if ($Help -or -not $Tracks) {
    Show-Usage
    exit 0
}

$root = $PSScriptRoot
$python = Join-Path $root '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    throw "Не найден Python окружения: $python`nСначала создайте окружение (.venv) и установите demucs."
}

$resolved = @()
foreach ($t in $Tracks) {
    $items = Get-Item -Path $t -ErrorAction SilentlyContinue
    if ($items) { $resolved += $items.FullName }
    else { Write-Warning "Файл не найден: $t" }
}
if (-not $resolved) { throw 'Не найдено ни одного входного файла.' }

if ($HQ) {
    if ($TwoStems -or $Mp3) { Write-Warning '-TwoStems/-Mp3 игнорируются в режиме -HQ.' }
    $outDir = if ($Out) { $Out.Trim() } else { 'separated_hq' }
    $hqArgs = @((Join-Path $root 'hq_separate.py'), '-o', $outDir)
    if ($Device) { $hqArgs += @('--device', $Device) }
    if ($Segment -gt 0) { $hqArgs += @('--segment', $Segment) }
    $hqArgs += @('--shifts', ($(if ($Shifts -gt 0) { $Shifts } else { 2 })))
    if ($Extra) { $hqArgs += $Extra }
    $hqArgs += $resolved

    Write-Host 'Режим: HQ (htdemucs_ft + htdemucs_6s) -> vocals, drums, bass, guitar, piano, other' -ForegroundColor Cyan
    Write-Host ("Вывод:  {0}" -f (Join-Path $root $outDir)) -ForegroundColor Cyan
    Write-Host ''
    & $python @hqArgs
    exit $LASTEXITCODE
}

$model = if ($SixStems) { 'htdemucs_6s' } else { $Model }
$outDir = if ($Out) { $Out.Trim() } else { 'separated' }

$demucsArgs = @('-m', 'demucs', '-n', $model, '-o', $outDir)
if ($TwoStems) { $demucsArgs += @('--two-stems', $TwoStems) }
if ($Device) { $demucsArgs += @('-d', $Device) }
if ($Segment -gt 0) { $demucsArgs += @('--segment', $Segment) }
if ($Shifts -gt 0) { $demucsArgs += @('--shifts', $Shifts) }
if ($Mp3) { $demucsArgs += '--mp3' }
if ($Extra) { $demucsArgs += $Extra }
$demucsArgs += $resolved

Write-Host "Модель: $model" -ForegroundColor Cyan
Write-Host ("Файлов: {0}" -f $resolved.Count) -ForegroundColor Cyan
Write-Host ("Вывод:  {0}" -f (Join-Path $root $outDir)) -ForegroundColor Cyan
Write-Host ''

& $python @demucsArgs
exit $LASTEXITCODE
