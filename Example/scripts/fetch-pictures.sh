#!/bin/zsh
# Photos to edit in the example: Unsplash photos through picsum.photos (the Unsplash licence: free to use), landscape,
# portrait and square, 2048 on the long side. Into Example/Pictures, which git ignores; the app takes the folder as it
# is at build time, and photos picked from the library with +. The same photos every time: fixed ids.
set -e
cd "${0:A:h}/.."
out=Pictures
mkdir -p $out
ids=(10 15 28 29 54 64 76 91 103 1015 1018 1025 1043 1062 1074 1080)
sizes=(2048x1365 2048x1365 1365x2048 2048x1365 2048x2048 1365x2048 2048x1365 1365x2048
       2048x1365 2048x1365 2048x1365 1365x2048 2048x1365 1365x2048 2048x1365 2048x2048)
for i in {1..${#ids}}; do
    id=$ids[$i]; size=$sizes[$i]; w=${size%x*}; h=${size#*x}
    file=$out/$(printf "%02d" $i)-${w}x${h}.jpg
    [[ -s $file ]] && continue
    curl -sfL "https://picsum.photos/id/$id/$w/$h.jpg" -o $file
done
ls $out | wc -l | xargs echo pictures:
du -sh $out
