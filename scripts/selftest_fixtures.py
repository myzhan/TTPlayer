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


def sequence_samples(folder):
    """现场生成 SMF 与四种各自有真实采样的模块，不依赖外部曲目或改后缀。"""
    folder.mkdir(parents=True, exist_ok=True)

    def vlq(number):
        data = [number & 127]
        while number > 127:
            number >>= 7
            data.insert(0, (number & 127) | 128)
        return bytes(data)

    def event(delta, data):
        return vlq(delta) + data

    def meta(delta, kind, data):
        return event(delta, bytes([255, kind]) + vlq(len(data)) + data)

    def smf(tracks, division=480, fmt=None):
        return (b"MThd" + struct.pack(">IHHH", 6, int(len(tracks) > 1) if fmt is None else fmt, len(tracks), division)
                + b"".join(b"MTrk" + struct.pack(">I", len(track)) + track for track in tracks))

    end = meta(0, 47, b"")
    notes = (meta(0, 3, "序列测试".encode()) + event(0, b"\xc0\x00")
             + event(0, b"\xb0\x0a\x10") + event(0, b"\x90\x3c\x64")
             + event(240, b"\xb0\x40\x7f") + event(240, b"\x80\x3c\x00")
             + event(480, b"\xb0\x40\x00") + event(480, b"\x90\x40\x00") + end)
    midi = smf([notes])
    (folder / "旋律.MID").write_bytes(midi)
    tempo = meta(0, 81, bytes.fromhex("07a120")) + meta(480, 81, bytes.fromhex("0f4240")) + meta(960, 47, b"")
    (folder / "tempo.midi").write_bytes(smf([tempo, notes]))
    for fps in (24, 25, 29, 30):
        track = event(0, b"\x90\x3c\x64") + event(fps * 40, b"\x80\x3c\x00") + end
        (folder / f"smpte{fps}.mid").write_bytes(smf([track], ((256 - fps) << 8) | 40))
    words = (meta(0, 1, b"@KMIDI KARAOKE FILE") + meta(0, 5, "/第一句".encode())
             + meta(480, 5, "/第二句".encode()) + meta(960, 47, b""))
    (folder / "words.kar").write_bytes(smf([notes, words]))
    body = b"RMIDdata" + struct.pack("<I", len(midi)) + midi + (b"\0" if len(midi) & 1 else b"")
    (folder / "rmid.mid").write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
    (folder / "running.mid").write_bytes(smf([event(0, b"\x90\x3c\x64") + event(480, b"\x3c\x00") + end]))
    for name, channel, program, bank in (("piano", 0, 0, 0), ("strings", 0, 48, 0),
                                         ("drums", 9, 0, 0), ("bank", 0, 0, 1)):
        track = (event(0, bytes([0xb0 | channel, 0, bank])) + event(0, bytes([0xc0 | channel, program]))
                 + event(0, bytes([0x90 | channel, 60, 100])) + event(960, bytes([0x80 | channel, 60, 0])) + end)
        (folder / f"{name}.mid").write_bytes(smf([track]))
    for seconds in (300, 1800):
        track = (event(0, b"\xc0\x30") + event(0, b"\x90\x3c\x64")
                 + event(seconds * 960, b"\x80\x3c\0") + end)
        (folder / f"long{seconds}.mid").write_bytes(smf([track]))
    (folder / "format2.mid").write_bytes(smf([notes], fmt=2))
    (folder / "truncated.mid").write_bytes(midi[:-3])
    (folder / "badvlq.mid").write_bytes(smf([b"\x81\x81\x81\x81\x00\x90\x3c\x64" + end]))
    (folder / "device.mid").write_bytes(smf([event(0, b"\xf0\x04\x41\x10\x16\xf7") + end]))
    (folder / "ports.mid").write_bytes(smf([meta(0, 33, b"\x01") + end]))
    (folder / "eventlimit.mid").write_bytes(smf([event(0, b"\xc0\0") * 1000000 + end]))
    (folder / "timelimit.mid").write_bytes(smf([event(0x0fffffff, b"\x90\x3c\x64") + end], division=1))
    (folder / "stable.mid").write_bytes(smf([event(0, b"\xc0\x30") + end, event(0, b"\x90\x3c\x64") + end]))
    resets = b"".join(event(0, b"\xf0" + vlq(len(payload)) + payload) for payload in
                      (bytes.fromhex("7e7f0901f7"), bytes.fromhex("4110421240007f0041f7"),
                       bytes.fromhex("43104c00007e00f7"), bytes.fromhex("7d01f7")))
    (folder / "reset.mid").write_bytes(smf([resets + end]))
    (folder / "legacy.kar").write_bytes(smf([meta(0, 1, b"@TLegacy")
                                            + meta(0, 1, "/中文".encode("gb18030"))
                                            + meta(6000 * 960, 1, "/晚句".encode("gb18030")) + end]))
    (folder / "旋律.lrc").write_text("[00:00.10]外置回退\n", encoding="utf-8")
    (folder / "words.lrc").write_text("[00:00.10]不应覆盖内嵌词\n", encoding="utf-8")

    sample = bytes(int(70 * math.sin(i * 2 * math.pi / 32)) & 255 for i in range(256))
    mod = bytearray(1084 + 1024)
    mod[:20] = b"Generated MOD".ljust(20, b"\0")
    mod[20:50] = b"sine".ljust(22, b"\0") + struct.pack(">HBBHH", 128, 0, 64, 0, 128)
    mod[950], mod[951] = 1, 127
    mod[1080:1084] = b"M.K."
    for row, period in ((0, 428), (16, 339)):
        mod[1084 + row * 16:1088 + row * 16] = bytes([period >> 8, period & 255, 0x10, 0])
    mod[1084 + 32 * 16:1088 + 32 * 16] = b"\0\0\x0b\0"
    (folder / "sample.mod").write_bytes(mod + sample)

    xm = (b"Extended Module: " + b"Generated XM".ljust(20, b"\0") + b"\x1a"
          + b"TTPlayer fixture".ljust(20, b"\0") + struct.pack("<HI8H", 0x104, 276, 1, 0, 2, 1, 1, 1, 6, 125)
          + bytes(256))
    pattern = bytearray(32 * 2 * 5)
    pattern[:5] = bytes([49, 1, 0, 0, 0])
    pattern[160:165] = bytes([53, 1, 0, 0, 0])
    instrument = bytearray(263)
    struct.pack_into("<I", instrument, 0, 263)
    instrument[4:26] = b"sine".ljust(22, b"\0")
    struct.pack_into("<HI", instrument, 27, 1, 40)
    sample_header = struct.pack("<IIIBbBBbB", 256, 0, 256, 64, 0, 1, 128, 0, 0) + b"sine".ljust(22, b"\0")
    delta = bytes((value - (sample[i - 1] if i else 0)) & 255 for i, value in enumerate(sample))
    (folder / "sample.xm").write_bytes(xm + struct.pack("<IBHH", 9, 0, 32, len(pattern))
                                        + pattern + instrument + sample_header + delta)

    s3m = bytearray(192)
    s3m[:28] = b"Generated S3M".ljust(28, b"\0")
    s3m[28:32] = b"\x1a\x10\0\0"
    struct.pack_into("<6H", s3m, 32, 2, 1, 1, 0, 0x1320, 1)
    s3m[44:48] = b"SCRM"
    s3m[48:54] = bytes([64, 6, 125, 0xb0, 0, 0])
    s3m[64:96] = bytes([0, 8] + [255] * 30)
    s3m[96:98] = bytes([0, 255])
    struct.pack_into("<HH", s3m, 98, 7, 12)
    packed = bytearray()
    for row in range(64):
        if row in (0, 16): packed += bytes([0x20, 0x40 if row == 0 else 0x44, 1])
        if row == 32: packed += bytes([0x80, 2, 0])
        packed += b"\0"
    s3m += struct.pack("<H", len(packed) + 2) + packed
    s3m += bytes((-len(s3m)) % 16)
    sample_pos = len(s3m)
    s3m[112] = 1
    struct.pack_into("<H", s3m, 126, sample_pos // 16)
    struct.pack_into("<III", s3m, 128, 256, 0, 256)
    s3m[140], s3m[143] = 64, 1
    struct.pack_into("<I", s3m, 144, 8363)
    s3m[160:188] = b"sine".ljust(28, b"\0")
    s3m[188:192] = b"SCRS"
    (folder / "sample.s3m").write_bytes(s3m + sample)

    it = bytearray(288)
    it[:4] = b"IMPM"
    it[4:30] = b"Generated IT".ljust(26, b"\0")
    struct.pack_into("<8H", it, 32, 2, 0, 1, 1, 0x214, 0x214, 1, 0)
    it[48:54] = bytes([128, 48, 6, 125, 128, 0])
    it[64:128] = bytes([16, 48] + [128] * 62)
    it[128:192] = bytes([64] * 64)
    it[192:194] = bytes([0, 255])
    struct.pack_into("<II", it, 194, 208, 288)
    packed = bytearray()
    for row in range(64):
        if row in (0, 16): packed += bytes([0x81, 3, 60 if row == 0 else 64, 1])
        if row == 32: packed += bytes([0x81, 8, 2, 0])
        packed += b"\0"
    it += struct.pack("<HHI", len(packed), 64, 0) + packed
    it[208:212] = b"IMPS"
    it[225:228] = bytes([64, 0x11, 64])
    it[228:254] = b"sine".ljust(26, b"\0")
    it[254] = 1
    struct.pack_into("<7I", it, 256, 256, 0, 256, 8363, 0, 0, len(it))
    (folder / "sample.it").write_bytes(it + sample)
    for extension in ("mod", "xm", "s3m", "it"):
        (folder / f"bad.{extension}").write_bytes((folder / f"sample.{extension}").read_bytes()[:50])
    with zipfile.ZipFile(folder / "sequences.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for name in ("旋律.MID", "words.kar", "sample.mod", "sample.xm", "sample.s3m", "sample.it"):
            archive.write(folder / name, "中文/" + name)


def generate(folder: Path, matrix: bool, lyrics: bool = False, sequenced: bool = False):
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

    if sequenced:
        sequence_samples(folder / "sequences")
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
    generate(Path(sys.argv[1]), True, lyrics=True, sequenced=True)
    for reason in json.loads((Path(sys.argv[1]) / "fixture-skips.json").read_text()):
        print("FIXTURE SKIP", reason)
