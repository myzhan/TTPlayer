#!/usr/bin/env python3
"""生成本地可审阅的分发目录 build/dist；不发布、不打 tag。

产物布局：
    build/package/    Release + TTPLAYER_BUNDLE 的 CMake 构建树
    build/dist/       cmake --install 的结果（macOS 为 ttplayer.app）
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/package"
DIST = ROOT / "build/dist"


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def build_ffmpeg():
    """按平台现编静态 FFmpeg（与 CMake 用的 3rd/ffmpeg-build 同一布局）。"""
    system = platform.system()
    if system == "Darwin":
        run("zsh", "scripts/build_ffmpeg.sh")
    elif system == "Linux":
        run("bash", "scripts/build_ffmpeg_linux.sh")


def build_bundle():
    run("cmake", "-S", ".", "-B", str(BUILD), "-DCMAKE_BUILD_TYPE=Release", "-DTTPLAYER_BUNDLE=ON")
    run("cmake", "--build", str(BUILD), "--config", "Release", "-j", "4")
    run("cmake", "--install", str(BUILD), "--config", "Release", "--prefix", str(DIST))


def sign(app):
    """macdeployqt 会改写 bundle，使链接期 adhoc 签名失效；不重签 macOS 会 SIGKILL 掉。"""
    run("codesign", "--force", "--deep", "--sign", "-", str(app))


def export_icon(app, temporary):
    """offscreen 跑一次 app，把图标导出成单张 PNG。"""
    folder = Path(temporary)
    png = folder / "icon.png"
    env = dict(os.environ,
               QT_QPA_PLATFORM="offscreen",
               TTPLAYER_SELFTEST="1",
               TTPLAYER_QT_STATE=str(folder / "state.json"),
               TTPLAYER_QT_ICON_EXPORT=str(png))
    subprocess.run([str(app / "Contents/MacOS/ttplayer")], env=env, check=True)
    return png


def make_icns(app, png, temporary):
    """由单张 PNG 生成 AppIcon.icns：先出 10 档 iconset，再交给 iconutil。"""
    iconset = Path(temporary) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            run("sips", "-z", str(size * scale), str(size * scale), str(png),
                "--out", str(iconset / name), stdout=subprocess.DEVNULL)
    resources = app / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    run("iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns"))


def main():
    os.chdir(ROOT)
    build_ffmpeg()
    build_bundle()
    if platform.system() == "Darwin":
        app = DIST / "ttplayer.app"
        sign(app)
        with tempfile.TemporaryDirectory(prefix="ttplayer-icon-") as temporary:
            png = export_icon(app, temporary)
            make_icns(app, png, temporary)
        sign(app)
    print("Prepared", DIST)


if __name__ == "__main__":
    main()
