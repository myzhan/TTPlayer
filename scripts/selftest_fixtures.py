"""在隔离的自检目录里生成短小、确定性的音频素材。"""
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import wave
import zipfile

DSD_RATE = 2_822_400


def dsd_samples(target):
    """二阶噪声整形的 1 bit 流，同时写成 DSF 与 DFF（同一份采样）。"""
    rate = DSD_RATE
    bits = bytearray(rate // 8)
    e1 = e2 = previous = 0.0
    for i in range(rate):
        sample = 0.3 * math.sin(i * 2 * math.pi * 440 / rate)
        e1 += sample - previous
        e2 += e1 - previous
        previous = 1.0 if e2 >= 0 else -1.0
        if previous > 0:
            bits[i // 8] |= 1 << (i % 8)
    # 每 4096 字节补齐后重复一次，凑出 DSF 块对齐的负载。
    data = b"".join(bytes(bits[i:i + 4096]).ljust(4096, b"\0") * 2
                    for i in range(0, len(bits), 4096))

    fmt = b"fmt " + struct.pack("<QIIIIIIQII", 52, 1, 0, 2, 2, rate, 1, rate, 4096, 0)
    payload = fmt + b"data" + struct.pack("<Q", 12 + len(data)) + data
    (target / "dsd.dsf").write_bytes(b"DSD " + struct.pack("<QQQ", 28, 28 + len(payload), 0) + payload)

    def chunk(name, body):
        padding = b"\0" if len(body) % 2 else b""
        return name + struct.pack(">Q", len(body)) + body + padding

    properties = (b"SND " + chunk(b"FS  ", struct.pack(">I", rate))
                  + chunk(b"CHNL", struct.pack(">H", 2) + b"SLFTSRGT")
                  + chunk(b"CMPR", b"DSD " + bytes([14]) + b"not compressed"))
    reverse = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
    msb = bits.translate(reverse)
    interleaved = bytes(value for byte in msb for value in (byte, byte))
    payload = (b"DSD " + chunk(b"FVER", struct.pack(">I", 0x01050000))
               + chunk(b"PROP", properties) + chunk(b"DSD ", interleaved))
    (target / "dsd.dff").write_bytes(b"FRM8" + struct.pack(">Q", len(payload)) + payload)


def generate(folder: Path, matrix: bool, lyrics: bool = False):
    """folder 下生成曲库；按需补编码矩阵与内嵌歌词素材。"""
    folder.mkdir(parents=True, exist_ok=True)
    for name, seconds, hz in [("demo01.wav", 12, 880), ("demo02.wav", 10, 440)]:
        with wave.open(str(folder / name), "wb") as output:
            output.setnchannels(2)
            output.setsampwidth(2)
            output.setframerate(44100)
            one_second = b"".join(struct.pack("<hh", value, value) for value in
                                  (int(math.sin(i * 2 * math.pi * hz / 44100) * 8000) for i in range(44100)))
            output.writeframes(one_second * seconds)

    (folder / "art").mkdir(exist_ok=True)
    for name in ["single.wav", "coverless.wav"]:
        shutil.copyfile(folder / "demo01.wav", folder / "art" / name)
    (folder / "cuealbum.cue").write_text(
        'PERFORMER "TestArtist"\nTITLE "TestAlbum"\nFILE "demo01.wav" WAVE\n'
        'TRACK 01 AUDIO\nTITLE "Track One"\nINDEX 01 00:00:00\n'
        'TRACK 02 AUDIO\nTITLE "Track Two"\nINDEX 01 00:04:00\n'
        'TRACK 03 AUDIO\nTITLE "Track Three"\nINDEX 01 00:08:30\n')
    (folder / "demo01.lrc").write_text('[00:01.00]第一句\n[00:02.50]第二句\n', encoding="utf-8")

    with zipfile.ZipFile(folder / "demo_archive.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(folder / "demo01.wav", "disc/one.wav")
        archive.write(folder / "demo02.wav", "disc/two.wav")
    for suffix, mode in [("tar", "w"), ("tar.gz", "w:gz"), ("tar.bz2", "w:bz2")]:
        with tarfile.open(folder / ("archive." + suffix), mode) as archive:
            archive.add(folder / "demo01.wav", arcname="中文 disc/one.wav")

    encoder = shutil.which("ffmpeg")
    if not encoder:
        raise RuntimeError("selftest requires FFmpeg CLI to generate independent encoded fixtures")

    def encode(destination, codec, container=None, extra=()):
        args = [encoder, "-nostdin", "-v", "error", "-y", "-i", str(folder / "demo01.wav"), "-t", "1", "-c:a", codec]
        args += ["-metadata", "title=Encoded title", "-metadata", "artist=Encoded artist",
                 "-metadata", "album=Encoded album",
                 "-metadata", "replaygain_track_gain=-6 dB", "-metadata", "replaygain_track_peak=0.8"]
        if container:
            args += ["-f", container]
        result = subprocess.run(args + list(extra) + [str(destination)], capture_output=True, text=True)
        return result.returncode == 0

    if not encode(folder / "cover.flac", "flac", extra=["-t", "12"]):
        raise RuntimeError("cannot generate FLAC")
    if lyrics:
        target = folder / "embedded"
        target.mkdir(exist_ok=True)
        if not encode(target / "bare.mp3", "libmp3lame", "mp3", extra=["-t", "4", "-id3v2_version", "0"]):
            raise RuntimeError("cannot generate embedded lyrics MP3")
        audio = (target / "bare.mp3").read_bytes()

        def synchsafe(size):
            return bytes((size >> shift) & 0x7f for shift in (21, 14, 7, 0))

        def uslt(name, text, version, utf16):
            # 直接写标准 USLT 帧，避免把 FFmpeg 的 TXXX=lyrics 误当作 USLT 验证。
            if utf16:
                payload = b"\x01eng\xff\xfe\0\0" + text.encode("utf-16")
            else:
                payload = b"\x03eng\0" + text.encode("utf-8")
            size = len(payload)
            frame = b"USLT" + (synchsafe(size) if version == 4 else struct.pack(">I", size)) + b"\0\0" + payload
            (target / name).write_bytes(b"ID3" + bytes([version, 0, 0]) + synchsafe(len(frame)) + frame + audio)

        timed = "[offset:100]\n[00:00.50]内嵌第一句\n[00:01.00]内嵌第二句\n"
        plain = "\n".join(f"纯文本歌词第 {i} 行" for i in range(1, 81))
        uslt("timed.mp3", timed, 3, True)
        uslt("plain.mp3", plain, 4, False)
        uslt("empty.mp3", " \r\n ", 4, False)
        for name in ("timed", "plain", "empty", "bare"):
            (target / (name + ".lrc")).write_text("[00:00.25]外置歌词\n", encoding="utf-8")
        for name, codec in (("tag.flac", "flac"), ("tag.m4a", "aac"), ("tag.ogg", "libopus")):
            if not encode(target / name, codec, extra=["-metadata", "lyrics=" + timed]):
                raise RuntimeError("cannot generate embedded lyrics fixture: " + name)
        with zipfile.ZipFile(target / "lyrics.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(target / "timed.mp3", "disc/timed.mp3")

    if not matrix:
        return

    target = folder / "formats"
    target.mkdir(exist_ok=True)
    dsd_samples(target)
    # 播放断续回归：保留完整 12 秒，覆盖真实 producer 的多次 2048 帧顺序读取。
    if not encode(target / "mp3-320.mp3", "libmp3lame", "mp3", extra=["-b:a", "320k", "-t", "12"]):
        raise RuntimeError("cannot generate 320Kbps MP3 regression fixture")

    skipped = []
    monkey = shutil.which("mac")
    if monkey:
        subprocess.run([monkey, str(folder / "demo01.wav"), str(target / "monkey.ape"), "-c1000"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        skipped.append("APE: Monkey's Audio encoder unavailable")
    seven = shutil.which("7z") or shutil.which("7zz")
    if seven:
        subprocess.run([seven, "a", "-y", str(folder / "archive.7z"), str(folder / "demo01.wav")],
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run([seven, "a", "-y", "-psecret", str(folder / "encrypted.zip"), str(folder / "demo01.wav")],
                       check=True, stdout=subprocess.DEVNULL)
    else:
        skipped.append("7z and encrypted ZIP: generator unavailable")
    variants = [("mp3.mp3", "libmp3lame", "mp3"), ("aac.aac", "aac", "adts"), ("flac.flac", "flac", "flac"),
                ("alac.m4a", "alac", "ipod"), ("aac.m4a", "aac", "ipod"), ("vorbis.ogg", "vorbis", "ogg"),
                ("opus.ogg", "libopus", "ogg"),
                ("s8.au", "pcm_s8", "au"), ("u8.wav", "pcm_u8", "wav"), ("s16.wav", "pcm_s16le", "wav"),
                ("s24.wav", "pcm_s24le", "wav"), ("s32.wav", "pcm_s32le", "wav"), ("f32.wav", "pcm_f32le", "wav"),
                ("f64.wav", "pcm_f64le", "wav"), ("s16.aiff", "pcm_s16be", "aiff"), ("s24.aiff", "pcm_s24be", "aiff"),
                ("s32.aiff", "pcm_s32be", "aiff"), ("alaw.wav", "pcm_alaw", "wav"), ("mulaw.wav", "pcm_mulaw", "wav"),
                ("ima.aifc", "adpcm_ima_qt", "aiff"), ("pcm.caf", "pcm_s16le", "caf"), ("pcm.w64", "pcm_s16le", "w64"),
                ("tta.tta", "tta", None), ("wavpack.wv", "wavpack", None), ("wma.wma", "wmav2", "asf"),
                ("layer2.mp2", "mp2", "mp2"), ("core.dts", "dca", "dts"),
                ("dolby.ac3", "ac3", "ac3"), ("dolby.eac3", "eac3", "eac3"),
                ("lossless.mlp", "mlp", "mlp"), ("lossless.thd", "truehd", "truehd"),
                ("surround.wav", "pcm_s24le", "wav"), ("hires.wav", "pcm_s24le", "wav")]
    for name, codec, container in variants:
        if name == "surround.wav":
            extra = ["-ac", "6", "-ar", "48000"]
        elif name == "hires.wav":
            extra = ["-ar", "96000"]
        else:
            extra = []
        if codec in {"vorbis", "dca", "mlp", "truehd"}:
            extra += ["-strict", "-2"]
        if codec in {"dca", "mlp", "truehd"}:
            extra += ["-ar", "48000"]
        if not encode(target / name, codec, container, extra):
            raise RuntimeError("required fixture encoder unavailable: " + name)

    # 系统 CLI 不一定带 AMR 编码器；失败产物不留在真实解码矩阵里。
    amr = target / "speech.amr"
    if not encode(amr, "libopencore_amrnb", "amr", ["-ar", "8000", "-ac", "1", "-t", "2"]):
        amr.unlink(missing_ok=True)
        skipped.append("AMR-NB: fixture encoder unavailable")
    # FFmpeg 没有这些编码器：只验注册能力，不冒充真实文件解码覆盖。
    for name in ("WMA Pro", "WMA Lossless", "WMA Voice", "DTS-HD", "Musepack SV7", "Musepack SV8",
                 "TAK", "Shorten", "MP1", "AMR-WB"):
        skipped.append(name + ": fixture encoder unavailable; registration only")
    (folder / "fixture-skips.json").write_text(json.dumps(skipped))


if __name__ == "__main__":
    generate(Path(sys.argv[1]), True)
    for reason in json.loads((Path(sys.argv[1]) / "fixture-skips.json").read_text()):
        print("FIXTURE SKIP", reason)
