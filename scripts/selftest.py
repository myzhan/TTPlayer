#!/usr/bin/env python3
"""增量构建当前源码、隔离跑自检套件，并守住真实用户存档字节。

用法：
    ./scripts/selftest.sh                     # smoke：LYRIC / QUEUE / SPECTRUM
    ./scripts/selftest.sh affected            # 按改动路径挑档
    ./scripts/selftest.sh core                # 除计时档外的全部套件
    ./scripts/selftest.sh all [release]
    ./scripts/selftest.sh gapless gain        # 指定套件

环境变量：
    TTPLAYER_BIN             跳过构建，直接用给定二进制（调用者负责它是新的）
    TTPLAYER_PROBE           报告目录（run.json / selftest.log），默认 build/selftest
    TTPLAYER_DRYRUN=1        只打印挑档结果
    TTPLAYER_AFFECTED_FILES  直接传入待分类的改动路径
    TTPLAYER_AUDIO_DRIVER    输出驱动，默认 dummy
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

from selftest_fixtures import generate
from selftest_guard import fingerprints

ROOT = Path(__file__).resolve().parents[1]
SUITE_FILE = ROOT / "src/testing/suites.txt"
# 这几档耗时明显更长，core 档跳过；全量/发布前仍要跑。
TIMED = {"GAPLESS", "GAIN", "RADIO", "RADIOLIVE", "WATCH"}
# smoke 的最小覆盖面。
SMOKE = ["LYRIC", "QUEUE", "SPECTRUM"]
RADIOLIVE_MODES = ["noresp", "slow", "stall", "disconnect", "icy", "denied", "retry"]
TIMEOUT_SECONDS = 120


def resolve_affected():
    """按改动路径挑档：只有文档 / 纯 UI / 工作流的改动才降档。"""
    changed = os.environ.get("TTPLAYER_AFFECTED_FILES")
    if changed is None:
        changed = subprocess.check_output(["git", "diff", "--name-only", "HEAD"], text=True)
        changed += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], text=True)
    files = changed.split()
    if any(not (f.endswith(".md") or f.startswith(("docs/", "src/ui/", ".github/"))) for f in files):
        return "all"
    if any(f.startswith("src/ui/") for f in files):
        return "core"
    return "smoke"


def select_suites(mode, extra, all_suites):
    if mode == "affected":
        mode = resolve_affected()
        print("affected →", mode)
    if mode == "all":
        return all_suites
    if mode == "smoke":
        return SMOKE
    if mode == "core":
        return [suite for suite in all_suites if suite not in TIMED]
    suites = [arg.upper().removeprefix("TTPLAYER_QT_").removesuffix("_PROBE") for arg in extra]
    unknown = set(suites) - set(all_suites)
    if unknown:
        print("Unknown suites:", sorted(unknown))
        sys.exit(2)
    return suites


def ensure_binary(conf):
    """默认先增量构建当前源码；TTPLAYER_BIN 给了就信调用者。"""
    binary = os.environ.get("TTPLAYER_BIN")
    if not binary:
        build = "build/release" if conf == "Release" else "build"
        subprocess.run(["cmake", "-S", ".", "-B", build, "-DCMAKE_BUILD_TYPE=" + conf], check=True)
        subprocess.run(["cmake", "--build", build, "--config", conf, "-j", "4"], check=True)
        build_dir = ROOT / build
        candidates = [build_dir / "ttplayer", build_dir / "ttplayer.exe", build_dir / conf / "ttplayer.exe"]
        binary = str(next(path for path in candidates if path.exists()))
    return Path(binary).resolve()


def source_digest():
    """源码 + 脚本 + CMakeLists 的联合 SHA-256，写进 run.json 便于追溯。"""
    digest = hashlib.sha256()
    paths = sorted(list((ROOT / "src").rglob("*")) + list((ROOT / "scripts").glob("*")) + [ROOT / "CMakeLists.txt"])
    for path in paths:
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def run_suite(binary, suite, radio_mode, fixtures, isolation, log):
    """跑一个套件（电台直播档按弱网模式再展开），返回 (PASS, FAIL, SKIP)。"""
    env = dict(os.environ,
               QT_QPA_PLATFORM="offscreen",
               SDL_AUDIODRIVER=os.environ.get("TTPLAYER_AUDIO_DRIVER", "dummy"),
               TTPLAYER_SELFTEST="1",
               TTPLAYER_SILENT_OUTPUT="1",
               TTPLAYER_TESTDIR=str(fixtures),
               TTPLAYER_QT_STATE=str(Path(isolation) / suite / "state.json"))
    # 只点亮当前套件的探针，避免继承外部环境里的别的档。
    for key in list(env):
        if key.startswith("TTPLAYER_QT_") and key.endswith("_PROBE"):
            del env[key]
    env["TTPLAYER_QT_" + suite + "_PROBE"] = "1"
    if radio_mode:
        env["TTPLAYER_QT_RADIOLIVE_MODE"] = radio_mode
        env["TTPLAYER_QT_RADIOLIVE_STRESS"] = "30"

    start = time.monotonic()
    try:
        result = subprocess.run([binary], env=env, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=TIMEOUT_SECONDS)
        output = result.stdout + result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        # 超时被直接杀掉，stdout/stderr 都要并进日志：套件自己打的进度轨迹
        # （如 ARCHIVE 的容器名）通常就在 stderr 里，漏了就没法定位卡点。
        output = "TIMEOUT\n" + str(error.stdout or "") + str(error.stderr or "")
        code = 124

    passed = len(re.findall(r" PASS$", output, re.M))
    failed = len(re.findall(r" FAIL(?:$|[ (])", output, re.M))
    skipped = len(re.findall(r" SKIP(?:$|[ (])", output, re.M))
    # 异常退出或一条结果都没打印，都要算失败，不能被当成 0 FAIL 通过。
    if code or not (passed or skipped):
        failed = max(1, failed)
    if code:
        output += f"\nPROCESS_EXIT={code}\n"

    label = suite + (":" + radio_mode if radio_mode else "")
    line = f"{label:<23} PASS={passed} FAIL={failed} SKIP={skipped} {time.monotonic() - start:.2f}s"
    print(line, flush=True)
    log.write(line + "\n" + output + "\n")
    log.flush()
    if failed:
        # 临时存档会在整轮结束时删除；先保留失败进程的隔离崩溃日志，方便 CI 定位栈。
        for crash in (Path(isolation) / suite).rglob("crash.log"):
            artifact = Path(log.name).parent / "failures" / label.replace(":", "-") / crash.name
            artifact.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(crash, artifact)
            print("CRASH_LOG", artifact, flush=True)
        print(output, flush=True)
    return passed, failed, skipped


def main(argv):
    os.chdir(ROOT)
    conf = "Release" if "release" in argv else "Debug"
    args = [arg for arg in argv if arg not in {"debug", "release"}]
    mode = args[0] if args else "smoke"
    suites = select_suites(mode, args, SUITE_FILE.read_text().split())
    if os.environ.get("TTPLAYER_DRYRUN"):
        print(conf, *suites)
        return 0

    binary = ensure_binary(conf)
    before = fingerprints()
    report = Path(os.environ.get("TTPLAYER_PROBE", ROOT / "build/selftest"))
    report.mkdir(parents=True, exist_ok=True)
    log_path = report / "selftest.log"
    passed = failed = skipped = 0
    with tempfile.TemporaryDirectory(prefix="ttplayer-selftest-") as isolation, log_path.open("w", encoding="utf-8") as log:
        metadata = {
            "binary": str(binary),
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "source_sha256": source_digest(),
            "platform": platform.platform(),
            "suites": suites,
            "audio_driver": os.environ.get("TTPLAYER_AUDIO_DRIVER", "dummy"),
            "state_before": before,
        }
        (report / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")

        fixtures = Path(isolation) / "fixtures"
        # 只有这几档需要编码矩阵；其余用最小的确定性素材即可。
        # ARCHIVE 也算：7z 与加密 ZIP 只在 matrix 档生成，否则单跑该档会静默少测两档。
        generate(fixtures, bool({"FORMAT", "GAPLESS", "DECODER", "ARCHIVE"} & set(suites)))
        fixture_skips = fixtures / "fixture-skips.json"
        if fixture_skips.exists():
            for reason in json.loads(fixture_skips.read_text()):
                skipped += 1
                print("FIXTURE SKIP", reason)
                log.write("FIXTURE SKIP " + reason + "\n")

        for suite in suites:
            for radio_mode in RADIOLIVE_MODES if suite == "RADIOLIVE" else [""]:
                suite_passed, suite_failed, suite_skipped = run_suite(
                    binary, suite, radio_mode, fixtures, isolation, log)
                passed += suite_passed
                failed += suite_failed
                skipped += suite_skipped

    after = fingerprints()
    if before != after:
        print("FAIL: user state/resume changed:", [p for p in before if before[p] != after[p]])
        failed += 1
    print(f"PASS={passed} FAIL={failed} SKIP={skipped}; {log_path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
