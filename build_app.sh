#!/bin/zsh
# 构建并打包 TTPlayer.app
set -e
cd "$(dirname "$0")"

CONF=release
# 架构：默认只编本机架构（开发机跑起来最快）；发版要一份通用二进制就传
# TTPLAYER_ARCHS="arm64 x86_64"——交叉编译在本机就能做，不必去借别人的机器
ARCH_ARGS=()
if [[ -n "$TTPLAYER_ARCHS" ]]; then
    for a in ${=TTPLAYER_ARCHS}; do ARCH_ARGS+=(--arch "$a"); done
fi

# 前置：解码已全部交给 FFmpeg，静态库必须先编好（Package.swift 直接链 3rd/ffmpeg-build/lib）。
# 没 submodule / 没产物就给一句话指引，别把错误拖到 swift build 的链接阶段。
if [[ ! -f 3rd/ffmpeg-build/lib/libavformat.a ]]; then
    echo "→ 未找到 FFmpeg 静态库，先跑 scripts/build_ffmpeg.sh 编一份"
    zsh scripts/build_ffmpeg.sh
fi

swift build -c $CONF "${ARCH_ARGS[@]}"
BIN=$(swift build -c $CONF "${ARCH_ARGS[@]}" --show-bin-path)

# 版本号：CI 传 tag（v1.16 → 1.16），本地打包就是 1.0
VER=${TTPLAYER_VERSION:-1.0}
BUILD_VER=${TTPLAYER_BUILD:-1}

APP=build/TTPlayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TTPlayer" "$APP/Contents/MacOS/TTPlayer"

# 图标由程序自己画（--export-icon 无头跑一趟），仓库里不入库二进制资源
ICONSET="$APP/Contents/Resources/AppIcon.iconset"
"$APP/Contents/MacOS/TTPlayer" --export-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# 文档类型里的扩展名跟着运行面白名单走（向 CoreAudio 现场问出来的），不在脚本里手抄；
# 问不到东西时兜底回最早那批，免得打包产物连 mp3 都不认
FORMATS="$("$APP/Contents/MacOS/TTPlayer" --dump-formats || true)"
[ -n "$FORMATS" ] || FORMATS="mp3 m4a mp4 aac flac wav aiff aif caf cue m3u m3u8"
EXT_XML=""
for e in ${=FORMATS}; do
    EXT_XML+="            <string>$e</string>
"
done

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TTPlayer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.retro.ttplayer</string>
    <key>CFBundleName</key>
    <string>千千静听 复刻版</string>
    <key>CFBundleDisplayName</key>
    <string>千千静听 复刻版</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VER}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 网络电台：国内电台绝大多数是明文 http 的 Icecast/Shoutcast，
         ATS 默认拦明文请求，不放开这条流根本拉不下来 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSAppleMusicUsageDescription</key>
    <string>用于播放本地音乐文件</string>
    <key>CFBundleDocumentTypes</key>
    <array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>音频、歌单与分轨表</string>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>public.audio</string>
            <string>public.mp3</string>
            <string>public.mp2</string>
            <string>public.mpeg-4-audio</string>
            <string>com.apple.m4a-audio</string>
            <string>public.aac-audio</string>
            <string>public.mp4a-loas</string>
            <string>org.xiph.flac</string>
            <string>org.xiph.opus</string>
            <string>com.microsoft.waveform-audio</string>
            <string>com.sony.wave64</string>
            <string>public.aiff-audio</string>
            <string>public.aifc-audio</string>
            <string>com.apple.coreaudio-format</string>
            <string>public.au-audio</string>
            <string>com.digidesign.sd2-audio</string>
            <string>public.ac3-audio</string>
            <string>public.enhanced-ac3-audio</string>
            <string>org.3gpp.adaptive-multi-rate-audio</string>
            <string>public.m3u-playlist</string>
        </array>
        <key>CFBundleTypeExtensions</key>
        <array>
${EXT_XML}        </array>
    </dict>
    </array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" 2>/dev/null || echo "（跳过代码签名）"

# 同路径重建的 bundle 会命中 LaunchServices 的旧图标缓存，强制重新登记一次
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -f "$APP" 2>/dev/null || echo "（跳过 LaunchServices 重新登记）"
echo "打包完成：$APP"
