#!/usr/bin/env python3
"""生成本地可审阅的分发目录 build/dist；不发布、不打 tag。

产物布局：
    build/package/    Release + TTPLAYER_BUNDLE 的 CMake 构建树
    build/dist/       cmake --install 的结果（macOS 为 ttplayer.app）
"""
import argparse
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

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


WINDOWS_CRT = {"msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"}


def windows_modules(pid):
    """读取目标进程实际加载的 DLL；不在 Python 进程中加载，避免宿主 CRT 干扰。"""
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    psapi.EnumProcessModulesEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE),
                                         wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]
    psapi.EnumProcessModulesEx.restype = wintypes.BOOL
    psapi.GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE,
                                         wintypes.LPWSTR, wintypes.DWORD]
    psapi.GetModuleFileNameExW.restype = wintypes.DWORD
    handle = kernel.OpenProcess(0x0410, False, pid)  # QUERY_INFORMATION | VM_READ
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        capacity = 256
        while True:
            modules = (wintypes.HMODULE * capacity)()
            needed = wintypes.DWORD()
            if not psapi.EnumProcessModulesEx(handle, modules, ctypes.sizeof(modules),
                                             ctypes.byref(needed), 3):  # LIST_MODULES_ALL
                raise ctypes.WinError(ctypes.get_last_error())
            if needed.value <= ctypes.sizeof(modules):
                break
            capacity = needed.value // ctypes.sizeof(wintypes.HMODULE) + 32
        paths = {}
        for module in modules[:needed.value // ctypes.sizeof(wintypes.HMODULE)]:
            name = ctypes.create_unicode_buffer(32768)
            if not psapi.GetModuleFileNameExW(handle, module, name, len(name)):
                raise ctypes.WinError(ctypes.get_last_error())
            path = Path(name.value).resolve()
            paths[path.name.lower()] = path
        return paths
    finally:
        kernel.CloseHandle(handle)


def check_windows_modules(modules, bin_dir):
    """所有已加载 VC DLL 必须来自 exe 同目录；UCRT 等 Windows 系统 DLL 不在此列。"""
    for name, path in modules.items():
        if re.fullmatch(r"(?:msvcp|vcruntime|concrt)140.*\.dll", name):
            if path.parent != bin_dir:
                raise RuntimeError(f"VC 运行时未从包内加载：{path}")
    return WINDOWS_CRT.union({"qt6widgets.dll", "qoffscreen.dll"}).issubset(modules)


def windows_version_strings(exe):
    """从 exe 的版本资源读取系统显示名，不依赖 Qt 窗口标题。"""
    import ctypes
    from ctypes import wintypes

    version = ctypes.WinDLL("version", use_last_error=True)
    version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    version.GetFileVersionInfoW.restype = wintypes.BOOL
    version.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR,
                                     ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
    version.VerQueryValueW.restype = wintypes.BOOL
    ignored = wintypes.DWORD()
    size = version.GetFileVersionInfoSizeW(str(exe), ctypes.byref(ignored))
    if not size:
        raise RuntimeError(f"Windows exe 缺少版本资源：{exe}")
    data = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(str(exe), 0, size, data):
        raise ctypes.WinError(ctypes.get_last_error())
    values = {}
    for key in ("FileDescription", "ProductName", "InternalName", "OriginalFilename"):
        value = ctypes.c_void_p()
        length = wintypes.UINT()
        query = "\\StringFileInfo\\040904b0\\" + key
        if not version.VerQueryValueW(data, query, ctypes.byref(value), ctypes.byref(length)) or not value.value:
            raise RuntimeError(f"Windows exe 版本资源缺少 {key}：{exe}")
        values[key] = ctypes.wstring_at(value, length.value).rstrip("\0")
    return values


def verify_windows_metadata(exe):
    """门禁确保任务管理器显示中文名，文件名与内部身份不变。"""
    values = windows_version_strings(exe)
    expected = {"FileDescription": "千千静听", "ProductName": "千千静听",
                "InternalName": "ttplayer", "OriginalFilename": "ttplayer.exe"}
    for key, value in expected.items():
        if values.get(key) != value:
            raise RuntimeError(f"Windows exe 元数据不符：{key}={values.get(key)!r}，应为 {value!r}")
    print("WINDOWS_EXE_METADATA PASS 千千静听")


def verify_windows_ui(exe, env, temporary):
    """用 Windows 平台插件验证图标、真实 HWND 及置顶透明样式，不以 offscreen 替代。"""
    native_env = dict(env, QT_QPA_PLATFORM="windows", TTPLAYER_QT_UI_PROBE="1")
    result = subprocess.run([exe], cwd=temporary, env=native_env, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=120)
    output = result.stdout + result.stderr
    passed = len(re.findall(r" PASS$", output, re.M))
    skipped = len(re.findall(r" SKIP(?:$|[ (])", output, re.M))
    required = {"UI_exe_embedded_icon", "UI_windows_resolved_font", "UI_windows_native_single_taskbar",
                "UI_windows_panel_minimize_restore", "UI_windows_pin_preserves_layered_surface",
                "UI_windows_unpin_preserves_layered_surface", "UI_windows_pin_toggle_30_preserves_surfaces",
                "UI_windows_pin_first_show_inherits", "UI_windows_pin_reopen_inherits",
                "UI_windows_unpin_hidden_panel_reopen", "UI_windows_pin_minimize_restore",
                "UI_windows_pin_background_restore", "UI_windows_unpin_while_hidden_restore"}
    completed = set(re.findall(r"^REVIEW_PROBE (\S+) PASS$", output, re.M))
    if (result.returncode or not required.issubset(completed) or skipped
            or re.search(r" FAIL(?:$|[ (])", output, re.M)):
        raise RuntimeError(f"Windows 原生界面验证失败（{result.returncode}）：\n{output}")
    print(f"WINDOWS_NATIVE_UI PASS={passed} SKIP={skipped}")


def verify_windows(dist):
    """发布门禁：DLL 齐全、隔离环境冒烟、核对目标进程的 app-local CRT 路径。"""
    if platform.system() != "Windows":
        raise RuntimeError("Windows 分发验证必须在 Windows x64 上运行")
    import struct
    if struct.calcsize("P") != 8:
        raise RuntimeError("Windows x64 分发验证需要 64 位 Python")
    bin_dir = (Path(dist) / "bin").resolve()
    for name in ["ttplayer.exe", *sorted(WINDOWS_CRT)]:
        if not (bin_dir / name).is_file():
            raise RuntimeError(f"Windows 分发缺少 {bin_dir / name}")
    for path in bin_dir.rglob("*.dll"):
        if re.fullmatch(r"(?:msvcp140(?:_[12])?d(?:_.*)?|vcruntime140(?:_1)?d|concrt140d|ucrtbased)\.dll",
                        path.name.lower()):
            raise RuntimeError(f"发布包包含不可再分发的 Debug CRT：{path}")
    # 去掉开发工具与外部 Qt 的搜索路径；System32 已安装的 VC 仍由下方模块检查识别。
    env = {key: value for key, value in os.environ.items()
           if not key.upper().startswith(("QT_", "QML", "SDL_", "TTPLAYER_"))}
    system_root = Path(os.environ["SystemRoot"])
    env.update(PATH=os.pathsep.join([str(system_root / "System32"), str(system_root)]),
               QT_QPA_PLATFORM="offscreen", TTPLAYER_SELFTEST="1",
               TTPLAYER_SILENT_OUTPUT="1", SDL_AUDIODRIVER="dummy", SDL_AUDIO_DRIVER="dummy")
    probe_root = ROOT / "build"
    probe_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="windows-package-", dir=probe_root) as temporary:
        env["TTPLAYER_QT_STATE"] = str(Path(temporary) / "state.json")
        exe = str(bin_dir / "ttplayer.exe")
        version = subprocess.run([exe, "--version"], cwd=temporary, env=env,
                                 capture_output=True, text=True, check=True, timeout=30)
        if not re.fullmatch(r"TTPlayer \S+ Qt \S+ x86_64", version.stdout.strip()):
            raise RuntimeError(f"版本输出不符：{version.stdout!r} {version.stderr!r}")
        print(version.stdout.strip())
        verify_windows_metadata(exe)
        with tempfile.TemporaryFile(mode="w+") as log:
            process = subprocess.Popen([exe], cwd=temporary, env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        log.seek(0)
                        raise RuntimeError(f"打包进程提前退出（{process.returncode}）：{log.read()}")
                    try:
                        modules = windows_modules(process.pid)
                    except OSError as error:
                        if error.winerror != 299:  # DLL 装载尚未完成，下一轮重试。
                            raise
                    else:
                        if check_windows_modules(modules, bin_dir):
                            for name in sorted(WINDOWS_CRT):
                                print(f"APP_LOCAL_CRT PASS {modules[name]}")
                            break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("打包进程未在 30 秒内加载完整 CRT 与 offscreen 插件")
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)
        verify_windows_ui(exe, env, temporary)


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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-windows", type=Path, metavar="DIST",
                        help="仅验证已安装的 Windows 分发目录，不重新构建")
    args = parser.parse_args()
    if args.verify_windows is not None:
        verify_windows(args.verify_windows)
        return
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
    elif platform.system() == "Windows":
        verify_windows(DIST)
    print("Prepared", DIST)


if __name__ == "__main__":
    main()
