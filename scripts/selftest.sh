#!/bin/zsh
# 分级自检：按套件跑真实链路（命令见 AGENTS.md《常用命令》，环境变量见《自检环境变量》）。
#
# 用法：
#   ./scripts/selftest.sh                 冒烟档（debug）：lyric + playlist + spectrum，几秒
#   ./scripts/selftest.sh all             全量 311 项（debug），发布门槛
#   ./scripts/selftest.sh all release     release 二进制全量
#   ./scripts/selftest.sh ui import       只跑指定套件（逗号或空白分隔，按给出的顺序执行）
#   ./scripts/selftest.sh release ui      构型也可以写在前面
#
# 跑打包版（二进制不在 .build 里，给 TTPLAYER_BIN 就跳过编译）：
#   TTPLAYER_BIN=build/TTPlayer.app/Contents/MacOS/TTPlayer ./scripts/selftest.sh all
#
# 退出码：0 全绿 / 1 有断言失败 / 2 套件名不认识；编译失败时透传编译器的非 0。
#
# 系统刚睡醒时音频设备还没就绪，engine.start() 会报 AVFAudio 35（裸 AVAudioEngine 也一样），
# 跑音频类套件前先 `caffeinate -u -t 120` 把机器唤醒。
set -e
cd "$(dirname "$0")/.."

# ---- 参数：构型（debug/release）可写在最前或最后，其余都是套件名 ----
conf=debug
args=("$@")
if [[ ${#args[@]} -gt 0 ]]; then
    if [[ ${args[1]} == debug || ${args[1]} == release ]]; then
        conf=${args[1]}
        args=("${args[@]:1}")
    elif [[ ${args[-1]} == debug || ${args[-1]} == release ]]; then
        conf=${args[-1]}
        n=${#args[@]}
        args=("${args[@]:0:$((n - 1))}")
    fi
fi
# 不点套件名就是冒烟档：改纯逻辑与绘制时用它，不碰音频设备与窗口
suites=${(j:,:)args}
[[ -n "$suites" ]] || suites=smoke

if [[ -n ${TTPLAYER_BIN} ]]; then
    # 打包版：现成二进制，不重编（编译产物在 .build 里，换不出来这个）
    bin=$TTPLAYER_BIN
    echo "→ 用现成二进制：$bin"
else
    echo "→ 编译（$conf）"
    swift build -c $conf
    bin="$(swift build -c $conf --show-bin-path)/TTPlayer"
fi
[[ -x "$bin" ]] || { echo "找不到可执行文件：$bin"; exit 1; }

# ---- 测试曲库：缺什么补什么（素材都只用系统自带能力现造，仓库不入库音频）----
TESTDIR=${TTPLAYER_TESTDIR:-$PWD/testlib}
mkdir -p "$TESTDIR"
if [[ ! -f "$TESTDIR/demo01.wav" || ! -f "$TESTDIR/demo02.wav" ]]; then
    echo "→ 造基础样本（12 s / 10 s 正弦）"
    swift scripts/gen_wav.swift "$TESTDIR"
fi
if [[ ! -f "$TESTDIR/demo01.lrc" ]]; then
    printf '[00:01.00]第一句\n[00:02.50]第二句\n' > "$TESTDIR/demo01.lrc"
fi
if [[ ! -f "$TESTDIR/cover.m4a" || ! -f "$TESTDIR/cover.flac" ]]; then
    echo "→ 造封面试材（内嵌图 + 目录大图回落）"
    swift scripts/gen_cover.swift "$TESTDIR"
fi
if [[ ! -f "$TESTDIR/demo_dsd.dsf" || ! -f "$TESTDIR/demo_dsd.dff" ]]; then
    echo "→ 造 DSD 样本"
    swift scripts/gen_dsd.swift "$TESTDIR" 3
fi
# TTA 不再自带编码器（解码已全部交给 FFmpeg）：testlib/demo_tta.tta 缺失时
# DecoderSuite 的 TTA 段自动 SKIP，不在这里现造。

# APE 真引擎播放需要上游 mac CLI 编的真实码流（自制样本只够验参数/定位/逐字节，
# 验不了 seek 表/帧包完整性）。FFmpeg 没有 ape encoder（上游只提供解码器，编码只以
# Windows 桌面版发行），只能靠 brew install mac（Monkey's Audio SDK 的 Unix port）。
# brew install mac 后就能现场从 demo01.wav 转一份，不入库。
if [[ ! -f "$TESTDIR/demo_ape.ape" && -f "$TESTDIR/demo01.wav" ]]; then
    if command -v mac >/dev/null 2>&1; then
        echo "→ 造 APE 样本（mac -c1000）"
        mac "$TESTDIR/demo01.wav" "$TESTDIR/demo_ape.ape" -c1000 >/dev/null \
            || rm -f "$TESTDIR/demo_ape.ape"
    else
        echo "→ 未装 brew install mac：APE 真引擎段会 SKIP（其他 APE 断言不受影响）"
    fi
fi

# ---- 探针目录：报告走 $PROBE/tt_selftest.txt，截图走 $SHOTS（cacheDisplay，不需要录屏权限）----
PROBE=${TTPLAYER_PROBE:-$PWD/build/selftest}
SHOTS=${TTPLAYER_SHOTDIR:-$PROBE/shots}
mkdir -p "$PROBE" "$SHOTS"
rm -f "$PROBE/tt_selftest.txt"

# 自检靠 TTPLAYER_TESTDIR 把存档重定向到测试曲库；真实存档前后必须逐字节相同
state="$HOME/Library/Application Support/TTPlayer/state.json"
before=$(shasum "$state" 2>/dev/null | awk '{print $1}')

echo "→ 自检：套件 $suites（$conf）"
# 自检会真实开播（多个套件验“有声音”）。
# 不送物理设备靠 TTPLAYER_SILENT_OUTPUT=1（AudioEngine 里把 mainMixer.outputVolume 锁 0、
# 频谱 tap 改接 fadeNode 上游），不影响其他应用。以前用 osascript 把系统 mute 掉会连
# 后台浏览器/音乐一起没声，脚本崩溃 trap 还原失败用户就一直没声，不再用。
set +e
TTPLAYER_SELFTEST=1 TTPLAYER_SILENT_OUTPUT=1 TTPLAYER_SUITE="$suites" TTPLAYER_TESTDIR="$TESTDIR" \
    TTPLAYER_PROBE="$PROBE" TTPLAYER_SHOTDIR="$SHOTS" "$bin" 2>&1 | tee "$PROBE/selftest.log"
code=${pipestatus[1]}
set -e

after=$(shasum "$state" 2>/dev/null | awk '{print $1}')
if [[ "$before" != "$after" ]]; then
    echo "✗ 用户 state.json 被写：${before:-（原本不存在）} → ${after:-（没了）}"
    exit 1
fi

echo "报告：$PROBE/selftest.log（镜像 tt_selftest.txt）  截图：$SHOTS"
if [[ $code -eq 0 ]]; then
    echo "✓ 自检通过"
elif [[ $code -eq 2 ]]; then
    echo "✗ 套件名不认识（可用：lyric playlist spectrum playback cover cue format decoder import radio ui perf system / smoke / all）"
else
    echo "✗ 有断言失败（退出码 $code）"
fi
exit $code
