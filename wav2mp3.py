#!/usr/bin/env python
"""Convert Demucs WAV stems to mp3 via ffmpeg/libmp3lame.

Demucs writes its stems with lameenc, which does not store the LAME gapless
("Info") tag. Decoders then keep the encoder delay, and the stem ends up
~1105 samples (25 ms) later than the original track. Encoding the WAV stems
with ffmpeg/libmp3lame produces a file that decodes sample-aligned.
"""
import argparse
import shutil
import sys
from pathlib import Path

import progress

progress.apply_tqdm_patch()


def convert(wav: Path, mp3: Path, bitrate: int = 320) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required to write mp3 stems.")
    command = [
        ffmpeg, "-y", "-v", "error",
        "-i", str(wav),
        "-c:a", "libmp3lame", "-b:a", f"{bitrate}k",
        str(mp3),
    ]
    progress.run_ffmpeg(command, check=True, desc=f"mp3 {wav.stem}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Convert WAV stems to mp3 (gapless).")
    ap.add_argument("-Dir", dest="dir", required=True, help="Directory with WAV stems")
    ap.add_argument("-Bitrate", dest="bitrate", type=int, default=320)
    ap.add_argument("-KeepWav", action="store_true", help="Keep the WAV files")
    args = ap.parse_args()

    root = Path(args.dir)
    if not root.is_dir():
        print(f"not found: {root}", file=sys.stderr)
        return 1

    wavs = sorted(root.rglob("*.wav"))
    if not wavs:
        print(f"no wav stems in {root}")
        return 0

    for wav in wavs:
        mp3 = wav.with_suffix(".mp3")
        convert(wav, mp3, args.bitrate)
        if not args.KeepWav:
            try:
                wav.unlink()
            except OSError:
                pass
        print(f"  {wav.name} -> {mp3.name}")
    print(f"converted {len(wavs)} wav stem(s) in {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
