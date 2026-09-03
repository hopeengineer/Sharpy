#!/bin/zsh
cd "$(dirname "$0")"
R=results/ffmpeg.txt; : > $R
run() { # label, frames, cmd...
  local label=$1; local frames=$2; shift 2
  local out; out=$( { /usr/bin/time -l "$@" -f null - ; } 2>&1 )
  local rt=$(echo "$out" | grep -E "^\s*[0-9.]+ real" | awk '{print $1}')
  local rss=$(echo "$out" | grep "maximum resident" | awk '{print $1}')
  local fps=$(python3 -c "print(round($frames/$rt,1))" 2>/dev/null)
  printf "%-46s rtime=%6ss  fps=%7s  peakRSS=%5sMB\n" "$label" "$rt" "$fps" "$((rss/1048576))" | tee -a $R
}
M=media
echo "== DECODE (900 frames 4K@30 / 300 frames 1080p) ==" | tee -a $R
run "4K H.264  HW decode (videotoolbox)"  900 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_h264.mp4
run "4K HEVC   HW decode (videotoolbox)"  900 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_hevc.mp4
run "4K ProRes HW decode (videotoolbox)"  900 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_prores422hq.mov
run "4K H.264  SW decode (libavcodec)"    900 ffmpeg -v error -i $M/test4k_h264.mp4
run "4K ProRes SW decode (libavcodec)"    900 ffmpeg -v error -i $M/test4k_prores422hq.mov
run "1080p H.264 HW decode"               900 ffmpeg -v error -hwaccel videotoolbox -i $M/test1080_h264.mp4
echo "== MULTI-STREAM (4x 4K H.264 HW decode concurrently = 3600 frames) ==" | tee -a $R
run "4x 4K H.264 HW decode, aggregate"   3600 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_h264.mp4 -hwaccel videotoolbox -i $M/test4k_h264.mp4 -hwaccel videotoolbox -i $M/test4k_h264.mp4 -hwaccel videotoolbox -i $M/test4k_h264.mp4 -map 0:v -map 1:v -map 2:v -map 3:v
run "4x 4K ProRes HW decode, aggregate"  3600 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_prores422hq.mov -hwaccel videotoolbox -i $M/test4k_prores422hq.mov -hwaccel videotoolbox -i $M/test4k_prores422hq.mov -hwaccel videotoolbox -i $M/test4k_prores422hq.mov -map 0:v -map 1:v -map 2:v -map 3:v
echo "== ENCODE (900 frames 4K) ==" | tee -a $R
run "4K -> H.264 HW encode 40Mbps"        900 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_h264.mp4 -c:v h264_videotoolbox -b:v 40M
run "4K -> HEVC  HW encode 30Mbps"        900 ffmpeg -v error -hwaccel videotoolbox -i $M/test4k_h264.mp4 -c:v hevc_videotoolbox -b:v 30M
run "4K -> ProRes422HQ HW encode"         900 ffmpeg -v error -i $M/test4k_h264.mp4 -c:v prores_videotoolbox -profile:v 3
run "1080p -> H.264 HW encode 12Mbps"     900 ffmpeg -v error -hwaccel videotoolbox -i $M/test1080_h264.mp4 -c:v h264_videotoolbox -b:v 12M
echo "== ANALYSIS FILTERS ==" | tee -a $R
run "ebur128 loudness, 203s audio"          1 ffmpeg -v error -i $M/speech16k.wav -af ebur128
run "signalstats (QCTools core), 1080p"   900 ffmpeg -v error -i $M/test1080_h264.mp4 -vf signalstats
run "signalstats (QCTools core), 4K"      900 ffmpeg -v error -i $M/test4k_h264.mp4 -vf signalstats
run "scene-change select, 1080p"          900 ffmpeg -v error -i $M/test1080_h264.mp4 -vf "select='gt(scene,0.3)'"
run "cropdetect, 4K"                      900 ffmpeg -v error -i $M/test4k_h264.mp4 -vf cropdetect
run "silencedetect+astats, 203s audio"      1 ffmpeg -v error -i $M/speech16k.wav -af "silencedetect=n=-45dB:d=0.3,astats"
echo FFMPEG_DONE | tee -a $R
