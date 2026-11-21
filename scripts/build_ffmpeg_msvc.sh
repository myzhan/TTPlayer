#!/usr/bin/env bash
# Windows（MSVC）：在继承了 MSVC 开发者环境的 MSYS2 shell 里，从 3rd/ffmpeg 源码现编静态 FFmpeg，
# 默认分别产出 Release /MD 到 3rd/ffmpeg-build、Debug /MDd 到其 debug/ 子目录。
# 可用 TTPLAYER_FFMPEG_CONFIG=Debug|Release 只构建一档；库名为 avformat.lib 等。
# 与 MinGW/mac/linux 同一份组件清单（scripts/ffmpeg_components.sh）。
#
# 前置条件：
#   - 已在同一 shell 里初始化 MSVC x64 developer environment（vcvars64）
#   - MSYS2 安装 pkgconf，用 pkgconf 读 zlib.pc 与外部编码库的 .pc
#
# zlib 与外部编码库（ogg/vorbis/opus/lame）一样从 3rd/ 源码现编，不再依赖 vcpkg：
#   zlib 的官方 CMake 在 Windows 下把静态库叫 zs.lib（Debug 再带 d 后缀），
#   而 zlib.pc 与 FFmpeg 都按 `-lz` 找，所以 install 后补一份 z.lib 副本。
#
# 外部编码库（ogg/vorbis/opus/lame）在 configure 之前用同一套 MSVC 现编：
#   Xiph 三家都带 CMake；LAME 上游只有 autotools 与古董级 Makefile.MSVC
#   （硬编码 /machine:I386 与 /MT，VS2022 跑不了），所以在构建目录生成一个
#   最小 CMake 包装，把 libmp3lame/*.c + mpglib/*.c 编成 mp3lame.lib，
#   配置头用上游自带的 configMS.h。
#
# 幂等：源码 commit、本脚本、组件清单、依赖路径都一致且库齐全才跳过；--force 强制重来。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.."
ROOT=$(pwd)
source "$SCRIPT_DIR/ffmpeg_components.sh"
source "$SCRIPT_DIR/codec_deps.sh"

if [[ -z "${TTPLAYER_FFMPEG_CONFIG:-}" ]]; then
    for config in Release Debug; do
        TTPLAYER_FFMPEG_CONFIG="$config" bash "$SCRIPT_DIR/build_ffmpeg_msvc.sh" "$@"
    done
    exit 0
fi

SRC="$ROOT/3rd/ffmpeg"
PREFIX="$ROOT/3rd/ffmpeg-build"
CONFIG="$TTPLAYER_FFMPEG_CONFIG"
case "$CONFIG" in
    Release) CRT=-MD ;;
    Debug) CRT=-MDd; PREFIX+="/debug" ;;
    *) echo "错误：TTPLAYER_FFMPEG_CONFIG 必须为 Debug 或 Release" >&2; exit 1 ;;
esac

# zlib：与 macOS/Linux 一致，从 3rd/zlib 现编静态库；Debug/Release 各一套。
ZLIB_SRC="$ROOT/3rd/zlib"
ZLIB_PREFIX="$ROOT/3rd/zlib-build"
if [[ "$CONFIG" == Debug ]]; then ZLIB_PREFIX="$ZLIB_PREFIX/debug"; fi
ZLIB_KEY="$CONFIG|$(git -C "$ZLIB_SRC" rev-parse HEAD 2>/dev/null || echo missing)"
if [[ "${1:-}" == "--force" ]] || [[ ! -f "$ZLIB_PREFIX/.built-config" || "$(cat "$ZLIB_PREFIX/.built-config")" != "$ZLIB_KEY" ]]; then
    echo "=== 编译 zlib（$CONFIG）==="
    # codec-build 目录在首次构建时还不存在，日志重定向会直接报 No such file；先建父目录。
    mkdir -p "$CODEC_PREFIX"
    ZLIB_BUILD="$(cygpath -m "$CODEC_PREFIX")/.obj-zlib-$CONFIG"
    rm -rf "$ZLIB_BUILD"
    cmake -S "$ZLIB_SRC" -B "$ZLIB_BUILD" -G "NMake Makefiles" \
        -DCMAKE_BUILD_TYPE="$CONFIG" -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$ZLIB_PREFIX")" \
        -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON \
        -DZLIB_BUILD_TESTING=OFF -DCMAKE_DEBUG_POSTFIX= \
        > "$ZLIB_BUILD-cfg.log" 2>&1 || { tail -n 30 "$ZLIB_BUILD-cfg.log" >&2; exit 1; }
    cmake --build "$ZLIB_BUILD" --parallel "$(nproc)" > "$ZLIB_BUILD-mk.log" 2>&1 \
        || { tail -n 30 "$ZLIB_BUILD-mk.log" >&2; exit 1; }
    cmake --install "$ZLIB_BUILD" > "$ZLIB_BUILD-ins.log" 2>&1 \
        || { tail -n 30 "$ZLIB_BUILD-ins.log" >&2; exit 1; }
    # Windows 静态库叫 zs.lib（Debug 再带 d 后缀为 zsd.lib）；zlib.pc 与
    # FFmpeg 的 `-lz` 找的是 z.lib，补一份副本让两边都命中。
    for built in zs zsd; do
        if [[ -f "$ZLIB_PREFIX/lib/$built.lib" ]]; then
            cp "$ZLIB_PREFIX/lib/$built.lib" "$ZLIB_PREFIX/lib/z.lib"
            break
        fi
    done
    printf '%s\n' "$ZLIB_KEY" > "$ZLIB_PREFIX/.built-config"
else
    echo "zlib 已就绪（$ZLIB_PREFIX），跳过编译"
fi
ZLIB_LIBDIR="$ZLIB_PREFIX/lib"
ZLIB_BINDIR="$ZLIB_PREFIX/bin"

if [[ ! -f "$SRC/configure" ]]; then
    echo "错误：3rd/ffmpeg 不存在或未初始化子模块" >&2
    exit 1
fi

require_frozen_ffmpeg "$SRC"
COMMIT=$(git -C "$SRC" rev-parse HEAD)
ZLIB_NATIVE=$(cygpath -m "$ZLIB_PREFIX")
ZLIB_NATIVE_LIBDIR=$(cygpath -m "$ZLIB_LIBDIR")

# ---- 外部编码库（mp3 / vorbis / opus）先于 FFmpeg 编好 ----
# Debug / Release 各自一套 .lib：静态库里编进了目标文件，/MD 与 /MDd 不能混链。
codec_require_sources
CODEC_COMMIT=$(codec_sources_commit)
CODEC_HASH=$(sha256sum "$SCRIPT_DIR/codec_deps.sh" | awk '{print $1}')
# Debug 的静态库单独一层：/MD 与 /MDd 不能混链。
CODEC_LIBS_PREFIX="$CODEC_PREFIX"
if [[ "$CONFIG" == Debug ]]; then
    CODEC_LIBS_PREFIX="$CODEC_PREFIX/debug"
fi
CODEC_INSTALL_WIN="$(cygpath -m "$CODEC_LIBS_PREFIX")"
CODEC_KEY="$CODEC_COMMIT|$CODEC_HASH|$(uname -m)|msvc=$CONFIG|$CODEC_INSTALL_WIN"
CODEC_JOBS=$(nproc)
export CODEC_JOBS
if [[ "${1:-}" == "--force" ]] || ! codecs_is_built "$CODEC_LIBS_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT" "" lib; then
    codecs_begin_build "$CODEC_LIBS_PREFIX"
    CODEC_BUILD="$CODEC_PREFIX/.obj-msvc-$CONFIG"
    mkdir -p "$CODEC_BUILD"
    echo "=== 编译外部编码库（ogg/vorbis/opus/lame, $CONFIG）==="
    codec_build_cmake ogg "$CODEC_3RD/ogg" "$CODEC_INSTALL_WIN" \
        -G "NMake Makefiles" -DCMAKE_BUILD_TYPE="$CONFIG" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
    codec_build_cmake opus "$CODEC_3RD/opus" "$CODEC_INSTALL_WIN" \
        -G "NMake Makefiles" -DCMAKE_BUILD_TYPE="$CONFIG" \
        -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
    codec_build_cmake vorbis "$CODEC_3RD/vorbis" "$CODEC_INSTALL_WIN" \
        -G "NMake Makefiles" -DCMAKE_BUILD_TYPE="$CONFIG" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_PREFIX_PATH="$CODEC_INSTALL_WIN"
    # LAME：上游 Makefile.MSVC 是 VS6 时代产物（/machine:I386、/MT、废弃开关），
    # 用最小 CMake 包装现编，直接得到 mp3lame.lib 并安装回头文件。
    LAME_DIR="$(cygpath -m "$CODEC_3RD/lame")"
    # 注意：heredoc 不加引号是为了让 ${LAME_DIR} 被展开，因此 CMake 自己的变量
    # （${CMAKE_CURRENT_BINARY_DIR}、${LAME_SOURCES}）必须写 \${…}；漏一个就会在
    # set -u 下报 unbound variable。
    cat > "$CODEC_BUILD/lame-CMakeLists.txt" <<LAME_CMAKE
cmake_minimum_required(VERSION 3.21)
project(ttplayer_mp3lame C)
file(READ "${LAME_DIR}/configMS.h" _lame_cfg)
file(WRITE "\${CMAKE_CURRENT_BINARY_DIR}/config.h" "\${_lame_cfg}")
file(GLOB LAME_SOURCES "${LAME_DIR}/libmp3lame/*.c" "${LAME_DIR}/mpglib/*.c")
add_library(mp3lame STATIC \${LAME_SOURCES})
target_include_directories(mp3lame PUBLIC "${LAME_DIR}/include" "${LAME_DIR}" "${LAME_DIR}/mpglib" "\${CMAKE_CURRENT_BINARY_DIR}")
target_compile_definitions(mp3lame PRIVATE HAVE_CONFIG_H HAVE_MPGLIB BS_FORMAT=BINARY _CRT_SECURE_NO_WARNINGS)
target_compile_options(mp3lame PRIVATE /w)
install(TARGETS mp3lame ARCHIVE DESTINATION lib)
install(FILES "${LAME_DIR}/include/lame.h" DESTINATION include/lame)
LAME_CMAKE
    mkdir -p "$CODEC_BUILD/lame-wrapper"
    cp "$CODEC_BUILD/lame-CMakeLists.txt" "$CODEC_BUILD/lame-wrapper/CMakeLists.txt"
    codec_build_cmake lame "$CODEC_BUILD/lame-wrapper" "$CODEC_INSTALL_WIN" -G "NMake Makefiles" -DCMAKE_BUILD_TYPE="$CONFIG" || exit 1
    codecs_finish_build "$CODEC_LIBS_PREFIX" "$CODEC_KEY" "$CODEC_COMMIT"
else
    echo "外部编码库已就绪（$CODEC_LIBS_PREFIX），跳过编译"
fi

# 不再用 --define-variable 覆盖 prefix：那是全局生效的，会把外部编码库的 .pc
# 也改指到 zlib 目录。zlib.pc 与 codec 的 .pc 都由本项目现编生成，prefix 已正确。
CODEC_PC="$(cygpath -u "$CODEC_INSTALL_WIN/lib/pkgconfig")"
ZLIB_PC="$(cygpath -u "$ZLIB_LIBDIR/pkgconfig")"
export PKG_CONFIG_LIBDIR="$ZLIB_PC:$CODEC_PC"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PATH="$(cygpath -u "$ZLIB_BINDIR"):$PATH"
if [[ "$CONFIG" == Debug && -n "${VCToolsRedistDir:-}" ]]; then
    DEBUG_CRT="$(cygpath -u "$VCToolsRedistDir")/debug_nonredist/x64/Microsoft.VC143.DebugCRT"
    if [[ -d "$DEBUG_CRT" ]]; then
        export PATH="$DEBUG_CRT:$PATH"
    fi
fi
if ! command -v pkgconf >/dev/null; then
    echo "错误：MSYS2 需要 pkgconf（pacman -S pkgconf）来读取 3rd/zlib-build 与外部编码库的 .pc" >&2
    exit 1
fi
pkgconf --exists zlib
pkgconf --exists ogg
pkgconf --exists vorbisenc
pkgconf --exists opus
echo "$CONFIG ($CRT): zlib $(pkgconf --modversion zlib): $(pkgconf --libs zlib)"
echo "$CONFIG ($CRT): ogg/vorbis/opus $(pkgconf --modversion ogg vorbis opus | tr '\n' ' ')"
SCRIPT_HASH=$(sha256sum "$SCRIPT_DIR/build_ffmpeg_msvc.sh" | awk '{print $1}')
COMP_HASH=$(sha256sum "$SCRIPT_DIR/ffmpeg_components.sh" | awk '{print $1}')
CONFIG_KEY="$COMMIT|$SCRIPT_HASH|$COMP_HASH|$CODEC_HASH|$(uname -m)|msvc=$CONFIG|$ZLIB_NATIVE"

# MSVC 的库名没有 lib 前缀、后缀是 .lib
if [[ "${1:-}" != "--force" ]] && ffmpeg_is_built "$PREFIX" "$CONFIG_KEY" "$COMMIT" "" lib; then
    echo "FFmpeg 静态库已就绪（commit ${COMMIT:0:8}），跳过编译；需重来用 --force"
    exit 0
fi

ffmpeg_begin_build "$PREFIX"

BDIR="$PREFIX/.obj-msvc"
rm -rf "$BDIR"
mkdir -p "$BDIR"
# extra-ldflags 在探测 MSVC 前原样保存；通过 pkg-config 输入的 -L/-l 才会转换为原生参数。
# 3rd/zlib 现编出来的静态库叫 zs.lib，上面已补一份 z.lib 给 `-lz` 用。
( cd "$BDIR" && "$SRC/configure" --toolchain=msvc --arch=x86_64 --target-os=win64 \
    --pkg-config=pkgconf \
    --extra-cflags="$CRT -I$(cygpath -m "$CODEC_INSTALL_WIN")/include" \
    --extra-ldflags="-L$(cygpath -m "$CODEC_INSTALL_WIN")/lib" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --disable-doc --disable-programs --disable-debug \
    --disable-everything --disable-autodetect \
    --enable-zlib \
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
    "${COMPONENTS[@]}" ) || {
        result=$?
        tail -n 100 "$BDIR/ffbuild/config.log" >&2
        exit "$result"
    }

ffmpeg_make_install "$BDIR" "$(nproc)"

ffmpeg_finish_build "$PREFIX" "$CONFIG_KEY" "$COMMIT"
echo "FFmpeg 静态库编译完成：$PREFIX"
