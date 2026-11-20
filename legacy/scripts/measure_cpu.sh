#!/bin/zsh
# 播放态 CPU 实测：用 ps 的累计 CPU 时间在采样窗口内取差值，换算成单核百分比。
#
# 用法：scripts/measure_cpu.sh [音频文件] [采样窗口秒数]
#   音频文件默认 /tmp/bench_long.wav（90 秒正弦，不存在就地生成）
#   采样窗口默认 10 秒；文件长度必须盖住"6 秒预热 + 采样窗口"
#
# 为什么不用 sample / top：
#   · sample 的计数包含阻塞线程（能看到十个线程"卡在 open()"），不能当 CPU 归因；
#   · top 只给瞬时值，频谱这种每帧都一样的负载会被采样抖动淹没。
#   ps -o time 是进程真实的累计 CPU 时间，取差值除以窗口 = 这段时间的平均单核占用。
#
# 注意：
#   · 只有 TTPLAYER_SELFTEST=1 时才重定向存档（LibraryStore.swift），普通启动会写用户
#     真实 state.json，所以这里先备份再删，测完原样还原并核对 shasum。
#   · 必须亮屏且窗口可见时测。窗口被遮挡或熄屏时频谱会主动停画（SpectrumView.tick 的
#     遮挡判断），数字会掉到 3 % 左右，那是另一条路径，别混着比。
set -e
cd "$(dirname "$0")/.."

# 整轮保持亮屏；只把窗口置前仍可能在采样过程中因屏幕休眠停掉频谱，产生虚假的低值。
caffeinate -diu &
wake_pid=$!
trap 'kill "$wake_pid" 2>/dev/null || true' EXIT INT TERM

file=${1:-/tmp/bench_long.wav}
window=${2:-10}

# 默认素材现造现用：gen_wav 的 10~12 秒样本不够 6 + 10 的长度，让它额外吐一条 90 秒的
if [[ ! -f "$file" ]]; then
    tmpdir=$(mktemp -d)
    swift scripts/gen_wav.swift "$tmpdir" 90 > /dev/null
    mv "$tmpdir/bench_long.wav" "$file"
    rm -rf "$tmpdir"
fi

[[ -f "$file" ]] || { echo "找不到音频文件：$file"; exit 1; }
[[ -d build/TTPlayer.app ]] || { echo "先跑 ./build_app.sh 生成 build/TTPlayer.app"; exit 1; }

state="$HOME/Library/Application Support/TTPlayer/state.json"
backup=$(mktemp -t ttplayer-state.XXXXXX)
had=0
[[ -f "$state" ]] && { cp "$state" "$backup"; had=1; }

restore() {
    kill "$wake_pid" 2>/dev/null || true
    pkill -x TTPlayer 2>/dev/null || true
    sleep 0.5
    if (( had )); then cp "$backup" "$state"; else rm -f "$state"; fi
    rm -f "$backup"
    if (( had )); then echo "存档已还原：$(shasum "$state" | cut -c1-40)"; fi
}
trap restore EXIT INT TERM

pkill -x TTPlayer 2>/dev/null || true
sleep 1
rm -f "$state"

open -a "$PWD/build/TTPlayer.app" "$file"
sleep 6

pid=$(pgrep -x TTPlayer)
[[ -n "$pid" ]] || { echo "播放器没起来"; exit 1; }

# 采样前再顶一次窗：macOS 只要窗口有一点被别的窗口盖住就不算 .visible，频谱会停画，
# 数字直接掉到 2~4 %。不顶这一下，同一份代码能测出 8.7 % 和 2.2 % 两个结果。
open -a "$PWD/build/TTPlayer.app"
sleep 1

a=$(ps -p "$pid" -o time= | tr -d ' ')
sleep "$window"
b=$(ps -p "$pid" -o time= | tr -d ' ')

python3 - "$a" "$b" "$window" "$file" <<'PY'
import sys
def secs(t):
    m, s = t.split(':')
    return int(m) * 60 + float(s)
a, b, w = secs(sys.argv[1]), secs(sys.argv[2]), float(sys.argv[3])
print(f"{(b - a) / w * 100:.1f} % 单核  ({a:.2f}s → {b:.2f}s，窗口 {w:.0f}s，{sys.argv[4].rsplit('/', 1)[-1]})")
PY
