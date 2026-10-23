"""Полосы прогресса: ширина по окну консоли, чистые числа, прогресс ffmpeg.

Зачем: demucs рисует полосу фиксированной шириной 120 символов (demucs/apply.py),
а hq_separate.py и mix_stem.py — 80. Если полоса шире окна, терминал переносит
её на вторую строку; при обновлении ('\\r') курсор возвращается не в начало
полосы, а в начало следующей строки — полоса «прыгает» и оставляет мусор.

Здесь ширина всегда на 1 символ меньше ширины окна и пересчитывается на
каждое обновление (т.е. после ресайза окна тоже).

Плюс: demucs декодирует вход через ffmpeg с -loglevel panic — во время
декодирования (особенно для видео) консоль молчит. Тут ffmpeg запускается с
-progress pipe:1 и по out_time рисуется полоса.
"""
import os
import shutil
import sys

MIN_WIDTH = 20


def _windows_window_width() -> int:
    """Видимая ширина окна консоли Windows (буфер может быть шире окна)."""
    try:
        import ctypes
        from ctypes import wintypes

        class _COORD(ctypes.Structure):
            _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]

        class _SMALL_RECT(ctypes.Structure):
            _fields_ = [("Left", ctypes.c_short), ("Top", ctypes.c_short),
                        ("Right", ctypes.c_short), ("Bottom", ctypes.c_short)]

        class _CONSOLE_SCREEN_BUFFER_INFO(ctypes.Structure):
            _fields_ = [("dwSize", _COORD), ("dwCursorPosition", _COORD),
                        ("wAttributes", wintypes.WORD), ("srWindow", _SMALL_RECT),
                        ("dwMaximumWindowSize", _COORD)]

        kernel32 = ctypes.windll.kernel32
        for handle_id in (-11, -10, -12):  # stderr, stdout, stdin
            handle = kernel32.GetStdHandle(handle_id)
            if not handle or handle == ctypes.c_void_p(-1).value:
                continue
            info = _CONSOLE_SCREEN_BUFFER_INFO()
            if kernel32.GetConsoleScreenBufferInfo(handle, ctypes.byref(info)):
                width = info.srWindow.Right - info.srWindow.Left + 1
                if width > 0:
                    return width
    except Exception:
        return 0
    return 0


def _detected_width(default: int = 80) -> int:
    env_cols = os.environ.get("COLUMNS")
    if env_cols and env_cols.isdigit():
        return int(env_cols)
    if os.name == "nt":
        width = _windows_window_width()
        if width:
            return width
    try:
        return shutil.get_terminal_size((default, 24)).columns
    except Exception:
        return default


def console_width(default: int = 80) -> int:
    """Ширина окна консоли в символах минус 1 (чтобы строка не переносилась)."""
    cols = _detected_width(default)
    if not cols or cols <= 0:
        cols = default
    return max(MIN_WIDTH, cols - 1)


def bar_width(preferred: int = 80) -> int:
    """Ширина полосы: не больше окна и не больше желаемой."""
    return max(MIN_WIDTH, min(preferred, console_width()))


def _clamp(bar) -> None:
    """Ограничить ширину полосы шириной окна.

    В tqdm 4.70 при disable=True (вывод не в TTY) __init__ делает ранний
    return и НЕ создаёт атрибут ncols — поэтому проверяем hasattr, а не
    обращаемся напрямую.
    """
    width = console_width()
    ncols = getattr(bar, "ncols", None)
    if ncols is None or ncols > width:
        try:
            bar.ncols = width
        except Exception:
            pass


class _Fixed2(float):
    """float, который печатается всегда с двумя знаками после запятой.

    ``width`` — минимальная ширина строки: число дополняется пробелами справа
    по левому краю, чтобы длина строки не менялась от кадра к кадру
    (иначе полоса сдвигается на символ).
    """

    def __new__(cls, value, width=0):
        obj = super().__new__(cls, value)
        obj._width = width
        return obj

    def __str__(self) -> str:
        text = f"{float(self):.2f}"
        return text.rjust(self._width) if self._width else text


def _clean_number(value, decimals: int = 2, width: int = 0):
    """Убрать шум float (25.9999999 -> 26.00) и зафиксировать ширину строки."""
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    try:
        number = float(value)
    except (TypeError, ValueError):
        return value
    if number != number or number in (float("inf"), float("-inf")):
        return value
    return _Fixed2(round(number, decimals), width=width)


def _install_format_meter_patch(tqdm) -> None:
    """Чистые числа в полосе tqdm.

    demucs рисует прогресс в секундах аудио: unit_scale = 5.85, поэтому
    tqdm умножает счётчик на 5.85 и печатает результат как str(n) ->
    40.949999999999996 вместо 40.95. Разная длина числа каждый раз сдвигает
    правую часть полосы -> полоса «прыгает». Здесь масштаб применяется заранее,
    а результат округляется и печатается фиксированной шириной.
    """
    original = tqdm.tqdm.format_meter
    if getattr(original, "_sound_separate_clean", False):
        return

    def format_meter(n, total, elapsed, ncols=None, prefix='', ascii=False, unit='it',
                     unit_scale=False, rate=None, bar_format=None, postfix=None,
                     unit_divisor=1000, initial=0, colour=None, **extra_kwargs):
        if unit_scale and unit_scale not in (True, 1):
            if total:
                total = _clean_number(total * unit_scale)
            if rate:
                rate = _clean_number(rate * unit_scale)
            n = _clean_number(n * unit_scale)
            unit_scale = False
        else:
            n = _clean_number(n)
            total = _clean_number(total)
        width = len(str(total)) if total is not None else 0
        if width and isinstance(n, _Fixed2):
            n = _Fixed2(float(n), width=width)
        return original(n, total, elapsed, ncols=ncols, prefix=prefix, ascii=ascii,
                        unit=unit, unit_scale=unit_scale, rate=rate,
                        bar_format=bar_format, postfix=postfix,
                        unit_divisor=unit_divisor, initial=initial, colour=colour,
                        **extra_kwargs)

    format_meter._sound_separate_clean = True
    tqdm.tqdm.format_meter = staticmethod(format_meter)


def apply_tqdm_patch() -> None:
    """Заставляет все полосы tqdm помещаться в окно консоли и не «прыгать»."""
    import tqdm

    if getattr(tqdm.tqdm, "_sound_separate_patched", False):
        return

    orig_init = tqdm.tqdm.__init__
    orig_display = tqdm.tqdm.display

    def init(self, *args, **kwargs):
        orig_init(self, *args, **kwargs)
        _clamp(self)

    def display(self, *args, **kwargs):
        _clamp(self)
        return orig_display(self, *args, **kwargs)

    tqdm.tqdm.__init__ = init
    tqdm.tqdm.display = display
    tqdm.tqdm._sound_separate_patched = True
    _install_format_meter_patch(tqdm)


def is_oom(exc: BaseException) -> bool:
    """Похоже ли исключение на нехватку видеопамяти."""
    text = f"{type(exc).__name__}: {exc}".lower()
    if "out of memory" in text:
        return True
    if "cuda" in text and ("memory" in text or "alloc" in text):
        return True
    return type(exc).__name__ == "OutOfMemoryError"


# --- тишина вокруг Hugging Face ----------------------------------------

#: Темы предупреждений HF, которые не стоит показывать.
#: "unauthenticated" прилетает заголовком X-HF-Warning на КАЖДЫЙ запрос
#: (даже на модель, которая уже лежит в кэше) и не значит ничего плохого:
#: токен нужен только для закрытых/приватных репозиториев.
_HF_IGNORED_WARNING_TOPICS = ("unauthenticated",)


def _hf_warning_is_noise(topic: str) -> bool:
    topic = (topic or "").strip().lower()
    return any(topic.startswith(ignored) for ignored in _HF_IGNORED_WARNING_TOPICS)


def _install_post_import_hook(module_name: str, callback, flag: str) -> None:
    """Вызвать callback сразу после импорта module_name.

    Нужен для модулей, которые грузятся лениво (huggingface_hub) или
    тяжело (demucs): хук вешается на sys.meta_path и не тянет их импорт
    при старте python.
    """
    if getattr(sys, flag, False):
        return
    setattr(sys, flag, True)

    class _Finder:
        def find_spec(self, fullname, path=None, target=None):
            if fullname != module_name:
                return None
            spec = None
            for finder in list(sys.meta_path):
                if finder is self:
                    continue
                find = getattr(finder, "find_spec", None)
                if find is None:
                    continue
                spec = find(fullname, path, target)
                if spec is not None:
                    break
            if spec is None or spec.loader is None:
                return None
            loader = spec.loader
            original_exec = loader.exec_module

            def exec_module(module, _original=original_exec):
                _original(module)
                try:
                    callback(module)
                except Exception:
                    pass

            loader.exec_module = exec_module
            return spec

        def invalidate_caches(self):
            pass

    sys.meta_path.insert(0, _Finder())


def silence_hf_warnings(module=None) -> None:
    """Убрать предупреждение HF «unauthenticated requests».

    huggingface_hub печатает его через logger.warning() из
    utils/_http.py::_warn_on_warning_headers — по заголовку X-HF-Warning,
    который сервер шлёт на каждый запрос без токена. Для локального
    разделения это шум: модели в кэше, токен не нужен.

    Остальные темы предупреждений (gated repo, deprecated и т.п.) остаются
    видимыми — глушим только «unauthenticated».
    """
    try:
        from huggingface_hub.utils import _http as hf_http
    except Exception:
        return

    if getattr(hf_http, "_sound_separate_silenced", False):
        return

    original = hf_http._warn_on_warning_headers
    warned_topics = hf_http._WARNED_TOPICS

    def patched(response):
        try:
            warnings = response.headers.get_list("X-HF-Warning")
        except Exception:
            return original(response)

        for raw in warnings:
            topic, _, _message = raw.partition(";")
            if _hf_warning_is_noise(topic):
                # Помечаем тему как «уже показанную», чтобы оригинал её пропустил.
                warned_topics.add(topic.strip())

    hf_http._warn_on_warning_headers = patched
    hf_http._sound_separate_silenced = True


def prefer_cached_models(module=None) -> None:
    """Сначала искать модель в локальном кэше HF, сеть — только если её нет.

    demucs грузит модель через huggingface_hub.hf_hub_download, который
    всегда делает HEAD-запрос на huggingface.co, даже если файл уже лежит
    в кэше. Из-за этого (а) тратится время на сеть, (б) прилетает
    предупреждение «unauthenticated requests».

    Оборачиваем hf_hub_download: пробуем local_files_only=True, и только
    при LocalEntryNotFoundError идём в сеть как раньше.
    """
    try:
        import huggingface_hub
    except Exception:
        return

    if getattr(huggingface_hub, "_sound_separate_cache_first", False):
        return

    try:
        from huggingface_hub.errors import LocalEntryNotFoundError
    except Exception:
        LocalEntryNotFoundError = OSError  # noqa: N806 - запасной вариант

    original = huggingface_hub.hf_hub_download

    def wrapper(*args, **kwargs):
        if kwargs.get("local_files_only") or kwargs.get("force_download"):
            return original(*args, **kwargs)
        try:
            return original(*args, **kwargs, local_files_only=True)
        except LocalEntryNotFoundError:
            return original(*args, **kwargs)

    huggingface_hub.hf_hub_download = wrapper
    huggingface_hub._sound_separate_cache_first = True


def silence_hf_noise(module=None) -> None:
    """Точка входа: убрать весь шум Hugging Face."""
    silence_hf_warnings()
    prefer_cached_models()


def install_hf_silence_hook() -> None:
    """Подключить silence_hf_noise после импорта huggingface_hub."""
    _install_post_import_hook(
        "huggingface_hub", silence_hf_noise, "_sound_separate_hf_hook"
    )


def silence_demucs_bag_notice(module=None) -> None:
    """Убрать вводящее в заблуждение «bag of 1 models».

    demucs печатает это для ЛЮБОГО BagOfModels (demucs/separate.py:146),
    даже когда в мешке ровно одна сеть — а значит будет ровно одна
    полоса прогресса, а не «столько-то полос». Для htdemucs/htdemucs_6s
    это всегда 1 модель; для htdemucs_ft — 4, и там сообщение полезно,
    поэтому глушим только случай «1 модель».

    print подменяется не в builtins, а в глобалах demucs.separate: Python
    ищет имя print сначала в __dict__ модуля, и только потом в builtins,
    так что подмена действует на demucs и ни на кого больше.
    """
    try:
        import re

        import demucs.separate as demucs_separate
    except Exception:
        return

    if getattr(demucs_separate, "_sound_separate_bag_silenced", False):
        return

    original_print = demucs_separate.__dict__.get("print", print)
    pattern = re.compile(r"^Selected model is a bag of (\d+) models\.")

    def patched_print(*args, **kwargs):
        try:
            if args and isinstance(args[0], str):
                match = pattern.match(args[0])
                if match and int(match.group(1)) <= 1:
                    return
        except Exception:
            pass
        return original_print(*args, **kwargs)

    demucs_separate.print = patched_print
    demucs_separate._sound_separate_bag_silenced = True


def install_demucs_bag_hook() -> None:
    """Подключить silence_demucs_bag_notice после импорта demucs.separate."""
    _install_post_import_hook(
        "demucs.separate", silence_demucs_bag_notice, "_sound_separate_bag_hook"
    )


def restrict_demucs_output(keep_stems) -> None:
    """Не сохранять на диск стемы, которые пользователь не просил.

    demucs за один проход считает ВСЕ источники модели (vocals, drums, bass,
    other) и сохраняет их все — отдельного режима «считай только drums» у
    него нет. Раньше лишние файлы удалялись постфактум (Flatten-Stems), но
    к тому моменту уже потрачено время на их кодирование в mp3 и на микс.

    Здесь перехватывается save_audio в demucs.separate: файлы не нужных
    стемов просто не пишутся. Само разделение при этом не меняется —
    модель всё равно считает все каналы, но не тратит время и место на
    их сохранение и последующую обработку.

    Имя стема берётся из имени файла: demucs сохраняет источники как
    {track}/{stem}.{ext}, поэтому basename без расширения — это и есть
    имя стема.
    """
    keep = {str(s).strip().lower() for s in (keep_stems or []) if str(s).strip()}
    if not keep:
        return

    try:
        from pathlib import Path

        import demucs.separate as demucs_separate
    except Exception:
        return

    if getattr(demucs_separate, "_sound_separate_output_restricted", False):
        return

    original = demucs_separate.save_audio

    def patched(source, path, *args, **kwargs):
        try:
            name = Path(path).stem.lower()
        except Exception:
            name = ""
        if name and name not in keep:
            return None
        return original(source, path, *args, **kwargs)

    demucs_separate.save_audio = patched
    demucs_separate._sound_separate_output_restricted = True


# --- прогресс для ffmpeg -------------------------------------------------

def _option_value(command, name):
    """Значение опции ffmpeg (например '-i' -> путь файла)."""
    for index, item in enumerate(command):
        if item == name and index + 1 < len(command):
            return command[index + 1]
    return None


def _probe_duration(path: str):
    """Длительность аудиодорожки (или файла) в секундах, либо None."""
    probe = shutil.which("ffprobe")
    if not probe or not os.path.isfile(path):
        return None
    import subprocess

    def _query(args):
        try:
            result = subprocess.run(
                [probe, "-v", "error"] + args + [
                    "-of", "default=nw=1:nk=1", path],
                capture_output=True, text=True, timeout=60,
            )
            return result.stdout.strip()
        except Exception:
            return ""

    value = _query(["-select_streams", "a:0", "-show_entries", "stream=duration"])
    if not value:
        value = _query(["-show_entries", "format=duration"])
    try:
        return float(value) if value else None
    except ValueError:
        return None


def _pcm_seconds(command, byte_count: int):
    """Длительность raw PCM по размеру данных и параметрам команды."""
    samplerate = _option_value(command, "-ar")
    channels = _option_value(command, "-ac")
    fmt = _option_value(command, "-f") or ""
    if not samplerate or not channels:
        return None
    bytes_per_sample = {"s16le": 2, "s16": 2, "u8": 1, "s32le": 4, "f32le": 4}.get(fmt, 2)
    try:
        return byte_count / (float(samplerate) * float(channels) * bytes_per_sample)
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def _run_ffmpeg_with_progress(command, kwargs):
    """Запустить ffmpeg с -progress pipe:1 и полосой прогресса."""
    import subprocess

    import tqdm as tqdm_module

    cmd = list(command)
    cmd[1:1] = ["-progress", "pipe:1", "-nostats", "-stats_period", "0.2"]

    pcm = kwargs.get("input")
    total = None
    if isinstance(pcm, (bytes, bytearray)):
        total = _pcm_seconds(cmd, len(pcm))
    if total is None:
        limit = _option_value(cmd, "-t")
        if limit:
            try:
                total = float(limit)
            except ValueError:
                total = None
    if total is None:
        source = _option_value(cmd, "-i")
        if source and not source.startswith("-"):
            total = _probe_duration(source)

    stdin_data = pcm if isinstance(pcm, (bytes, bytearray)) else None
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
    )
    try:
        if stdin_data is not None:
            proc.stdin.write(stdin_data)
            proc.stdin.close()
        bar = tqdm_module.tqdm(total=total, unit="seconds",
                               desc=kwargs.get("desc") or "ffmpeg",
                               leave=False)
        last = 0.0
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if line.startswith("out_time_us="):
                try:
                    seconds = int(line.split("=", 1)[1]) / 1_000_000
                except ValueError:
                    continue
            elif line.startswith("out_time_ms="):
                try:
                    seconds = int(line.split("=", 1)[1]) / 1_000
                except ValueError:
                    continue
            elif line == "progress=end":
                break
            else:
                continue
            if seconds > last:
                bar.update(seconds - last)
                last = seconds
        bar.close()
    finally:
        proc.stdout.close()
    returncode = proc.wait()
    if kwargs.get("check") and returncode != 0:
        raise subprocess.CalledProcessError(returncode, cmd)
    return subprocess.CompletedProcess(cmd, returncode)


def run_ffmpeg(command, input_bytes=None, check=True, desc="ffmpeg"):
    """Запустить ffmpeg с полосой прогресса (публичная обёртка)."""
    kwargs = {"check": check, "desc": desc}
    if input_bytes is not None:
        kwargs["input"] = input_bytes
    return _run_ffmpeg_with_progress(list(command), kwargs)


def patch_demucs_ffmpeg() -> None:
    """Научить demucs показывать прогресс при декодировании через ffmpeg."""
    try:
        import demucs.audio as demucs_audio
    except Exception:
        return
    if getattr(demucs_audio, "_sound_separate_ffmpeg_patched", False):
        return

    original_run = demucs_audio.sp.run

    def run(command, *args, **kwargs):
        if (isinstance(command, (list, tuple)) and command
                and str(command[0]).lower().split("\\")[-1].startswith("ffmpeg")
                and "-progress" not in command):
            return _run_ffmpeg_with_progress(list(command), kwargs)
        return original_run(command, *args, **kwargs)

    demucs_audio.sp.run = run
    demucs_audio._sound_separate_ffmpeg_patched = True


def install_demucs_ffmpeg_hook() -> None:
    """Патчить demucs.audio сразу после его импорта (без тяжёлого импорта torch)."""
    import sys

    if getattr(sys, "_sound_separate_ffmpeg_hook", False):
        return
    sys._sound_separate_ffmpeg_hook = True

    try:
        import progress
    except Exception:
        return

    class _Finder:
        def find_spec(self, fullname, path=None, target=None):
            if fullname != "demucs.audio":
                return None
            spec = None
            for finder in list(sys.meta_path):
                if finder is self:
                    continue
                find = getattr(finder, "find_spec", None)
                if find is None:
                    continue
                spec = find(fullname, path, target)
                if spec is not None:
                    break
            if spec is None or spec.loader is None:
                return None
            loader = spec.loader
            original_exec = loader.exec_module

            def exec_module(module, _original=original_exec):
                _original(module)
                try:
                    progress.patch_demucs_ffmpeg()
                except Exception:
                    pass

            loader.exec_module = exec_module
            return spec

        def invalidate_caches(self):
            pass

    sys.meta_path.insert(0, _Finder())
