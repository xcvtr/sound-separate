#!/usr/bin/env python
"""Запуск demucs из CLI: нормальная ширина полосы прогресса + понятная диагностика.

Зачем не `python -m demucs`:
  * demucs рисует полосу шириной 120 символов -> в окне уже 80 колонок строка
    переносится и полоса «прыгает» (лечится progress.apply_tqdm_patch);
  * при нехватке VRAM (GTX 1060 3GB, а рабочий стол занимает ~1.6 ГБ) падает
    голый traceback. Здесь исключение ловится, печатается короткая причина и
    возвращается код 90, чтобы обёртка (separate.ps1) повторила запуск с
    меньшим сегментом;
  * лишние стемы не пишутся на диск: demucs считает все источники модели
    разом и сохраняет их все, а нужно часто только один (--keep-stems).
"""
import sys
import traceback

import progress

EXIT_OOM = 90


def _diagnose(exc: BaseException) -> int:
    if progress.is_oom(exc):
        print(
            "\n[demucs] Not enough VRAM (CUDA out of memory). "
            "Retry with a smaller segment (--segment 4) or close GPU apps.",
            file=sys.stderr,
        )
        return EXIT_OOM
    print(f"\n[demucs] Failed: {type(exc).__name__}: {exc}", file=sys.stderr)
    return 1


def _split_keep_stems(argv):
    """Вытащить --keep-stems из аргументов demucs (до вызова demucs_main).

    Флаг не demucs'овский, а наш: он говорит, какие стемы сохранять.
    """
    keep = []
    rest = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--keep-stems":
            if i + 1 < len(argv):
                keep.append(argv[i + 1])
            i += 2
            continue
        if arg.startswith("--keep-stems="):
            keep.append(arg.split("=", 1)[1])
            i += 1
            continue
        rest.append(arg)
        i += 1
    stems = []
    for chunk in keep:
        stems.extend(part.strip() for part in chunk.split(",") if part.strip())
    return stems, rest


def main() -> int:
    progress.apply_tqdm_patch()
    progress.install_demucs_ffmpeg_hook()
    progress.install_hf_silence_hook()
    progress.install_demucs_bag_hook()

    from demucs.separate import main as demucs_main

    stems, args = _split_keep_stems(sys.argv[1:])
    if stems:
        # Ограничить список сохраняемых стемов: лишние не пишутся вовсе.
        progress.restrict_demucs_output(stems)

    sys.argv[0] = "demucs"
    try:
        demucs_main(args)
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 - нужен код возврата для ретрая
        traceback.print_exc()
        return _diagnose(exc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
