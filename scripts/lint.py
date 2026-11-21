#!/usr/bin/env python3
"""C++/Qt 代码检查入口：clang-format 管格式，clang-tidy 管缺陷。

默认只查「相对某个 git 基线的改动」，避免把历史格式差异一次挂红；
--all 才整仓检查（format --all 会把整仓重排，需明确要）。

工具版本固定在 18.1.8（与 CI ubuntu-24.04 自带 LLVM 18 对齐）：
    pip install clang-format==18.1.8 clang-tidy==18.1.8
也可用 CLANG_FORMAT / CLANG_TIDY 指向自备二进制。

用法：
    python3 scripts/lint.py format            # 改动行的格式检查
    python3 scripts/lint.py format --fix      # 就地把改动行排好
    python3 scripts/lint.py tidy              # 改动文件的静态检查（需 build/compile_commands.json）
    python3 scripts/lint.py all               # 两者都查
    python3 scripts/lint.py all --all         # 整仓（CI 就用这档）
    python3 scripts/lint.py all --base origin/main --build-dir build-ci
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
EXTS = {".cpp", ".h", ".mm"}
# 只约束产品源码：docs/ 是证据快照，3rd/ 是第三方。
SOURCE_DIRS = {"src"}
PINNED = "18.1.8"


def tool(name, env):
    path = os.environ.get(env) or shutil.which(name)
    if not path:
        sys.exit(f"找不到 {name}。装法：pip install clang-format=={PINNED} clang-tidy=={PINNED}"
                 f"（再用 {env} 指定路径也可）")
    return path


def version(path):
    out = subprocess.run([path, "--version"], text=True, capture_output=True).stdout
    return out.strip()


def check_major(path, name):
    line = version(path)
    major = line.split("version ")[-1].split(".")[0] if "version " in line else "?"
    if major != PINNED.split(".")[0]:
        # 容错不是宽容：格式规则按 18 写，换成别的版本会静默漂移（PATH 上装了
        # Homebrew 的 clang-format 就会遮蔽 venv 里的固定版），必须直接报错。
        sys.exit(f"{name} 版本不对：{line}；本项目固定 {PINNED}。"
                 f"装法：pip install clang-format=={PINNED} clang-tidy=={PINNED}"
                 f"（或用 {name.upper().replace('-', '_')} 指向该版本）")


def git(*args, check=True):
    return subprocess.run(["git", *args], text=True, capture_output=True, check=check)


def is_source(name):
    parts = Path(name).parts
    return bool(parts) and parts[0] in SOURCE_DIRS


def source_diagnostics(output):
    """整仓也只约束 src/；分析器不总是遵守 HeaderFilterRegex，编译错误仍全部保留。"""
    found = []
    for line in output.splitlines():
        if ": error:" in line:
            found.append(line)
            continue
        match = re.match(r"^(.*?):\d+:\d+: warning:", line)
        if not match:
            continue
        try:
            name = Path(match.group(1)).resolve().relative_to(ROOT)
        except ValueError:
            continue
        if is_source(str(name)):
            found.append(line)
    return found


def changed_files(base, include_untracked):
    """相对 base 的改动文件（重命名取新名、删除不计），只留 src/ 下的 C++ 源。"""
    diff = git("diff", "--name-only", "--diff-filter=ACMR", base, check=False)
    names = diff.stdout.splitlines() if diff.returncode == 0 else []
    if include_untracked:
        names += git("ls-files", "--others", "--exclude-standard").stdout.splitlines()
    return [n for n in dict.fromkeys(names)
            if Path(n).suffix in EXTS and is_source(n) and (ROOT / n).is_file()]


def added_ranges(base, name):
    """base→工作区这份文件新增/修改过的行号区间（1 基，含两端）。

    只排改动行、不整份重排，才能在不碰历史格式的前提下做增量门禁；
    git-clang-format 要求索引干净，这里自己拆 hunk，未暂存改动也不影响。
    """
    diff = git("diff", "-U0", "--no-color", base, "--", name, check=False)
    ranges = []
    for line in diff.stdout.splitlines():
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if not m:
            continue
        start = int(m.group(1))
        count = int(m.group(2)) if m.group(2) is not None else 1
        if count > 0:
            ranges.append((start, start + count - 1))
    return ranges


def formatted(fmt, name, ranges):
    """clang-format 只作用于给定行区间后的全文（bytes，避免编码来回转）。"""
    args = [fmt]
    if ranges:
        args += [f"--lines={start}:{end}" for start, end in ranges]
    args.append(name)
    return subprocess.run(args, capture_output=True, check=True).stdout


def format_check(base, fix, all_files):
    fmt = tool("clang-format", "CLANG_FORMAT")
    check_major(fmt, "clang-format")
    if all_files:
        files = [n for n in git("ls-files").stdout.splitlines()
                 if Path(n).suffix in EXTS and is_source(n)]
    else:
        files = changed_files(base, include_untracked=True)
    if not files:
        print("format: 没有需要检查的文件")
        return 0

    if all_files:
        if fix:
            fixed = []
            for name in files:
                if subprocess.run([fmt, "--dry-run", "--Werror", name],
                                  capture_output=True, check=False).returncode:
                    subprocess.run([fmt, "-i", name], check=True)
                    fixed.append(name)
            print(f"format: 已重排 {len(fixed)} 个文件")
            return 0
        bad = [name for name in files
               if subprocess.run([fmt, "--dry-run", "--Werror", name],
                                 capture_output=True, check=False).returncode != 0]
        if bad:
            print(f"format: {len(bad)}/{len(files)} 个文件不合规则：")
            for name in bad[:20]:
                print("  " + name)
            return 1
        print(f"format: {len(files)} 个文件全部合规")
        return 0

    untracked = set(git("ls-files", "--others", "--exclude-standard").stdout.splitlines())
    bad, touched = [], 0
    for name in files:
        ranges = [] if name in untracked else added_ranges(base, name)
        if name not in untracked and not ranges:
            continue          # 纯删除或没动到代码行
        touched += 1
        want = formatted(fmt, name, ranges)
        were = (ROOT / name).read_bytes()
        if want == were:
            continue
        bad.append(name)
        if fix:
            (ROOT / name).write_bytes(want)
    if bad:
        if fix:
            print(f"format: 已重排 {len(bad)} 个文件的改动行")
            return 0
        print(f"format: {len(bad)}/{touched} 个改动文件需要格式化：")
        for name in bad[:20]:
            print("  " + name)
        print("按提示改，或跑 python3 scripts/lint.py format --fix")
        return 1
    print(f"format: {touched} 个改动文件的改动行已合规")
    return 0


def compile_units(build_dir):
    db = ROOT / build_dir / "compile_commands.json"
    if not db.is_file():
        sys.exit(f"缺 {build_dir}/compile_commands.json。先跑：\n"
                 f"  cmake -S . -B {build_dir} -DCMAKE_BUILD_TYPE=Debug")
    units = {}
    for entry in json.loads(db.read_text()):
        file = Path(entry["file"]).resolve()
        # moc 产物目录是 `<target>_autogen`，按子串排除；只看产品源码
        if not any("autogen" in part for part in file.parts) and file.suffix in {".cpp", ".mm"}:
            units[file] = entry.get("directory", str(ROOT))
    return units


def tidy_check(base, all_files, fix, build_dir):
    tidy = tool("clang-tidy", "CLANG_TIDY")
    check_major(tidy, "clang-tidy")
    units = compile_units(build_dir)
    untracked = set()
    ranges = {}
    if all_files:
        files = sorted(units)
    else:
        changed = changed_files(base, include_untracked=True)
        untracked = set(git("ls-files", "--others", "--exclude-standard").stdout.splitlines())
        for name in changed:
            # 未跟踪的新文件整份算改动；其余按 hunk 的 + 行范围
            spans = [(1, 10**9)] if name in untracked else added_ranges(base, name)
            if spans:
                ranges[(ROOT / name).resolve()] = spans
        files = [f for f in (ROOT / n for n in changed) if f in units]
        # 只改头文件时，上面会落空；把 #include 到它的编译单元一并查（按文件名近似）。
        headers = [ROOT / n for n in changed if (ROOT / n).suffix == ".h"]
        for unit in sorted(units):
            if unit in files:
                continue
            text = unit.read_text(encoding="utf-8", errors="ignore")
            if any(f'"{header.name}"' in text for header in headers):
                files.append(unit)
    if not files:
        print("tidy: 没有可检查的编译单元")
        return 0

    def on_changed_line(line):
        """增量门禁：只看落在本次改动行上的告警，历史行不背债。"""
        m = re.match(r"^(.*?):(\d+):\d+: (?:warning|error):", line)
        if not m:
            return False
        path, row = Path(m.group(1)).resolve(), int(m.group(2))
        spans = ranges.get(path)
        if not spans:                      # 告警在未改动的包含头里
            return False
        return any(start <= row <= end for start, end in spans)

    warnings = []
    report = ROOT / build_dir / "lint"
    for index, file in enumerate(files, 1):
        args = [tidy, "-p", build_dir, "--quiet", str(file)] + (["--fix"] if fix else [])
        done = subprocess.run(args, text=True, capture_output=True, check=False)
        output = done.stdout + done.stderr
        trace = report / file.relative_to(ROOT).with_suffix(".log")
        trace.parent.mkdir(parents=True, exist_ok=True)
        trace.write_text(output)
        found = source_diagnostics(output)
        if not all_files:
            found = [line for line in found if on_changed_line(line)]
        if done.returncode and not found:
            # 工具崩溃/参数错误也必须挂，不能因没有标准 warning/error 行而误判通过。
            found.append(f"{file}: error: clang-tidy exited {done.returncode}; see {trace}")
        for line in found:
            print(line.replace(str(ROOT) + os.sep, ""))
        warnings += found
        if len(files) > 8:
            print(f"  [{index}/{len(files)}] {file.relative_to(ROOT)} {len(found)} 条", flush=True)
    scope = "全部行" if all_files else "改动行"
    if warnings:
        print(f"tidy: {len(warnings)} 条问题（{len(files)} 个编译单元，{scope}）")
        return 1
    print(f"tidy: {len(files)} 个编译单元的{scope}无告警")
    return 0


def main(argv):
    if not argv or argv[0] in {"-h", "--help"}:
        print(__doc__)
        return 0
    mode, rest = argv[0], argv[1:]
    if mode not in {"format", "tidy", "all"}:
        print(__doc__)
        return 2
    all_files = "--all" in rest
    fix = "--fix" in rest
    base = "HEAD"
    if "--base" in rest:
        base = rest[rest.index("--base") + 1]
    build_dir = "build"
    if "--build-dir" in rest:
        build_dir = rest[rest.index("--build-dir") + 1]
    # 新分支/浅克隆里 base 可能不存在：退回 HEAD~1，再不行按「全部文件」处理
    if not all_files and git("cat-file", "-e", base, check=False).returncode != 0:
        base = "HEAD~1" if git("cat-file", "-e", "HEAD~1", check=False).returncode == 0 else ""
        if not base:
            print("tidy: 找不到可比较的基线，改为整仓检查", file=sys.stderr)
            all_files = True
    code = 0
    if mode in {"format", "all"}:
        code |= format_check(base or "HEAD", fix, all_files)
    if mode in {"tidy", "all"}:
        code |= tidy_check(base or "HEAD", all_files, fix, build_dir)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
