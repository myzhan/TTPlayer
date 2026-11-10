// swift-tools-version:5.9
import PackageDescription
import Foundation

// FFmpeg 静态库由 scripts/build_ffmpeg.sh 从 3rd/ffmpeg 源码编译产出，
// 头与库分别落在 3rd/ffmpeg-build/{include,lib}。这里用绝对路径把编译/链接钉死，
// 避免依赖构建时的工作目录。
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ffmpegInclude = packageRoot + "/3rd/ffmpeg-build/include"
let ffmpegLib = packageRoot + "/3rd/ffmpeg-build/lib"

let package = Package(
    name: "TTPlayer",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // C 桥接层：把 FFmpeg 的公开头包成一个可被 Swift `import` 的模块。
        .target(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I" + ffmpegInclude])
            ]
        ),
        // libarchive 桥接：macOS SDK 只带 libarchive.tbd 不带头，
        // 签名在 Sources/CLibarchive/include/shim.h 手写一份。
        // 链接 -larchive 走 SDK 的 tbd 解析到 /usr/lib/libarchive.2.dylib。
        .target(
            name: "CLibarchive",
            path: "Sources/CLibarchive",
            publicHeadersPath: "include"
        ),
        // 入口为 Sources/TTPlayer/main.swift 的顶层代码
        .executableTarget(
            name: "TTPlayer",
            dependencies: ["CFFmpeg", "CLibarchive"],
            path: "Sources/TTPlayer",
            swiftSettings: [
                // cSettings 的 -I 只作用于 CFFmpeg 自身源码的编译；Swift `import CFFmpeg`
                // 走的是 clang importer，需要额外用 -Xcc 把 FFmpeg 头路径传给它，
                // 否则 umbrella header 里的 <libavutil/...> 找不到。
                .unsafeFlags(["-Xcc", "-I" + ffmpegInclude])
            ],
            linkerSettings: [
                // 静态链接顺序按依赖：avformat → avcodec → swresample → avutil。
                // 外加 FFmpeg .pc 里声明的系统依赖：-lz -lm 与三个 framework。
                .unsafeFlags([
                    "-L" + ffmpegLib,
                    "-lavformat", "-lavcodec", "-lswresample", "-lavutil",
                    "-lz", "-lm", "-lpthread",
                    "-framework", "CoreFoundation",
                    "-framework", "CoreVideo",
                    "-framework", "CoreMedia",
                    // libarchive 系统 dylib（macOS 11+ 都在），shim.h 手写声明靠它提供实现。
                    "-larchive"
                ])
            ]
        )
    ]
)
