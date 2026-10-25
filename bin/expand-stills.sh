#!/usr/bin/env bash
# Each still in a one-frame-per-photo video becomes 5 seconds of real frames.
# Usage: expand-stills SOURCE
# Writes SOURCE with "-5s" inserted before the extension.

set -euo pipefail

FFMPEG=${FFMPEG:-ffmpeg}
hold=5
fps=30

if [[ $# -ne 1 ]]; then
  echo "Usage: expand-stills SOURCE" >&2
  exit 1
fi

input=$1

if [[ ! -f $input ]]; then
  echo "File not found: $input" >&2
  exit 1
fi

dir=$(dirname -- "$input")
base=$(basename -- "$input")
stem=${base%.*}
ext=${base##*.}

if [[ $stem == "$base" ]]; then
  output=$dir/${base}-${hold}s
else
  output=$dir/${stem}-${hold}s.$ext
fi

if [[ -e $output ]]; then
  echo "Output already exists: $output" >&2
  exit 1
fi

"$FFMPEG" -i "$input" -an \
  -vf "setpts=N*${hold}/TB,fps=${fps},tpad=stop_mode=clone:stop_duration=${hold}" \
  -c:v libx264 -tune stillimage -pix_fmt yuv420p -crf 18 -preset medium \
  -force_key_frames "expr:gte(t,n_forced*${hold})" \
  -r "$fps" \
  "$output"
