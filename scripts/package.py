#!/usr/bin/env python3
"""Prepare a local, reviewable install tree; never publish or tag."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
os.chdir(ROOT)
if platform.system()=="Darwin":subprocess.run(["zsh","scripts/build_ffmpeg.sh"],check=True)
elif platform.system()=="Linux":subprocess.run(["bash","scripts/build_ffmpeg_linux.sh"],check=True)
build=ROOT/"build-package"
args=["cmake","-S",".","-B",str(build),"-DCMAKE_BUILD_TYPE=Release","-DTTPLAYER_BUNDLE=ON"]
subprocess.run(args,check=True)
subprocess.run(["cmake","--build",str(build),"--config","Release","-j","4"],check=True)
subprocess.run(["cmake","--install",str(build),"--config","Release","--prefix",str(ROOT/"dist")],check=True)
if platform.system()=="Darwin":
    app=ROOT/"dist/ttplayer.app"
    with tempfile.TemporaryDirectory(prefix="ttplayer-icon-") as temporary:
        folder=Path(temporary);png=folder/"icon.png";iconset=folder/"AppIcon.iconset";iconset.mkdir()
        env=dict(os.environ,QT_QPA_PLATFORM="offscreen",TTPLAYER_SELFTEST="1",TTPLAYER_QT_STATE=str(folder/"state.json"),TTPLAYER_QT_ICON_EXPORT=str(png))
        subprocess.run([str(app/"Contents/MacOS/ttplayer")],env=env,check=True)
        for size in [16,32,128,256,512]:
            for scale in [1,2]:
                name=f"icon_{size}x{size}"+("@2x" if scale==2 else "")+".png"
                subprocess.run(["sips","-z",str(size*scale),str(size*scale),str(png),"--out",str(iconset/name)],check=True,stdout=subprocess.DEVNULL)
        resources=app/"Contents/Resources";resources.mkdir(exist_ok=True)
        subprocess.run(["iconutil","-c","icns",str(iconset),"-o",str(resources/"AppIcon.icns")],check=True)
    subprocess.run(["codesign","--force","--deep","--sign","-",str(app)],check=True)
print("Prepared",ROOT/"dist")
