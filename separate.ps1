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

    [string[]]$Stems = @(),

    [string]$Dir = '',

    [switch]$Recurse,

    [ValidateSet('', 'cuda', 'cpu')]
    [string]$Device = '',

    [int]$Segment = 0,

    [int]$Shifts = 0,

    [ValidateSet('mp3', 'wav')]
    [string]$Format = 'mp3',

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
  .\separate.ps1 -Dir <папка> [-Recurse] [параметры]

Режимы:
  (по умолчанию)    htdemucs: vocals, drums, bass, other. Быстро.
  -HQ               htdemucs_ft + htdemucs_6s -> vocals, drums, bass, guitar,
                    piano, other. Повышенное качество + гитара/пиано. Медленнее
                    (несколько минут на трек). Пишет 24-бит WAV.
  -SixStems         htdemucs_6s: vocals, drums, bass, guitar, piano, other.
                    Один проход, быстрее, но качество базовое.

Параметры:
  -Model <имя>      Модель (по умолчанию htdemucs). Пример: htdemucs_ft, htdemucs_6s.
  -Dir <папка>      Обработать все аудиофайлы в папке (batch). Можно указать вместо
                    списка файлов.
  -Recurse          С -Dir: включать вложенные папки.
  -Out <папка>      Куда сохранять. По умолчанию: separated (или separated_hq для -HQ).
  -TwoStems <stem>  Только выбранный stem и "минус" (vocals|drums|bass|other|guitar|piano).
  -Stems <s...>     Сохранять только перечисленные стемы (через запятую или пробел).
                    По умолчанию — все. Пример: -Stems vocals,drums.
                    В -HQ пропускает лишние стадии; в обычном режиме удаляет
                    лишние файлы после разделения (время не экономится).
  -Device <dev>     cuda или cpu (по умолчанию авто).
  -Segment <сек>    Размер чанка; уменьшить при нехватке видеопамяти.
  -Shifts <n>       Больше сдвигов = лучше, но медленнее (HQ по умолчанию 2).
  -Format <fmt>     Формат результата: mp3 или wav. По умолчанию mp3.
  -Extra <арг...>   Доп. аргументы Demucs в обычном режиме.
  -Help             Показать эту справку.

Результат: плоские файлы <трек>_<стем>.<fmt> в -Out (напр. test_drums.mp3),
без промежуточных папок модели и трека.

Примеры:
  .\separate.ps1 test.mp3
  .\separate.ps1 "song.mp3" -HQ
  .\separate.ps1 "song.mp3" -SixStems -Format wav
  .\separate.ps1 "song.mp3" -TwoStems vocals
  .\separate.ps1 "song.mp3" -HQ -Stems vocals,drums
  .\separate.ps1 -Dir ".\songs" -Recurse -Stems vocals
'@
}

function Flatten-Stems {
    param(
        [string]$OutDir,
        [string]$ModelSub,
        [string[]]$Keep
    )
    $base = if ($ModelSub) { Join-Path $OutDir $ModelSub } else { $OutDir }
    if (-not (Test-Path -LiteralPath $base)) { return }

    $trackDirs = @(Get-ChildItem -LiteralPath $base -Directory)
    foreach ($td in $trackDirs) {
        $trackName = $td.Name
        foreach ($f in Get-ChildItem -LiteralPath $td.FullName -File) {
            if ($Keep -and ($f.BaseName -notin $Keep)) {
                Remove-Item -LiteralPath $f.FullName -Force
                continue
            }
            $target = Join-Path $OutDir ("{0}_{1}{2}" -f $trackName, $f.BaseName, $f.Extension)
            Move-Item -LiteralPath $f.FullName -Destination $target -Force
        }
        Remove-Item -LiteralPath $td.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($ModelSub) {
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Help -or (-not $Tracks -and -not $Dir)) {
    Show-Usage
    exit 0
}

$Stems = @($Stems | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } |
    Where-Object { $_ } | Select-Object -Unique)
if ($Stems) {
    $validStems = @('vocals', 'drums', 'bass', 'other', 'guitar', 'piano')
    $badStems = @($Stems | Where-Object { $_ -notin $validStems })
    if ($badStems) {
        throw ("Неверные стемы: {0}. Допустимо: {1}" -f ($badStems -join ', '), ($validStems -join ', '))
    }
}

$Format = $Format.Trim().ToLower()
if ($Mp3) { Write-Warning '-Mp3 устарел; используйте -Format mp3 (значение по умолчанию).' }
if ($Format -notin @('mp3', 'wav')) {
    throw ("Неверный формат: {0}. Допустимо: mp3, wav" -f $Format)
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

if ($Dir) {
    $dirPath = Get-Item -Path $Dir -ErrorAction SilentlyContinue
    if (-not $dirPath -or -not $dirPath.PSIsContainer) {
        throw "Папка не найдена: $Dir"
    }
    $exts = @('.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wma', '.aiff', '.aif', '.mp4', '.mkv', '.webm', '.mov')
    $found = Get-ChildItem -Path $dirPath.FullName -File -Recurse:$Recurse |
        Where-Object { $exts -contains $_.Extension.ToLower() }
    if (-not $found) {
        Write-Warning ("В папке нет аудиофайлов: {0}" -f $dirPath.FullName)
    }
    $resolved += ($found | ForEach-Object { $_.FullName })
}

$resolved = @($resolved | Select-Object -Unique)
if (-not $resolved) { throw 'Не найдено ни одного входного файла.' }

if ($HQ) {
    if ($TwoStems) { Write-Warning '-TwoStems игнорируется в режиме -HQ.' }
    $outDir = if ($Out) { $Out.Trim() } else { 'separated_hq' }
    $outDir = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $outDir))
    $hqArgs = @((Join-Path $root 'hq_separate.py'), '-o', $outDir)
    if ($Device) { $hqArgs += @('--device', $Device) }
    if ($Segment -gt 0) { $hqArgs += @('--segment', $Segment) }
    $hqArgs += @('--shifts', ($(if ($Shifts -gt 0) { $Shifts } else { 2 })))
    $hqArgs += @('--format', $Format)
    if ($Stems) { $hqArgs += @('--stems', ($Stems -join ',')) }
    if ($Extra) { $hqArgs += $Extra }
    $hqArgs += $resolved

    Write-Host 'Режим: HQ (htdemucs_ft + htdemucs_6s) -> vocals, drums, bass, guitar, piano, other' -ForegroundColor Cyan
    Write-Host ("Вывод:  {0}" -f $outDir) -ForegroundColor Cyan
    Write-Host ''
    & $python @hqArgs
    $code = $LASTEXITCODE
    if ($code -eq 0) { Flatten-Stems -OutDir $outDir -ModelSub '' -Keep $Stems }
    exit $code
}

$model = if ($SixStems) { 'htdemucs_6s' } else { $Model }
$outDir = if ($Out) { $Out.Trim() } else { 'separated' }
$outDir = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $outDir))

$demucsArgs = @('-m', 'demucs', '-n', $model, '-o', $outDir)
if ($TwoStems) { $demucsArgs += @('--two-stems', $TwoStems) }
if ($Device) { $demucsArgs += @('-d', $Device) }
if ($Segment -gt 0) { $demucsArgs += @('--segment', $Segment) }
if ($Shifts -gt 0) { $demucsArgs += @('--shifts', $Shifts) }
if ($Format -eq 'mp3') { $demucsArgs += '--mp3' }
if ($Stems) {
    $unknown = @($Stems | Where-Object { $_ -in @('guitar', 'piano') })
    if ($unknown -and $model -notmatch '6s$') {
        Write-Warning ("Стемы guitar/piano доступны только в htdemucs_6s (или режиме -HQ): " + ($unknown -join ', '))
    }
}
if ($Extra) { $demucsArgs += $Extra }
$demucsArgs += $resolved

Write-Host "Модель: $model" -ForegroundColor Cyan
Write-Host ("Файлов: {0}" -f $resolved.Count) -ForegroundColor Cyan
Write-Host ("Вывод:  {0}" -f $outDir) -ForegroundColor Cyan
Write-Host ''

& $python @demucsArgs
$code = $LASTEXITCODE

if ($code -eq 0) {
    Flatten-Stems -OutDir $outDir -ModelSub $model -Keep $Stems
}

exit $code
