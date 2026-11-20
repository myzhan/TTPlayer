#!/usr/bin/env python3
"""Build current sources, run isolated suites, guard real user state bytes."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import json
import platform
from selftest_fixtures import generate
from selftest_guard import fingerprints

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
ALL = (ROOT / "src/testing/suites.txt").read_text().split()
TIMED = {"GAPLESS", "GAIN", "RADIO", "RADIOLIVE", "WATCH"}
args = sys.argv[1:]
conf = "Release" if "release" in args else "Debug"
args = [arg for arg in args if arg not in {"debug", "release"}]
mode = args[0] if args else "smoke"
if mode == "affected":
    changed = os.environ.get("TTPLAYER_AFFECTED_FILES")
    if changed is None:
        changed = subprocess.check_output(["git", "diff", "--name-only", "HEAD"], text=True)
        changed += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], text=True)
    files = changed.split()
    mode = "all" if any(not (f.endswith(".md") or f.startswith(("docs/", "src/ui/", ".github/"))) for f in files) else "core" if any(f.startswith("src/ui/") for f in files) else "smoke"
    print("affected →", mode)
if mode in {"all", "core", "smoke"}:
    suites = ALL if mode == "all" else ["LYRIC","QUEUE","SPECTRUM"] if mode == "smoke" else [s for s in ALL if s not in TIMED]
else:
    suites = [arg.upper().removeprefix("TTPLAYER_QT_").removesuffix("_PROBE") for arg in args]
    unknown = set(suites) - set(ALL)
    if unknown:
        print("Unknown suites:", sorted(unknown)); sys.exit(2)
if os.environ.get("TTPLAYER_DRYRUN"):
    print(conf, *suites); sys.exit(0)

binary = os.environ.get("TTPLAYER_BIN")
if not binary:
    build = "build-release" if conf == "Release" else "build"
    subprocess.run(["cmake", "-S", ".", "-B", build, "-DCMAKE_BUILD_TYPE=" + conf], check=True)
    subprocess.run(["cmake", "--build", build, "--config", conf, "-j", "4"], check=True)
    candidates = [ROOT/build/"ttplayer", ROOT/build/"ttplayer.exe", ROOT/build/conf/"ttplayer.exe"]
    binary = str(next(path for path in candidates if path.exists()))
binary = str(Path(binary).resolve())

before = fingerprints()
report = Path(os.environ.get("TTPLAYER_PROBE", ROOT/"build/selftest"));report.mkdir(parents=True, exist_ok=True)
passed = failed = skipped = 0
with tempfile.TemporaryDirectory(prefix="ttplayer-selftest-") as isolation, (report/"selftest.log").open("w") as log:
    source_hash=hashlib.sha256()
    for path in sorted(list((ROOT/"src").rglob("*"))+list((ROOT/"scripts").glob("*"))+[ROOT/"CMakeLists.txt"]):
        if path.is_file():source_hash.update(str(path.relative_to(ROOT)).encode());source_hash.update(path.read_bytes())
    metadata={"binary":binary,"binary_sha256":hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
              "source_sha256":source_hash.hexdigest(),"platform":platform.platform(),"suites":suites,
              "audio_driver":os.environ.get("TTPLAYER_AUDIO_DRIVER","dummy"),"state_before":before}
    (report/"run.json").write_text(json.dumps(metadata,ensure_ascii=False,indent=2))
    fixtures=Path(isolation)/"fixtures"
    generate(fixtures,bool({"FORMAT","GAPLESS","DECODER"}&set(suites)))
    fixture_skips=fixtures/"fixture-skips.json"
    if fixture_skips.exists():
        for reason in json.loads(fixture_skips.read_text()):
            skipped+=1;print("FIXTURE SKIP",reason);log.write("FIXTURE SKIP "+reason+"\n")
    for suite in suites:
        modes = ["noresp", "slow", "stall", "disconnect", "icy", "denied", "retry"] if suite == "RADIOLIVE" else [""]
        for radio_mode in modes:
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", SDL_AUDIODRIVER=os.environ.get("TTPLAYER_AUDIO_DRIVER","dummy"),
                       TTPLAYER_SELFTEST="1", TTPLAYER_SILENT_OUTPUT="1",
                       TTPLAYER_TESTDIR=str(fixtures),
                       TTPLAYER_QT_STATE=str(Path(isolation)/suite/"state.json"))
            for key in list(env):
                if key.startswith("TTPLAYER_QT_") and key.endswith("_PROBE"): del env[key]
            env["TTPLAYER_QT_"+suite+"_PROBE"] = "1"
            if radio_mode:
                env["TTPLAYER_QT_RADIOLIVE_MODE"] = radio_mode
                env["TTPLAYER_QT_RADIOLIVE_STRESS"] = "30"
            start = time.monotonic()
            try:
                result = subprocess.run([binary], env=env, capture_output=True, text=True, timeout=120)
                output = result.stdout + result.stderr; code = result.returncode
            except subprocess.TimeoutExpired as error:
                output = "TIMEOUT\n" + str(error.stdout or ""); code = 124
            np = len(re.findall(r" PASS$", output, re.M)); nf = len(re.findall(r" FAIL(?:$|[ (])", output, re.M))
            ns = len(re.findall(r" SKIP(?:$|[ (])", output, re.M))
            if code or not (np or ns): nf = max(1, nf)
            if code: output += f"\nPROCESS_EXIT={code}\n"
            passed += np;failed += nf;skipped += ns
            label = suite + (":"+radio_mode if radio_mode else "")
            line = f"{label:<23} PASS={np} FAIL={nf} SKIP={ns} {time.monotonic()-start:.2f}s"
            print(line, flush=True);log.write(line+"\n"+output+"\n");log.flush()
            if nf: print(output, flush=True)
after = fingerprints()
if before != after:
    print("FAIL: user state/resume changed:", [p for p in before if before[p] != after[p]])
    failed += 1
print(f"PASS={passed} FAIL={failed} SKIP={skipped}; {report/'selftest.log'}")
sys.exit(1 if failed else 0)
