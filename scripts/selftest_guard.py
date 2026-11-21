#!/usr/bin/env python3
"""真实用户存档指纹守卫：被测进程跑完前后，存档必须逐字节一致。

单跑：python3 scripts/selftest_guard.py <ttplayer 可执行文件>
CTest 逐档调用；selftest.py 用它的 fingerprints() 守住整轮自检。
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

# 存档现在是 SQLite：主库之外 -wal/-shm 也会随写入变化，一并与旧 JSON 档一起看住。
STATE_FILES = ("state.db", "state.db-wal", "state.db-shm", "state.json", "resume.json")
RADIOLIVE_MODES = ["noresp", "slow", "stall", "disconnect", "icy", "denied", "retry"]


def state_roots():
    """三个平台各自的用户档目录。"""
    roots = [
        Path.home() / "Library/Application Support/TTPlayer",
        Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "TTPlayer",
    ]
    if os.environ.get("APPDATA"):
        roots.append(Path(os.environ["APPDATA"]) / "TTPlayer")
    return roots


def fingerprints():
    """路径 → SHA-256（不存在记 None），比较前后两份即可发现任何写入。"""
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
            for root in state_roots() for path in (root / name for name in STATE_FILES)}


if __name__ == "__main__":
    before = fingerprints()
    # 电台直播档要在 7 种弱网模式下各跑一遍。
    modes = RADIOLIVE_MODES if os.environ.get("TTPLAYER_QT_RADIOLIVE_PROBE") else [None]
    code = 0
    for mode in modes:
        environment = dict(os.environ)
        if mode:
            environment.update(TTPLAYER_QT_RADIOLIVE_MODE=mode, TTPLAYER_QT_RADIOLIVE_STRESS="30")
        result = subprocess.run(sys.argv[1:], env=environment)
        if result.returncode:
            code = result.returncode
    changed = before != fingerprints()
    if changed:
        print("USER_STATE_GUARD FAIL: state/resume bytes changed", file=sys.stderr)
    sys.exit(1 if changed else code)
