#!/bin/zsh
# Clips to edit in the example, made with ffmpeg from the example's photos (fetch-pictures.sh first): a landscape clip
# with a silent sound track, panning across a photo; one shot as a phone held upright shoots it (its frames stored on
# their side, a track transform turning them upright); a slow-motion one at 240 frames a second; and music to lay under
# them. Into Example/Clips, which git ignores; the app takes the folder as it is at build time.
set -e
cd "${0:A:h}/.."
out=Clips
mkdir -p $out
ff=(ffmpeg -loglevel error -y)
if [[ ! -s $out/1-landscape.mov ]]; then
    $ff -loop 1 -framerate 30 -i Pictures/01-2048x1365.jpg -f lavfi -i "anullsrc=r=44100:cl=mono" \
        -vf "scale=2880:-2,crop=1920:1080:x='(iw-1920)*t/12':y='(ih-1080)/2',format=yuv420p" \
        -t 12 -c:v libx264 -crf 20 -c:a aac -shortest $out/1-landscape.mov
fi
if [[ ! -s $out/2-upright.mov ]]; then
    # Upright 1080×1920 frames turned a quarter left to be stored 1920×1080, shown turned a quarter right (a phone's).
    $ff -loop 1 -framerate 30 -i Pictures/03-1365x2048.jpg -f lavfi -i "anullsrc=r=44100:cl=mono" \
        -vf "scale=1280:-2,crop=1080:1920:x='(iw-1080)/2':y='(ih-1920)*t/8',transpose=2,format=yuv420p" \
        -t 8 -c:v libx264 -crf 20 -c:a aac -shortest /tmp/hangar-side.mov
    $ff -display_rotation -90 -i /tmp/hangar-side.mov -c copy $out/2-upright.mov
fi
if [[ ! -s $out/3-slow-motion.mov ]]; then
    $ff -loop 1 -framerate 240 -i Pictures/04-2048x1365.jpg \
        -vf "scale=1920:-2,crop=1280:720:x='(iw-1280)*t/6':y='(ih-720)*t/6',format=yuv420p" \
        -t 6 -r 240 -c:v libx264 -crf 22 $out/3-slow-motion.mov
fi
# Music for Add Music: two soft chords, swelling and fading, quiet.
if [[ ! -s $out/music-calm.m4a ]]; then
    $ff -f lavfi -i "aevalsrc='0.05*(sin(2*PI*220*t)+sin(2*PI*277.2*t)+sin(2*PI*329.6*t))*(0.6+0.4*sin(2*PI*0.25*t))':s=44100:d=20" \
        -af "afade=t=in:d=2,afade=t=out:st=17:d=3" -c:a aac $out/music-calm.m4a
fi
if [[ ! -s $out/music-bright.m4a ]]; then
    $ff -f lavfi -i "aevalsrc='0.05*(sin(2*PI*261.6*t)+sin(2*PI*329.6*t)+sin(2*PI*392*t))*(0.5+0.5*abs(sin(2*PI*1*t)))':s=44100:d=16" \
        -af "afade=t=in:d=1,afade=t=out:st=14:d=2" -c:a aac $out/music-bright.m4a
fi
ls $out/*.mov | wc -l | xargs echo clips:
