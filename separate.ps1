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
  -Out <папка>      Куда сохранять. По умолчанию: папка separated ВНУТРИ указанной
                    -Dir (напр. -Dir test -> test\separated), для -HQ - separated_hq.
                    Без -Dir (одиночные файлы) — .\separated от текущей папки.
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

Результат: плоские файлы в -Out, без промежуточных папок модели и трека.
Для каждого стема пишутся три файла:
  <трек>_<стем>_only.<fmt>   — только инструмент (напр. test_drums_only.mp3);
  <трек>_<стем>.<fmt>        — оригинал + инструмент, 1:1 (напр. test_drums.mp3);
  <трек>_<стем>_2to1.<fmt>   — инструмент громче оригинала, 2:1 (напр. test_drums_2to1.mp3).
При -Dir подпапки исходной папки повторяются в -Out (папка модели не создаётся).

Примеры:
  .\separate.ps1 test.mp3
  .\separate.ps1 "song.mp3" -HQ
  .\separate.ps1 "song.mp3" -SixStems -Format wav
  .\separate.ps1 "song.mp3" -TwoStems vocals
  .\separate.ps1 "song.mp3" -HQ -Stems vocals,drums
  .\separate.ps1 -Dir ".\songs" -Recurse -Stems vocals
'@
}

function Resolve-ProjectRoot {
    <#
    .SYNOPSIS
        Ищет корень проекта (где лежат .venv, hq_separate.py, mix_stem.py).
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
        if ((Test-Path -LiteralPath (Join-Path $full '.venv\Scripts\python.exe')) -and
            (Test-Path -LiteralPath (Join-Path $full 'hq_separate.py'))) { return $full }
    }
    foreach ($full in $ordered) {
        if (Test-Path -LiteralPath (Join-Path $full '.venv\Scripts\python.exe')) { return $full }
    }
    foreach ($full in $ordered) {
        if (Test-Path -LiteralPath (Join-Path $full 'hq_separate.py')) { return $full }
    }
    return $PSScriptRoot
}

function Resolve-Python {
    <#
    .SYNOPSIS
        Находит интерпретатор с demucs: .venv проекта -> .venv в текущей папке -> системный python.
    #>
    param([string]$ProjectRoot)

    $candidates = @()
    if ($env:SOUND_SEPARATE_PYTHON) { $candidates += $env:SOUND_SEPARATE_PYTHON }
    if ($ProjectRoot) { $candidates += (Join-Path $ProjectRoot '.venv\Scripts\python.exe') }
    $candidates += (Join-Path (Get-Location).Path '.venv\Scripts\python.exe')
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot '.venv\Scripts\python.exe') }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) {
        Write-Warning "Использую системный python: $($pyCmd.Source)"
        return $pyCmd.Source
    }
    return $null
}

function Test-DemucsInstalled {
    param([string]$Python)
    if (-not $Python) { return $false }
    & $Python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('demucs') else 1)" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Flatten-Stems {
    <#
    .SYNOPSIS
        Переносит стемы из промежуточных папок модели/трека прямо в -Out.
    .DESCRIPTION
        Demucs (и hq_separate.py) пишут в <Out>/<модель>/<трек>/. Папку модели
        не оставляем: файлы переносятся в -Out (для -Recurse — в подпапку с
        исходным именем папки трека), после чего промежуточные папки удаляются.
        -OnlyTracks ограничивает обход именами реально обработанных файлов,
        чтобы Flatten не трогал уже созданные подпапки вывода (в HQ-режиме
        промежуточной папки модели нет, и -Out обходится целиком).
    #>
    param(
        [string]$OutDir,
        [string]$ModelSub,
        [string[]]$Keep,
        [hashtable]$Subdirs = @{},
        [hashtable]$OnlyTracks = $null
    )
    $base = if ($ModelSub) { Join-Path $OutDir $ModelSub } else { $OutDir }
    if (-not (Test-Path -LiteralPath $base)) { return }

    $trackDirs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $OnlyTracks -or $OnlyTracks.Contains($_.Name) })
    foreach ($td in $trackDirs) {
        $trackName = $td.Name
        $rel = if ($Subdirs.ContainsKey($trackName)) { [string]$Subdirs[$trackName] } else { '' }
        $destDir = if ($rel) { Join-Path $OutDir $rel } else { $OutDir }
        if ($rel) { $null = New-Item -ItemType Directory -Path $destDir -Force }
        foreach ($f in Get-ChildItem -LiteralPath $td.FullName -File) {
            $stemName = $f.BaseName -replace '_only$', ''
            if ($Keep -and ($stemName -notin $Keep)) {
                Remove-Item -LiteralPath $f.FullName -Force
                continue
            }
            $onlyName = "{0}_only{1}" -f $stemName, $f.Extension
            $target = Join-Path $destDir ("{0}_{1}" -f $trackName, $onlyName)
            Move-Item -LiteralPath $f.FullName -Destination $target -Force
        }
        Remove-Item -LiteralPath $td.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($ModelSub) {
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Mix-Stems {
    <#
    .SYNOPSIS
        Досчитывает миксы «оригинал + стем» из уже сохранённых <трек>_<стем>_only.<fmt>.
    .DESCRIPTION
        Для каждого стема пишутся два варианта:
          <трек>_<стем>.<fmt>       — оригинал + инструмент, 1:1;
          <трек>_<стем>_2to1.<fmt>  — инструмент вдвое громче оригинала (2:1).
        Для -Recurse файлы ищутся и создаются в той же подпапке, что и _only.
    #>
    param(
        [string]$OutDir,
        [string[]]$Originals,
        [string[]]$Keep,
        [string]$Format,
        [string]$Python,
        [string]$ProjectRoot,
        [hashtable]$Subdirs = @{}
    )
    $script = Join-Path $ProjectRoot 'mix_stem.py'
    # Варианты микса: инструмент : оригинал. Gain — вес стема в сумме.
    $variants = @(
        @{ Suffix = '';      Gain = '1' },  # 1:1
        @{ Suffix = '_2to1'; Gain = '2' }   # 2:1 — выделенный инструмент громче
    )
    foreach ($orig in $Originals) {
        $trackName = [IO.Path]::GetFileNameWithoutExtension($orig)
        $rel = if ($Subdirs.ContainsKey($orig)) { [string]$Subdirs[$orig] } else { '' }
        $srcDir = if ($rel) { Join-Path $OutDir $rel } else { $OutDir }
        $onlyFiles = @(Get-ChildItem -LiteralPath $srcDir -File -Filter "${trackName}_*_only.$Format" -ErrorAction SilentlyContinue)
        foreach ($of in $onlyFiles) {
            $stemName = $of.BaseName -replace "^${trackName}_", '' -replace '_only$', ''
            if ($Keep -and ($stemName -notin $Keep)) { continue }
            foreach ($v in $variants) {
                $mixOut = Join-Path $srcDir ("{0}_{1}{2}.{3}" -f $trackName, $stemName, $v.Suffix, $Format)
                Write-Host ("Микс: {0} + {1} -> {2}" -f (Split-Path $orig -Leaf), $stemName, (Split-Path $mixOut -Leaf)) -ForegroundColor DarkCyan
                & $Python $script --original $orig --stem $of.FullName --out $mixOut --format $Format --stem-gain $v.Gain
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning ("Не удалось смешать: {0}" -f $of.Name)
                }
            }
        }
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

$root = Resolve-ProjectRoot
$python = Resolve-Python -ProjectRoot $root
if (-not $python -or -not (Test-Path -LiteralPath $python)) {
    throw ("Не найден Python. Проверил: {0}. Создай .venv с demucs или добавь python в PATH." -f (Join-Path $root '.venv\Scripts\python.exe'))
}
if (-not (Test-DemucsInstalled -Python $python)) {
    Write-Warning ("В {0} нет пакета demucs — разделение, скорее всего, упадёт. Создай venv: python -m venv .venv; .venv\Scripts\pip install demucs" -f $python)
}

# Строка самопроверки: сразу видно, какой файл скрипта и какой интерпретатор
# реально выполнились (копия в PATH или старый файл ведут себя иначе).
Write-Host ("Скрипт: {0} ({1:yyyy-MM-dd HH:mm}) | python: {2}" -f `
    $PSCommandPath, (Get-Item -LiteralPath $PSCommandPath).LastWriteTime, $python) -ForegroundColor DarkGray

# Меньше фрагментации VRAM -> реже OOM (на Windows expandable_segments не поддерживается)
if (-not $env:PYTORCH_CUDA_ALLOC_CONF -and -not $IsWindows) {
    $env:PYTORCH_CUDA_ALLOC_CONF = 'expandable_segments:True'
}

$resolved = @()
$subdirs = @{}   # полный путь исходника -> подпапка внутри -Out ('' = сам -Out)

# Дефолтный -Out лежит ВНУТРИ исходной папки, а не рядом с ней:
#   -Dir test  -> test\separated   (для -HQ — test\separated_hq)
#   -Dir .     -> .\separated      (как и раньше)
# Без -Dir (одиночные файлы) дефолт остаётся относительным от текущей папки.
$defaultOutName = if ($HQ) { 'separated_hq' } else { 'separated' }
$outDir = if ($Out) { $Out.Trim() } else { $defaultOutName }
if (-not $Out -and $Dir) {
    $dirBase = try { (Get-Item -LiteralPath $Dir -ErrorAction Stop).FullName } catch { $null }
    if ($dirBase) { $outDir = Join-Path $dirBase $defaultOutName }
}
$outDir = if ([IO.Path]::IsPathRooted($outDir)) {
    [IO.Path]::GetFullPath($outDir)
} else {
    [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $outDir))
}
$outPrefix = $outDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
# Маркер папки вывода. По нему -Dir пропускает результаты прошлых запусков:
# иначе свои же стемы (par_drums.wav и т.п.) уходят на вход следующего прогона,
# особенно если новый -Out указывает в другое место.
$null = New-Item -ItemType Directory -Path $outDir -Force
Set-Content -LiteralPath (Join-Path $outDir '.sound-separate') -Value 'output dir of separate.ps1' -Encoding utf8

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
    # -Out по умолчанию лежит внутри -Dir — свои же стемы (и миксы) не должны
    # попадать во вход следующего запуска.
    if ($outDir -ne $dirPath.FullName) {
        $found = $found | Where-Object {
            -not $_.FullName.StartsWith($outPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }
    # Плюс наши папки вывода: с маркером .sound-separate и дефолтных имён
    # separated/separated_hq (последние — результаты прошлых запусков, созданные
    # до появления маркера). Иначе свои же стемы уходят на вход следующего
    # прогона: par_drums.wav -> par_drums_drums.wav.
    $dirs = @(Get-ChildItem -LiteralPath $dirPath.FullName -Directory -Recurse:$Recurse -ErrorAction SilentlyContinue)
    $legacy = @($dirs | Where-Object {
            $_.Name -in @('separated', 'separated_hq') -and
            $_.FullName -ne $outDir   # свой -Out и так отсекается ниже
        })
    $marked = @()
    foreach ($d in @($dirPath.FullName) + @($dirs | Select-Object -ExpandProperty FullName)) {
        if ($d -in @($legacy | Select-Object -ExpandProperty FullName) -or
            (Test-Path -LiteralPath (Join-Path $d '.sound-separate'))) {
            $marked += $d.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        }
    }
    if ($legacy) {
        Write-Host (">> Пропускаю папки вывода: {0}" -f (($legacy | Select-Object -ExpandProperty FullName) -join ', ')) -ForegroundColor DarkGray
    }
    if ($marked) {
        $found = $found | Where-Object {
            $p = $_.FullName
            -not ($marked | Where-Object { $p.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })
        }
    }
    if (-not $found) {
        Write-Warning ("В папке нет аудиофайлов: {0}" -f $dirPath.FullName)
    }
    foreach ($f in $found) {
        $resolved += $f.FullName
        # Внутри папки сохраняем её структуру: файлы из подпапок кладём в
        # одноимённые подпапки -Out (папку модели не создаём).
        $rel = [IO.Path]::GetRelativePath($dirPath.FullName, $f.DirectoryName)
        if ($rel -eq '.') { $rel = '' }
        $subdirs[$f.FullName] = $rel
    }
}

$resolved = @($resolved | Select-Object -Unique)
if (-not $resolved) { throw 'Не найдено ни одного входного файла.' }

# Предпроверка читаемости. Demucs обрабатывает список последовательно и падает
# на ПЕРВОМ нечитаемом файле — все следующие треки остаются неразделёнными.
# Поэтому битые входы отсеиваем сами (ffprobe читает только заголовок).
$ffprobe = @($env:SOUND_SEPARATE_FFPROBE, (Join-Path $root 'ffprobe.exe'), 'D:\Appz\ffprobe.exe') |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $ffprobe) {
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { $ffprobe = $cmd.Source }
}
if ($ffprobe) {
    $readable = @()
    foreach ($p in $resolved) {
        & $ffprobe -v error -show_entries format=duration -of csv=p=0 $p *> $null
        if ($LASTEXITCODE -eq 0) { $readable += $p }
        else {
            Write-Warning ("Пропускаю нечитаемый файл: {0}" -f $p)
            if ($subdirs.ContainsKey($p)) { $subdirs.Remove($p) }
        }
    }
    $resolved = @($readable)
    if (-not $resolved) { throw 'Ни один входной файл не читается — разделять нечего.' }
}

# Demucs/hq_separate складывают стемы в папку с именем файла без расширения,
# поэтому по этому имени определяем, в какую подпапку -Out переносить стемы.
$trackSubdirs = @{}
foreach ($p in $resolved) {
    $key = [IO.Path]::GetFileNameWithoutExtension($p)
    $rel = if ($subdirs.ContainsKey($p)) { [string]$subdirs[$p] } else { '' }
    if ($trackSubdirs.ContainsKey($key) -and ([string]$trackSubdirs[$key]) -ne $rel) {
        Write-Warning ("Одинаковые имена файлов в разных папках ({0}): demucs нумерует вывод по имени файла, результаты перезапишут друг друга." -f $key)
    } else {
        $trackSubdirs[$key] = $rel
    }
}

if ($HQ) {
    if ($TwoStems) { Write-Warning '-TwoStems игнорируется в режиме -HQ.' }
    $hqScript = Join-Path $root 'hq_separate.py'

    Write-Host 'Режим: HQ (htdemucs_ft + htdemucs_6s) -> vocals, drums, bass, guitar, piano, other' -ForegroundColor Cyan
    Write-Host ("Вывод:  {0}" -f $outDir) -ForegroundColor Cyan
    Write-Host ''

    $segment = $Segment
    $attempt = 0
    $code = 0
    while ($true) {
        $hqArgs = @($hqScript, '-o', $outDir)
        if ($Device) { $hqArgs += @('--device', $Device) }
        if ($segment -gt 0) { $hqArgs += @('--segment', $segment) }
        $hqArgs += @('--shifts', ($(if ($Shifts -gt 0) { $Shifts } else { 2 })))
        $hqArgs += @('--format', $Format)
        if ($Stems) { $hqArgs += @('--stems', ($Stems -join ',')) }
        if ($Extra) { $hqArgs += $Extra }
        $hqArgs += $resolved

        & $python @hqArgs
        $code = $LASTEXITCODE
        if ($code -ne 90) { break }
        $attempt++
        $next = if ($segment -gt 0) { [Math]::Max(2, [int][Math]::Floor($segment / 2)) } else { 4 }
        if ($attempt -ge 3 -or $next -eq $segment) {
            Write-Warning 'VRAM не хватило даже с минимальным сегментом — попробуй -Device cpu или закрой GPU-приложения.'
            break
        }
        $segment = $next
        Write-Warning ("Не хватило видеопамяти — повторяю с сегментом {0} c." -f $segment)
    }

    # Дообработка идёт и при ненулевом коде: в batch часть треков могла
    # разделиться нормально, и разложить их по местам нужно всё равно.
    # Сам факт ошибки не скрывается — предупреждение ниже и код возврата.
    Flatten-Stems -OutDir $outDir -ModelSub '' -Keep $Stems -Subdirs $trackSubdirs -OnlyTracks $trackSubdirs
    Mix-Stems -OutDir $outDir -Originals $resolved -Keep $Stems -Format $Format -Python $python -ProjectRoot $root -Subdirs $subdirs
    if ($code -ne 0) {
        Write-Warning ("hq_separate завершился с кодом {0} — часть треков не разделилась (см. сообщения выше)." -f $code)
    }
    exit $code
}

$model = if ($SixStems) { 'htdemucs_6s' } else { $Model }
$runDemucs = Join-Path $root 'run_demucs.py'

if ($Stems) {
    $unknown = @($Stems | Where-Object { $_ -in @('guitar', 'piano') })
    if ($unknown -and $model -notmatch '6s$') {
        Write-Warning ("Стемы guitar/piano доступны только в htdemucs_6s (или режиме -HQ): " + ($unknown -join ', '))
    }
}

Write-Host "Модель: $model" -ForegroundColor Cyan
Write-Host ("Файлов: {0}" -f $resolved.Count) -ForegroundColor Cyan
Write-Host ("Вывод:  {0}" -f $outDir) -ForegroundColor Cyan
Write-Host ''

$segment = $Segment
$attempt = 0
$code = 0
while ($true) {
    $demucsArgs = @('-n', $model, '-o', $outDir)
    if ($TwoStems) { $demucsArgs += @('--two-stems', $TwoStems) }
    if ($Device) { $demucsArgs += @('-d', $Device) }
    if ($segment -gt 0) { $demucsArgs += @('--segment', $segment) }
    if ($Shifts -gt 0) { $demucsArgs += @('--shifts', $Shifts) }
    # Лишние стемы не пишем на диск вовсе (demucs считает все источники
    # модели разом, но сохранять незапрошенные незачем). В -TwoStems demucs
    # и так сохраняет только выбранный стем и no_<stem>, поэтому фильтр не
    # нужен и не применяется.
    if ($Stems -and -not $TwoStems) {
        $demucsArgs += @('--keep-stems', ($Stems -join ','))
    }
    if ($Extra) { $demucsArgs += $Extra }
    $demucsArgs += $resolved

    & $python $runDemucs @demucsArgs
    $code = $LASTEXITCODE
    if ($code -ne 90) { break }
    $attempt++
    $next = if ($segment -gt 0) { [Math]::Max(2, [int][Math]::Floor($segment / 2)) } else { 4 }
    if ($attempt -ge 3 -or $next -eq $segment) {
        Write-Warning 'VRAM не хватило даже с минимальным сегментом — попробуй -Device cpu или закрой GPU-приложения.'
        break
    }
    $segment = $next
    Write-Warning ("Не хватило видеопамяти — повторяю с сегментом {0} c." -f $segment)
}

# Дообработка не привязана к коду возврата demucs: в batch один битый файл
# завершает процесс с ненулевым кодом, хотя остальные треки разделились
# нормально. Если её пропустить, в <Out> останется сырая папка модели
# (htdemucs/<трек>/drums.wav) без переименования и без миксов.
$modelDir = Join-Path $outDir $model
if (Test-Path -LiteralPath $modelDir) {
    if ($Format -eq 'mp3') {
        # Demucs пишет WAV: конвертируем в mp3 через ffmpeg, чтобы файл был gapless
        # (lameenc оставляет задержку кодировщика ~1105 сэмплов -> стем отстаёт от оригинала).
        $wav2mp3 = Join-Path $root 'wav2mp3.py'
        & $python $wav2mp3 -Dir $modelDir
        if ($LASTEXITCODE -ne 0) {
            # Не throw: иначе уже готовые WAV-стемы остаются в папке модели
            # без переименования и без миксов. Раскладываем что есть.
            Write-Warning 'Не удалось сконвертировать часть WAV-стемов в mp3 — они останутся в WAV.'
        }
    }
    Flatten-Stems -OutDir $outDir -ModelSub $model -Keep $Stems -Subdirs $trackSubdirs -OnlyTracks $trackSubdirs
    Mix-Stems -OutDir $outDir -Originals $resolved -Keep $Stems -Format $Format -Python $python -ProjectRoot $root -Subdirs $subdirs
}

if ($code -ne 0) {
    Write-Host ''
    Write-Host ("!! demucs завершился с кодом {0} — часть треков не разделилась (см. сообщения выше)." -f $code) -ForegroundColor Red
    Write-Host (("   Успешно разделённые треки разложены в {0}; код возврата скрипта = {1}." -f $outDir, $code)) -ForegroundColor Red
}

exit $code
