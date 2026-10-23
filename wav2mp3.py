#!/usr/bin/env python
"""Convert Demucs WAV stems to mp3 via ffmpeg/libmp3lame.

ffmpeg/libmp3lame writes the LAME gapless ("Info") tag, so decoders strip the
encoder delay and the mp3 stays sample-aligned with the source. lameenc (the
fallback in hq_separate) is avoided here for that reason.
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
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("-Dir", dest="dir", help="Directory with WAV stems (recursive).")
    source.add_argument("-Files", dest="files", nargs="+",
                        help="Explicit WAV file(s) to convert (used by separate.ps1, "
                             "which keeps the list of stems it just wrote).")
    ap.add_argument("-Bitrate", dest="bitrate", type=int, default=320)
    ap.add_argument("-KeepWav", action="store_true", help="Keep the WAV files")
    args = ap.parse_args()

    if args.files:
        wavs = [Path(p) for p in args.files]
        where = f"{len(wavs)} file(s) given"
    else:
        root = Path(args.dir)
        if not root.is_dir():
            print(f"not found: {root}", file=sys.stderr)
            return 1
        wavs = sorted(root.rglob("*.wav"))
        where = f"in {root}"

    if not wavs:
        print(f"no wav stems {where}")
        return 0

    missing = 0
    for wav in wavs:
        if not wav.is_file():
            print(f"  not found: {wav}", file=sys.stderr)
            missing += 1
            continue
        mp3 = wav.with_suffix(".mp3")
        convert(wav, mp3, args.bitrate)
        if not args.KeepWav:
            try:
                wav.unlink()
            except OSError:
                pass
        print(f"  {wav.name} -> {mp3.name}")
    print(f"converted {len(wavs) - missing} wav stem(s) {where}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
