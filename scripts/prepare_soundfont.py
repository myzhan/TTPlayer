#!/usr/bin/env python3
"""准备固定版本的默认音色；只读取数据包，不安装或执行其中任何程序。"""
import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import tarfile
import tempfile
import urllib.request

URL = ("https://deb.debian.org/debian/pool/main/f/fluidr3mono-gm-soundfont/"
       "fluidr3mono-gm-soundfont_2.315-7_all.deb")
SIZE = 18726092
SHA256 = "4098301bf29f4253c2f5799a844f42dd4aa733d91a210071ad16d7757dea51d6"
MEMBERS = {
    "usr/share/fluidr3mono-gm-soundfont/FluidR3Mono_GM.sf3": "FluidR3Mono_GM.sf3",
    "usr/share/doc/fluidr3mono-gm-soundfont/copyright": "FluidR3Mono-LICENSE.txt",
}


def verified(path):
    if not path.is_file() or path.stat().st_size != SIZE:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return digest.hexdigest() == SHA256


def data_archive(package):
    """严格解析 Debian ar 外壳，不解析/运行 control 包。"""
    with package.open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            raise ValueError("音色包不是 ar 文件")
        seen = set()
        payload = None
        while header := stream.read(60):
            if len(header) != 60 or header[58:] != b"`\n":
                raise ValueError("音色包 ar 头损坏")
            name = header[:16].decode("ascii").strip().rstrip("/")
            length = int(header[48:58])
            if name in seen or length < 0 or length > SIZE:
                raise ValueError("音色包包含重复或超限成员")
            seen.add(name)
            content = stream.read(length)
            if len(content) != length:
                raise ValueError("音色包被截断")
            if length % 2 and stream.read(1) != b"\n":
                raise ValueError("音色包 ar 填充损坏")
            if name in ("data.tar.xz", "data.tar.gz", "data.tar"):
                if payload is not None:
                    raise ValueError("音色包包含多个数据档案")
                payload = content
            elif name not in ("debian-binary", "control.tar.xz", "control.tar.gz"):
                raise ValueError(f"未知的音色包成员：{name}")
        if payload is None:
            raise ValueError("音色包缺少数据档案")
        return payload


def prepare(folder):
    folder.mkdir(parents=True, exist_ok=True)
    package = folder / "fluidr3mono-gm-soundfont_2.315-7_all.deb"
    # 已有但校验失败的缓存不能被当作有效音色，也不悄悄覆盖现场。
    if package.exists() and not verified(package):
        raise ValueError(f"音色缓存校验失败：{package}")
    with tempfile.TemporaryDirectory(prefix="soundfont-", dir=folder) as scratch:
        scratch = Path(scratch)
        if not package.exists():
            download = scratch / "download.deb"
            with urllib.request.urlopen(URL, timeout=60) as response, download.open("wb") as output:
                total = 0
                while block := response.read(65536):
                    total += len(block)
                    if total > SIZE:
                        raise ValueError("下载的音色包超出固定大小")
                    output.write(block)
            if not verified(download):
                raise ValueError("下载的音色包大小或 SHA-256 不匹配")
            download.replace(package)
        found = set()
        seen = set()
        total = 0
        with tarfile.open(fileobj=io.BytesIO(data_archive(package)), mode="r:*") as archive:
            for member in archive:
                name = member.name.removeprefix("./")
                path = PurePosixPath(name)
                if path.is_absolute() or ".." in path.parts or name in seen:
                    raise ValueError("音色包包含不安全或重复路径")
                seen.add(name)
                total += member.size
                if member.size < 0 or total > 64 * 1024 * 1024 or len(seen) > 256:
                    raise ValueError("音色包解压大小或成员数量超限")
                if not (member.isdir() or member.isfile()):
                    # Debian 附带默认音色别名链接；不提取、不跟随任何链接。
                    if name in MEMBERS:
                        raise ValueError(f"所需音色成员是链接或特殊文件：{name} -> {member.linkname}")
                    continue
                if name not in MEMBERS:
                    continue
                if not member.isfile():
                    raise ValueError("所需音色成员不是普通文件")
                with archive.extractfile(member) as source:
                    content = source.read(32 * 1024 * 1024 + 1)
                if len(content) != member.size:
                    raise ValueError("音色数据长度错误")
                target = scratch / MEMBERS[name]
                target.write_bytes(content)
                found.add(name)
        if found != set(MEMBERS):
            raise ValueError(f"音色包缺少所需成员：{set(MEMBERS) - found}")
        for filename in MEMBERS.values():
            source, target = scratch / filename, folder / filename
            # 保留未改变资源的 mtime，避免每次配置都重新运行 rcc。
            if not target.exists() or target.read_bytes() != source.read_bytes():
                source.replace(target)
    print(f"默认音色已校验：{folder / 'FluidR3Mono_GM.sf3'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "build/assets")
    args = parser.parse_args()
    prepare(args.output)
