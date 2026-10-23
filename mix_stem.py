#!/usr/bin/env python
"""Mix a stem with the original track into a single output file.

Reads the original audio and a stem file, aligns the stem to the original,
sums them sample-for-sample, and writes the result as mp3 or wav. Used to
produce <track>_<stem>.<fmt>: the stem is mixed in twice as loud as the
original (2:1, --stem-gain 2), so the isolated instrument stands out against
the record. The 1:1 variant was dropped - it sounded like the original and
just doubled the number of files.

Alignment matters: demucs' reader (sphn/libsndfile) keeps the LAME encoder
delay of a compressed (mp3) source, so every stem comes out ~1105 samples at
44.1 kHz (25 ms) later than the original and 1296 samples longer; a wav source
has no offset. This holds for wav stems too, so alignment can't be skipped for
wav output. Without correction the instrument lands 25 ms after the original,
which sounds like a flam instead of a single instrument in the mix.

The original is not always something libsndfile can read: downloads are often
m4a/aac/wma or video. Those are decoded through ffmpeg first (the same fallback
demucs itself uses), so the original and the stems come from the same sample
grid; the decode is cached per track when --decode-cache is given, because one
track is mixed once per stem.
"""
import argparse
import hashlib
import os
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
import torchaudio
import torch.nn.functional as F
from tqdm import tqdm

import progress
from demucs.audio import prevent_clip
from hq_separate import _encode_mp3, _encode_wav

progress.apply_tqdm_patch()

# +/- 46 ms: хватает для задержки LAME (1105 сэмплов @ 44.1 кГц),
# но не настолько много, чтобы поймать "периодичные" ложные пики (ритм-секция).
MAX_LAG = 2048
MIN_STRENGTH = 0.02  # минимальная корреляция, чтобы верить найденному сдвигу
MIN_MARGIN = 0.01  # насколько ненулевой лаг должен быть лучше нулевого


# Расширения, которые libsndfile (бэкенд torchaudio) читает сам. Всё остальное
# (m4a/aac/wma/mp4/mkv/...) декодируется через ffmpeg: libsndfile контейнеры
# не понимает, а вход часто именно такой.
SNDFILE_EXTENSIONS = {
    ".wav", ".wave", ".rf64", ".w64", ".flac", ".mp3", ".ogg", ".oga", ".opus",
    ".aif", ".aiff", ".aifc", ".caf", ".au", ".snd",
}


def _decode_ffmpeg(path: Path, cache_dir: Path | None = None) -> Path:
    """Декодирует вход в WAV (f32) через ffmpeg и возвращает путь к нему.

    demucs для нечитаемых libsndfile контейнеров делает то же самое, поэтому
    оригинал и стемы оказываются на одной сэмпловой сетке, и выравниванию в
    align_stem остаётся только задержка кодека.
    """
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError(
            f"libsndfile cannot read {path.name} and ffmpeg is not in PATH")
    temporary = False
    if cache_dir is not None:
        # Декодирование длится примерно столько же, сколько сам трек, а миксов
        # на трек столько же, сколько стемов: без кэша исходник декодировался
        # бы на каждый стем заново.
        stat = path.stat()
        key = hashlib.sha1(
            f"{path.resolve()}|{stat.st_size}|{stat.st_mtime_ns}".encode("utf-8")
        ).hexdigest()[:16]
        cache_dir.mkdir(parents=True, exist_ok=True)
        tmp = cache_dir / f"decode-{key}.wav"
        if tmp.is_file():
            return tmp
    else:
        handle, name = tempfile.mkstemp(prefix="sound-separate-decode-", suffix=".wav")
        os.close(handle)
        tmp = Path(name)
        temporary = True
    try:
        progress.run_ffmpeg(
            [ffmpeg, "-y", "-v", "error", "-i", str(path), "-vn",
             "-c:a", "pcm_f32le", str(tmp)],
            desc=f"decode {path.stem}")
    except Exception:
        if temporary:
            tmp.unlink(missing_ok=True)
        raise
    return tmp


def _load(path: Path, cache_dir: Path | None = None):
    if path.suffix.lower() in SNDFILE_EXTENSIONS:
        return torchaudio.load(str(path))
    tmp = _decode_ffmpeg(path, cache_dir)
    try:
        return torchaudio.load(str(tmp))
    finally:
        if cache_dir is None:
            tmp.unlink(missing_ok=True)


def _mono(x: torch.Tensor) -> np.ndarray:
    return x.detach().cpu().numpy().mean(axis=0).astype(np.float64)


def _correlate(x: np.ndarray, y: np.ndarray, shift: int) -> float:
    """Нормированная корреляция x и y при сдвиге shift (сэмплы).

    Положительный shift = x (сдвигаемый сигнал) звучит позже y.
    x и y могут быть разной длины (стем длиннее оригинала на задержку кодека) —
    сравнивается общий кусок.
    """
    if shift >= 0:
        a, b = x[shift:], y[:max(len(x) - shift, 0)]
    else:
        a, b = x[:max(len(y) + shift, 0)], y[-shift:]
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    if n < 1024:
        return -2.0
    denom = np.sqrt(float((a * a).sum()) * float((b * b).sum()))
    if denom <= 0:
        return -2.0
    return float((a * b).sum()) / denom


def _estimate_delay(orig: np.ndarray, stem: np.ndarray, max_lag: int = MAX_LAG):
    """Сдвиг стема относительно оригинала (в сэмплах) и сила корреляции.

    Положительный сдвиг = стем звучит позже оригинала (его надо подрезать).
    """
    n = min(len(orig), len(stem))
    if n < 8 * max_lag:
        return 0, 0.0
    x = stem[:n]
    y = orig[:n]

    dec = 8  # прореживание для грубой оценки
    kernel = np.ones(dec) / dec
    xs = np.convolve(x, kernel, mode="same")[::dec]
    ys = np.convolve(y, kernel, mode="same")[::dec]
    size = 1 << int(np.ceil(np.log2(len(xs) + len(ys))))
    fx = np.fft.rfft(xs - xs.mean(), size)
    fy = np.fft.rfft(ys - ys.mean(), size)
    corr = np.fft.irfft(fx * np.conj(fy), size)
    corr = np.concatenate((corr[-(len(ys) - 1):], corr[:len(xs)]))
    lags = np.arange(-(len(ys) - 1), len(xs)) * dec
    idx = np.nonzero(np.abs(lags) <= max_lag)[0]
    if idx.size == 0:
        return 0, 0.0
    coarse = int(lags[idx[int(np.argmax(corr[idx]))]])

    best_lag, best_val = coarse, -2.0
    for shift in range(coarse - dec, coarse + dec + 1):
        value = _correlate(x, y, shift)
        if value > best_val:
            best_lag, best_val = shift, value
    return best_lag, best_val


def align_stem(orig: torch.Tensor, stem: torch.Tensor, samplerate: int):
    """Сдвинуть стем так, чтобы он совпал с оригиналом по времени."""
    orig_mono, stem_mono = _mono(orig), _mono(stem)
    delay, strength = _estimate_delay(orig_mono, stem_mono)
    if strength < MIN_STRENGTH:
        print(f"align: shift not detected (corr {strength:.3f}) - mixing as is")
        return stem, 0
    if delay == 0:
        # Задержки нет — стем уже совпадает с оригиналом (так бывает, когда
        # demucs читал вход через ffmpeg, как и этот скрипт).
        print(f"align: stem already aligned (corr {strength:.3f})")
        return stem, 0
    # Слабый стем (вокал, остаток) даёт почти плоскую корреляцию, и поиск
    # промахивается на несколько сэмплов вокруг нуля. Слышно там не будет
    # ничего (0.1 мс), но сдвиг ни на чём не основан, поэтому берём его,
    # только если ненулевой лаг заметно лучше нулевого.
    at_zero = _correlate(stem_mono, orig_mono, 0)
    if strength <= at_zero + MIN_MARGIN:
        print(f"align: shift {delay} ignored (corr {strength:.3f} vs {at_zero:.3f} at 0)")
        return stem, 0
    if delay > 0:
        stem = stem[..., delay:]
    else:
        stem = F.pad(stem, (-delay, 0))
    print(f"align: stem shifted by {delay} samples ({delay * 1000.0 / samplerate:.1f} ms), "
          f"corr {strength:.3f}")
    return stem, delay


def mix(original: Path, stem: Path, out: Path, fmt: str, stem_gain: float = 1.0,
        decode_cache: Path | None = None) -> None:
    orig, sr = _load(original, decode_cache)
    st, stem_sr = _load(stem)

    if stem_sr != sr:
        st = torchaudio.functional.resample(st, stem_sr, sr)

    if orig.shape[0] != st.shape[0]:
        if orig.shape[0] == 1:
            orig = orig.repeat(st.shape[0], 1)
        elif st.shape[0] == 1:
            st = st.repeat(orig.shape[0], 1)

    st, _ = align_stem(orig, st, sr)

    n = min(orig.shape[-1], st.shape[-1])
    orig = orig[..., :n]
    st = st[..., :n]

    with tqdm(total=n, unit="fr", desc=f"Mix {out.stem}", leave=False) as bar:
        chunk = 1024 * 256
        mixed_parts = []
        for i in range(0, n, chunk):
            end = min(i + chunk, n)
            mixed_parts.append(orig[..., i:end] + stem_gain * st[..., i:end])
            bar.update(end - i)
        mixed = torch.cat(mixed_parts, dim=-1)

    out.parent.mkdir(parents=True, exist_ok=True)
    mixed = prevent_clip(mixed, "rescale")
    if fmt == "mp3":
        _encode_mp3(mixed, out, sr, desc=f"Encode {out.stem}")
    else:
        _encode_wav(mixed, out, sr, 24, False, desc=f"Encode {out.stem}")


def main():
    ap = argparse.ArgumentParser(description="Mix original + stem into one file.")
    ap.add_argument("--original", required=True)
    ap.add_argument("--stem", required=True, dest="stem_file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--format", dest="fmt", default="mp3", choices=["mp3", "wav"])
    ap.add_argument("--stem-gain", type=float, default=1.0,
                    help="Weight of the stem in the sum (1.0 = 1:1, 2.0 = 2:1).")
    ap.add_argument("--decode-cache", dest="decode_cache", default=None,
                    help="Dir to keep the ffmpeg-decoded original in: one track is "
                         "mixed once per stem, and decoding m4a/video takes as long "
                         "as the track. Without it the decode goes to a temp file "
                         "that is removed right after reading.")
    args = ap.parse_args()

    original = Path(args.original)
    stem_file = Path(args.stem_file)
    if not original.is_file():
        print(f"skip (original not found): {original}", file=sys.stderr)
        return 1
    if not stem_file.is_file():
        print(f"skip (stem not found): {stem_file}", file=sys.stderr)
        return 1

    mix(original, stem_file, Path(args.out), args.fmt, args.stem_gain,
        Path(args.decode_cache) if args.decode_cache else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
