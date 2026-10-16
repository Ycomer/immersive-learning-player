#!/bin/sh
# A silent, seven-second video for playback state tests, not an ASR fixture.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
if [ -f Samples/Japanese.mp4 ]; then exit 0; fi
ffmpeg_bin=${FFMPEG:-ffmpeg}
if ! command -v "$ffmpeg_bin" >/dev/null 2>&1; then
    echo 'Playback checks need ffmpeg. Install it or set FFMPEG to its path.' >&2
    exit 1
fi
mkdir -p Samples
"$ffmpeg_bin" -v error -nostdin -n -f lavfi -i 'color=c=0x18202b:s=320x180:r=25' \
    -f lavfi -i 'anullsrc=r=16000:cl=mono' -t 7 -c:v libx264 -pix_fmt yuv420p \
    -c:a aac Samples/Japanese.mp4
