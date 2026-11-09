#!/bin/sh
# Real H.264 / HEVC bitstreams for annexb.rs's tests: screen-like text scrolling, no B-frames, a keyframe every 30 frames,
# access unit delimiters on (the tests cut access units at them), headers before every keyframe as Media Foundation writes them.
# Needs an ffmpeg with libx264 and libx265 (brew install ffmpeg). Run from anywhere: it writes next to itself.
set -e
cd "$(dirname "$0")"
src="color=c=white:s=320x192:r=30,drawtext=text='Blurt remote %{n}':fontsize=18:x=8:y=180-mod(n*3\,180):fontcolor=black"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$src" -frames:v 60 -pix_fmt yuv420p \
  -c:v libx264 -profile:v high -bf 0 -g 30 -x264-params aud=1:keyint=30:min-keyint=30:scenecut=0 -b:v 300k -f h264 screen.h264
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$src" -frames:v 60 -pix_fmt yuv420p \
  -c:v libx265 -x265-params log-level=error:aud=1:keyint=30:min-keyint=30:scenecut=0:bframes=0:repeat-headers=1 -b:v 300k \
  -f hevc screen.h265
ls -l screen.h264 screen.h265
