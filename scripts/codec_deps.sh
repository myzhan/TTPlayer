#!/usr/bin/env bash
# 格式转换用外部编码库（LAME / libogg / libvorbis / libopus）的唯一构建入口。
#
# 为什么单独一层：FFmpeg 在 configure 阶段就要探测这三个编码库
#   libmp3lame → 头文件 lame/lame.h + -lmp3lame
#   libvorbis  → pkg-config vorbis / vorbisenc
#   libopus    → pkg-config opus
# 所以它们必须先于 FFmpeg 编好；最终 app 再由 CMake 按绝对路径静态链接同一份产物。
#
# 产物统一安装到 3rd/codec-build/{include,lib,lib/pkgconfig}：
#   多架构（macOS 发版）先按架构分别 install 到 .stage-<arch>，再 lipo 合并 .a；
#   .pc 里的 stage 路径会被改写成最终 prefix，避免指向随后删掉的临时目录。
#
# 四个平台脚本 source 本文件后调用对应函数；本文件的 SHA-256 也进各脚本的 CONFIG_KEY，
# 改动这里的编译参数会让 FFmpeg 重新 configure。
#
# 兼容 zsh 与 bash：不依赖关联数组，只用位置参数与普通数组。

# 路径定位：本文件被四个平台脚本 source（macOS 用 zsh，其余 bash）。
# zsh 没有 BASH_SOURCE，$0 在 source 时指向父脚本（都在 scripts/），据此回推仓库根；
# 万一从别处 source，则退回当前工作目录（各平台脚本都已先 cd 到仓库根）。
_codec_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)"
if [[ -d "$_codec_dir/../3rd/ffmpeg" ]]; then
    CODEC_3RD="$(cd "$_codec_dir/.." && pwd)/3rd"
else
    CODEC_3RD="$(pwd)/3rd"
fi
CODEC_PREFIX="$CODEC_3RD/codec-build"
CODEC_LIBS=(ogg vorbis vorbisenc opus mp3lame)
CODEC_SOURCES=(ogg vorbis opus lame)

# 构建指纹用：四个源码子模块各自的 commit。
codec_sources_commit() {
    local name commit
    for name in "${CODEC_SOURCES[@]}"; do
        commit="$(git -C "$CODEC_3RD/$name" rev-parse HEAD 2>/dev/null || echo missing)"
        printf '%s=%s;' "$name" "$commit"
    done
}

# 源码齐全性检查：submodule 没初始化时尽早报错，别等 configure 里一片"未找到"。
codec_require_sources() {
    local name
    for name in "${CODEC_SOURCES[@]}"; do
        if [[ ! -d "$CODEC_3RD/$name" || -z "$(ls -A "$CODEC_3RD/$name" 2>/dev/null)" ]]; then
            echo "错误：3rd/$name 不存在或未初始化子模块（git submodule update --init --recursive --depth 1）" >&2
            return 1
        fi
    done
}

# pre/suf 对应各平台库名：libogg.a（mac/linux/MinGW）、ogg.lib（MSVC）。
codecs_is_built() {
    local prefix="$1" key="$2" commit="$3" pre="${4-lib}" suf="${5-a}" lib
    [[ -f "$prefix/.built-config" && -f "$prefix/.built-commit" ]] || return 1
    [[ "$(cat "$prefix/.built-config")" == "$key" ]] || return 1
    [[ "$(cat "$prefix/.built-commit")" == "$commit" ]] || return 1
    [[ -f "$prefix/include/lame/lame.h" ]] || return 1
    for lib in "${CODEC_LIBS[@]}"; do
        [[ -f "$prefix/lib/$pre$lib.$suf" ]] || return 1
    done
}

codecs_begin_build() {
    mkdir -p "$1/lib" "$1/include"
    rm -f "$1/.built-commit" "$1/.built-config"
}

codecs_finish_build() {
    printf '%s\n' "$3" > "$1/.built-commit"
    printf '%s\n' "$2" > "$1/.built-config"
}

# CMake 驱动的三个 Xiph 库；$3 起是透传的 -D 参数（架构、CRT 等）。
# 失败时把对应阶段的日志尾巴打到 stderr，避免"只说失败不说原因"。
codec_build_cmake() {
    local name="$1" src="$2" stage="$3"
    shift 3
    local bdir="$CODEC_BUILD/$name" log
    rm -rf "$bdir"
    mkdir -p "$CODEC_BUILD"
    log="$CODEC_BUILD/$name"
    # CMake 4 移除了对 <3.5 的兼容，而上游还停在旧版本号（vorbis 2.8.12）；
    # CMAKE_POLICY_VERSION_MINIMUM 让 4.x 按 3.5 的策略跑，3.x 会把它当未用变量忽略。
    if ! cmake -S "$src" -B "$bdir" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$stage" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" \
        >"$log-cfg.log" 2>&1; then
        echo "错误：$name configure 失败" >&2
        tail -n 30 "$log-cfg.log" >&2
        return 1
    fi
    if ! cmake --build "$bdir" --parallel "${CODEC_JOBS:-4}" >"$log-mk.log" 2>&1; then
        echo "错误：$name 编译失败" >&2
        tail -n 30 "$log-mk.log" >&2
        return 1
    fi
    if ! cmake --install "$bdir" >"$log-ins.log" 2>&1; then
        echo "错误：$name install 失败" >&2
        tail -n 30 "$log-ins.log" >&2
        return 1
    fi
}

# LAME 只有 autotools：out-of-tree 构建时 mpglib 的 `#include "mpglib/mpg123.h"`
# 需要源码根在 include 路径里，否则 out-of-tree 一定失败（upstream 已知问题）。
# 必须 --disable-libmpg123：LAME 缺省按 pkg-config 找系统 libmpg123（macOS 上
# Homebrew 装了就命中），那样 libmp3lame.a 不含内部 mpglib，却要链外部 -lmpg123，
# 既引入未 vendor 的动态依赖，又让 FFmpeg 的 `-lmp3lame` 探测报未定义符号。
# 调用方负责 export CFLAGS/LDFLAGS（交叉编译时放 -arch）。
codec_build_lame() {
    local stage="$1" bdir="$CODEC_BUILD/lame" log="$CODEC_BUILD/lame"
    rm -rf "$bdir"
    mkdir -p "$bdir"
    if ! ( cd "$bdir" && CPPFLAGS="-I$CODEC_3RD/lame ${CPPFLAGS:-}" \
        "$CODEC_3RD/lame/configure" \
        --prefix="$stage" \
        --disable-shared --enable-static \
        --disable-frontend --disable-mp3x --disable-gtktest --disable-dependency-tracking \
        --disable-libmpg123 --enable-decoder ) \
        >"$log-cfg.log" 2>&1; then
        echo "错误：lame configure 失败" >&2
        tail -n 30 "$log-cfg.log" >&2
        return 1
    fi
    if ! ( cd "$bdir" && make -j"${CODEC_JOBS:-4}" >"$log-mk.log" 2>&1 && make install >"$log-ins.log" 2>&1 ); then
        echo "错误：lame 编译或 install 失败" >&2
        tail -n 30 "$log-mk.log" >&2
        tail -n 30 "$log-ins.log" >&2
        return 1
    fi
    # autotools 装出来的头是 include/lame/lame.h，正好对上 FFmpeg 的 require 路径；
    # libtool 会把 mpglib convenience 库的对象并进安装版 libmp3lame.a（实测 29 个
    # 成员含 layer3.o/common.o），所以 `-lmp3lame` 单库即可解析 mpg123_* 引用。
}

# 把若干 stage 合成最终 prefix：头文件取第一份，.a 单架构直接拷、多架构 lipo，
# .pc 里的 stage 绝对路径改写成最终 prefix（否则删 stage 后 pkg-config 指向死路径）。
codecs_merge_libs() {
    local final="$1"
    shift
    local stages=("$@") first="${1}" lib arch inputs
    if [[ ${#stages[@]} -eq 0 ]]; then
        echo "错误：codecs_merge_libs 需要至少一个 stage" >&2
        return 1
    fi
    rm -rf "$final/lib" "$final/include"
    mkdir -p "$final/lib/pkgconfig" "$final/include"
    cp -a "$first/include/." "$final/include/"
    for lib in "${CODEC_LIBS[@]}"; do
        if [[ ${#stages[@]} -eq 1 ]]; then
            cp "$first/lib/lib$lib.a" "$final/lib/"
        else
            inputs=()
            for arch in "${stages[@]}"; do
                inputs+=("$arch/lib/lib$lib.a")
            done
            lipo -create "${inputs[@]}" -output "$final/lib/lib$lib.a"
        fi
    done
    local pc dst
    for pc in "$first"/lib/pkgconfig/*.pc; do
        dst="$final/lib/pkgconfig/$(basename "$pc")"
        # FFmpeg 的 test_pkg_config 只调 `--libs`（不加 --static），不会展开
        # Requires.private；静态库场景下 `-lvorbis` 单独链接就会缺 ogg 符号
        # （_oggpack_*）。这里把私有依赖提升为公开依赖，让 --libs 一起带出来。
        sed -e "s|$first|$final|g" \
            -e 's|^Requires\.private:|Requires:|' "$pc" > "$dst"
    done
}

# FFmpeg configure 的 --pkg-config 参数：系统有 pkg-config 就用系统，没有就写一个
# 只认本目录 .pc 的最小替身（macOS 不必额外 brew install pkg-config）。
# 输出为空表示按 FFmpeg 默认（pkg-config）走。
codecs_pkg_config_flag() {
    if command -v pkg-config >/dev/null 2>&1; then
        return 0
    fi
    local shim="$CODEC_PREFIX/bin/pkg-config"
    mkdir -p "$(dirname "$shim")"
    cat > "$shim" <<'SHIM'
#!/bin/sh
# 最小 pkg-config 替身：只服务 3rd/codec-build/lib/pkgconfig 下的 .pc。
# 支持 FFmpeg configure 用到的 --exists/--cflags/--libs/--modversion/--variable=。
set -u
pc_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../lib/pkgconfig" && pwd)" || exit 1
lib_dir="$(CDPATH= cd -- "$pc_dir/../.." && pwd)" || exit 1
inc_dir="$lib_dir/include"

mode=""
field_var=""
mods=""
for arg in "$@"; do
    case "$arg" in
        --exists) mode=exists ;;
        --modversion) mode=modversion ;;
        --cflags|--cflags-only-I|--cflags-only-other) mode=cflags ;;
        --libs|--libs-only-l|--libs-only-L|--libs-only-other) mode=libs ;;
        --variable=*) mode=variable; field_var="${arg#--variable=}" ;;
        --version) echo "ttplayer-pkgconf-shim 1.0"; exit 0 ;;
        -*) ;;
        *) mods="$mods $arg" ;;
    esac
done

mods="$(echo $mods | sed 's/[<>=].*//')"
[ -n "$mods" ] || exit 1

# 把 ${prefix}/${libdir}/${includedir} 换成真实路径（.pc 由 CMake 生成，格式固定）。
expand() {
    printf '%s' "$1" | sed \
        -e "s|\${prefix}|$lib_dir|g" \
        -e "s|\${exec_prefix}|$lib_dir|g" \
        -e "s|\${libdir}|$lib_dir/lib|g" \
        -e "s|\${includedir}|$inc_dir|g"
}

# 取某个 .pc 的字段；Requires / Requires.private 都要展开（静态链接要自己带全依赖）。
pc_field() {
    local pc="$pc_dir/$1.pc" field="$2" line
    [ -f "$pc" ] || return 1
    line="$(grep -m1 "^$field:" "$pc" | cut -d: -f2-)" || return 1
    expand "$line"
}

pc_libs() {
    local name="$1" out reqs dep
    out="$(pc_field "$name" Libs)"
    for key in Requires.private Requires; do
        reqs="$(pc_field "$name" "$key")"
        for dep in $reqs; do
            dep="${dep%%[<>=]*}"
            out="$out $(pc_libs "$dep")"
        done
    done
    printf '%s' "$out"
}

case "$mode" in
    exists)
        for m in $mods; do [ -f "$pc_dir/$m.pc" ] || exit 1; done
        exit 0
        ;;
    modversion)
        pc_field "$mods" Version | tr -d ' '
        ;;
    cflags)
        echo "-I$inc_dir"
        ;;
    libs)
        out=""
        for m in $mods; do out="$out $(pc_libs "$m")"; done
        echo "-L$lib_dir/lib$out"
        ;;
    variable)
        case "$field_var" in
            includedir) echo "$inc_dir" ;;
            libdir) echo "$lib_dir/lib" ;;
            prefix) echo "$lib_dir" ;;
            *) pc_field "$mods" "$field_var" ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
SHIM
    chmod +x "$shim"
    printf '%s' "--pkg-config=$shim"
}
