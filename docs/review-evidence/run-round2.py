"""本机审查复现：链接已有 Unix Makefiles Debug 对象，不修改产品代码。
从仓库根执行 python3 docs/review-evidence/run-round2.py [build目录]。
白盒测试通过 -fno-access-control 调度边界；不代表硬件端到端取证。
"""
import collections
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile
import wave

root = Path(__file__).resolve().parents[2]
os.chdir(root)
build = Path(sys.argv[1] if len(sys.argv) > 1 else "build").resolve()
flags = {}
for line in (build / "CMakeFiles/ttplayer.dir/flags.make").read_text().splitlines():
    if " = " in line:
        key, value = line.split(" = ", 1)
        flags[key] = shlex.split(value)

with wave.open("/tmp/tt-review2-ramp.wav", "wb") as audio:
    audio.setnchannels(2)
    audio.setsampwidth(2)
    audio.setframerate(44100)
    audio.writeframes(b"".join(struct.pack("<hh", value, value)
                      for value in (int(i / (30 * 44100) * 20000)
                                    for i in range(30 * 44100))))

with tempfile.TemporaryDirectory(prefix="tt-review2-evidence-") as temp:
    obj, binary = Path(temp) / "probe.o", Path(temp) / "probe"
    subprocess.run(["/usr/bin/c++", *flags["CXX_DEFINES"], *flags["CXX_INCLUDES"],
                    *flags["CXX_FLAGS"], "-fno-access-control", "-c",
                    str(root / "docs/review-evidence/round2-probe.cpp"),
                    "-o", str(obj)], check=True)
    link = shlex.split((build / "CMakeFiles/ttplayer.dir/link.txt").read_text())
    link[link.index("CMakeFiles/ttplayer.dir/src/main.cpp.o")] = str(obj)
    link[link.index("-o") + 1] = str(binary)
    subprocess.run(link, cwd=build, check=True)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", SDL_AUDIODRIVER="dummy")
    env.pop("TTPLAYER_SILENT_OUTPUT", None)
    for mode in [[], ["seek-race"]]:
        result = subprocess.run([str(binary), *mode], env=env, capture_output=True,
                                text=True, timeout=20)
        print("mode", mode, "exit", result.returncode, result.stdout, result.stderr)
    counts = collections.Counter()
    for _ in range(30):
        try:
            result = subprocess.run([str(binary), "reorder"], env=env,
                                    capture_output=True, text=True, timeout=3)
            counts[(result.returncode, result.stdout.strip())] += 1
        except subprocess.TimeoutExpired:
            counts[("timeout", "")] += 1
    print("reorder_30_runs", dict(counts))
