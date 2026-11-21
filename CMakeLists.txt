# TTPlayer Qt6 —— 跨平台重构（C++20 + Qt Widgets + FFmpeg 静态库 + SDL3 输出）
#
# 工程代码在 src/，CMakeLists.txt 在仓库根。
# 解码层沿用 3rd/ffmpeg-build 的静态库（同一份产物、同一套链接顺序：avformat → avcodec → swresample → avutil）。
# libarchive 稳定子集声明已搬进 src/clibarchive/include。
# 输出层：设备 IO 用 SDL3（mac=CoreAudio/win=WASAPI/linux=ALSA），EQ/fade/频谱在回调里自绘。
#
# 构建产物统一在 build/（Debug 用 build/、Release 用 build/release/、打包用 build/package/ 与 build/dist/）。
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build
cmake_minimum_required(VERSION 3.21)

# macOS：两个环境层面的坑必须在这里先铺平，否则 fresh configure 会编译失败（不依赖手摇 flag）：
#  1) 显式 -isysroot：/usr/bin/c++ 包装器不拿 sysroot 时，C++ 标准库的 feature-test 宏
#     （<version>）解析会飘，Qt 6.9 的 Q_DECLARE_STRONGLY_ORDERED / Qt::compareThreeWay
#     被当成未启用，qstring.h 整片报错。xcrun --show-sdk-path 尊重本机 xcode-select 的指向。
#  2) 部署目标为 12.0；所选 Qt/SDL 依赖必须同样支持 12.0，不能提高门槛迁就 bottle。
# 两者都只在外部未指定时给默认，可用 -DCMAKE_OSX_SYSROOT / -DCMAKE_OSX_DEPLOYMENT_TARGET 覆盖。
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "minimum macOS deployment target" FORCE)
endif()
if(APPLE AND NOT CMAKE_OSX_SYSROOT)
  execute_process(COMMAND xcrun --show-sdk-path OUTPUT_VARIABLE _mac_sdk
                  OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  if(_mac_sdk)
    set(CMAKE_OSX_SYSROOT "${_mac_sdk}" CACHE PATH "macOS SDK path" FORCE)
  endif()
endif()

project(TTPlayer LANGUAGES C CXX)

# 给 IDE / clang-tidy 留编译数据库（只写进构建目录，不进仓）。
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# 可选：构建时顺带跑 clang-tidy。默认关——它比编译慢一个量级，
# 日常用 scripts/lint.py 只查改动文件，CI 也只查本次改动。
option(TTPLAYER_CLANG_TIDY "构建时执行 clang-tidy（需自行安装）" OFF)
if(TTPLAYER_CLANG_TIDY)
  find_program(TTPLAYER_CLANG_TIDY_EXE NAMES clang-tidy)
  if(TTPLAYER_CLANG_TIDY_EXE)
    set(CMAKE_CXX_CLANG_TIDY "${TTPLAYER_CLANG_TIDY_EXE}")
  else()
    message(WARNING "TTPLAYER_CLANG_TIDY=ON 但没找到 clang-tidy，已跳过")
  endif()
endif()

# .mm（ObjC++）/ .m（ObjC）是产品与 vendored SDL3 的源码：必须在 add_subdirectory(3rd/*) 之前启用。
# 子目录在生成阶段会用到各语言的 compile 规则变量，后启用会让那些 target 的生成失败；
# 只开 OBJCXX 不开 OBJC 时，CMake 会把 SDL 的 .m 当 ObjC++ 编，反带上 -std=c++20 而报错。
if(APPLE)
  enable_language(OBJC)
  enable_language(OBJCXX)
endif()

# 全工程统一 C++20：标准只在这两组变量里定义，其他地方不再手写 -std，
# 要升级语言水平只改这里。EXTENSIONS OFF = 用 -std=c++20，不开 gnu 扩展。
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# .mm（ObjC++）的标准是独立变量，必须同档设置；漏了就只有它一个文件掉到低标准。
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets Gui Core Network Core5Compat Concurrent Sql)
find_package(Threads REQUIRED)

# GB18030/GBK 使用必需的 Core5Compat QTextCodec。

# macOS 26 的 Command Line Tools SDK 移除了 AGL.framework，但 Homebrew Qt 的
# FindWrapOpenGL.cmake 在 find_library(AGL) 失败后仍硬塞 "-framework AGL" 作兜底，
# 顺着 Qt6::Gui → WrapOpenGL::WrapOpenGL 传下来会让链接找不到 AGL 而失败。
# 这里把 AGL 从该 interface target 的链接接口里剔掉（不去改 Homebrew 的 Qt）。
if(APPLE AND TARGET WrapOpenGL::WrapOpenGL)
  get_target_property(_qt_gl_iface WrapOpenGL::WrapOpenGL INTERFACE_LINK_LIBRARIES)
  if(_qt_gl_iface)
    list(FILTER _qt_gl_iface EXCLUDE REGEX "AGL")
    set_property(TARGET WrapOpenGL::WrapOpenGL PROPERTY INTERFACE_LINK_LIBRARIES "${_qt_gl_iface}")
  endif()
endif()

# ---- 第三方依赖：优先用 3rd/ 下的 submodule 源码 ----
# zlib / xz(liblzma) / libarchive / SDL3 都以 git submodule 冻结在 3rd/，默认从源码静态编译：
# 构建不依赖发行版包或包管理器，三平台跑的是同一份上游代码。
# 需要临时改回系统库时传 -DTTPLAYER_VENDORED=OFF（保留原来的 find_package 兜底）。
option(TTPLAYER_VENDORED "从 3rd/ 源码编译 zlib / xz / libarchive / SDL3（否则用系统库）" ON)

if(TTPLAYER_VENDORED)
  # zlib：只要静态库，关掉示例与安装规则
  set(ZLIB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
  set(ZLIB_BUILD_SHARED OFF CACHE BOOL "" FORCE)
  set(ZLIB_BUILD_STATIC ON CACHE BOOL "" FORCE)
  set(ZLIB_INSTALL OFF CACHE BOOL "" FORCE)
  add_subdirectory(3rd/zlib EXCLUDE_FROM_ALL)
  # libarchive 内部走 FindZLIB：先把 vendored 的 target 与路径给它，别让它去找系统 zlib。
  if(NOT TARGET ZLIB::ZLIB)
    add_library(ZLIB::ZLIB ALIAS zlibstatic)
  endif()
  set(ZLIB_INCLUDE_DIR "${zlib_SOURCE_DIR}" CACHE PATH "" FORCE)
  set(ZLIB_LIBRARY_RELEASE zlibstatic CACHE FILEPATH "" FORCE)
  set(ZLIB_LIBRARY zlibstatic)

  # xz：libarchive 读 7z / tar.xz 要用 liblzma，而 macOS SDK 只带 liblzma.tbd 不带 lzma.h，
  # 从源码编一份静态库才能不依赖 Homebrew。命令行工具与翻译全部关掉，只要库本体。
  set(XZ_TOOL_XZ OFF CACHE BOOL "" FORCE)
  set(XZ_TOOL_XZDEC OFF CACHE BOOL "" FORCE)
  set(XZ_TOOL_LZMADEC OFF CACHE BOOL "" FORCE)
  set(XZ_TOOL_LZMAINFO OFF CACHE BOOL "" FORCE)
  set(XZ_NLS OFF CACHE BOOL "" FORCE)
  # xz 的 tests/tests.cmake 会无条件 include(CTest)，把上游 58 个测试注册进我们的 CTest；
  # 那些 target 在 EXCLUDE_FROM_ALL 下不构建，ctest 会整片 "Not Run"。只关这一层。
  set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
  add_subdirectory(3rd/xz EXCLUDE_FROM_ALL)
  # libarchive 内部仍走 FindLibLZMA：先替它把头和库确定下来。
  # 三项 LIBLZMA_HAS_* 是模块里的 CHECK_LIBRARY_EXISTS 结果，只能用“已经存在的 .a”
  # 去做 try_compile；vendored liblzma 要到构建阶段才有产物，探测必然失败，所以直接标记已通过。
  set(LIBLZMA_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/3rd/xz/src/liblzma/api" CACHE PATH "" FORCE)
  set(LIBLZMA_LIBRARY liblzma CACHE FILEPATH "" FORCE)
  set(LIBLZMA_HAS_AUTO_DECODER 1 CACHE INTERNAL "")
  set(LIBLZMA_HAS_EASY_ENCODER 1 CACHE INTERNAL "")
  set(LIBLZMA_HAS_LZMA_PRESET 1 CACHE INTERNAL "")

  # bzip2：libarchive 读 tar.bz2 必须有内置 bzlib。找不到它时 libarchive 会退回
  # 外部 `bzip2 -d` 程序过滤器，Windows 的 MSYS bzip2 在管道上会卡死不返回
  # （CI 实测整档 120s 超时）。这里只取上游库源码编静态库，不用它的 CMakeLists：
  # 那份 CMake 会注册 CTest、man 与安装规则，把上游噪音带进本工程。
  set(_tt_bz2_dir "${CMAKE_CURRENT_SOURCE_DIR}/3rd/bzip2")
  set(BZ_VERSION 1.1.0)
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bzip2")
  configure_file("${_tt_bz2_dir}/bz_version.h.in" "${CMAKE_CURRENT_BINARY_DIR}/bzip2/bz_version.h" @ONLY)
  add_library(bz2static STATIC
      "${_tt_bz2_dir}/blocksort.c" "${_tt_bz2_dir}/huffman.c" "${_tt_bz2_dir}/crctable.c"
      "${_tt_bz2_dir}/randtable.c" "${_tt_bz2_dir}/compress.c" "${_tt_bz2_dir}/decompress.c"
      "${_tt_bz2_dir}/bzlib.c")
  target_include_directories(bz2static PUBLIC "${_tt_bz2_dir}" "${CMAKE_CURRENT_BINARY_DIR}/bzip2")
  target_compile_definitions(bz2static PUBLIC BZ2_STATICLIB)
  if(WIN32)
    target_compile_definitions(bz2static PRIVATE _CRT_SECURE_NO_WARNINGS)
  endif()
  # libarchive 用 FindBZip2：把 vendored 的头与 target 直接交给它。
  set(BZIP2_INCLUDE_DIR "${_tt_bz2_dir}" CACHE PATH "" FORCE)
  set(BZIP2_LIBRARIES bz2static CACHE STRING "" FORCE)
  set(BZIP2_VERSION_STRING "${BZ_VERSION}" CACHE STRING "" FORCE)
  set(BZIP2_FOUND TRUE CACHE BOOL "" FORCE)

  # libarchive：保留 zlib / bzip2 / lzma（现网支持的 ZIP、tar.gz/bz2、7z），
  # 其余可选依赖（OpenSSL / libxml2 / expat / lz4 / zstd / libb2）全部关闭：
  # libb2 开着会静默链上 Homebrew 的 libb2.dylib，而 BLAKE2 用 libarchive 自带的实现就够。
  set(BUILD_SHARED_LIBS OFF)
  set(ENABLE_OPENSSL OFF CACHE BOOL "" FORCE)
  set(ENABLE_LIBXML2 OFF CACHE BOOL "" FORCE)
  set(ENABLE_EXPAT OFF CACHE BOOL "" FORCE)
  set(ENABLE_LZ4 OFF CACHE BOOL "" FORCE)
  set(ENABLE_ZSTD OFF CACHE BOOL "" FORCE)
  set(ENABLE_LIBB2 OFF CACHE BOOL "" FORCE)
  set(ENABLE_TEST OFF CACHE BOOL "" FORCE)
  set(ENABLE_COVERAGE OFF CACHE BOOL "" FORCE)
  set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
  add_subdirectory(3rd/libarchive EXCLUDE_FROM_ALL)
  set(ARCHIVE_LIBRARY archive_static)
  # 校验 libarchive 真的用上了内置 bz2：这条退化只能从生成物里看出来，必须硬拦。
  file(STRINGS "${CMAKE_CURRENT_BINARY_DIR}/3rd/libarchive/config.h" _tt_bz2_config REGEX "HAVE_BZLIB_H")
  if(NOT _tt_bz2_config MATCHES "HAVE_BZLIB_H 1")
    message(FATAL_ERROR "libarchive 没有启用内置 bzip2（${_tt_bz2_config}）：tar.bz2 会退回外部 bzip2 程序过滤器")
  endif()
  # 头文件仍用稳定子集声明：shim 只声明用到的接口，不复制上游实现。
  set(CLIBARCHIVE_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/src/clibarchive/include)

  # SDL3：静态链接（设备 IO 只有一个入口，静态省掉打包拷 dylib）。
  set(SDL_SHARED OFF CACHE BOOL "" FORCE)
  set(SDL_STATIC ON CACHE BOOL "" FORCE)
  set(SDL_STATIC_PIC ON CACHE BOOL "" FORCE)
  set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
  set(SDL_TESTS OFF CACHE BOOL "" FORCE)
  set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
  # 本项目用 SDL3 只做音频设备 IO，窗口与事件都归 Qt。Linux 上没有 X11/Wayland
  # 开发包时，SDL 的 summary 检查会直接把 configure 判失败；打开
  # SDL_UNIX_CONSOLE_BUILD 跳过这项检查，ALSA/PulseAudio 后端仍然保留。
  if(UNIX AND NOT APPLE)
    set(SDL_UNIX_CONSOLE_BUILD ON CACHE BOOL "" FORCE)
  endif()
  add_subdirectory(3rd/sdl3 EXCLUDE_FROM_ALL)
  # 我们开了全局 CMAKE_AUTOMOC，它会顺带套到 SDL3 的 C target 上，
  # 与其预编译头生成规则冲突（cmake_pch_*.hxx.pch 无规则）。三方 target 一律不跑 moc。
  foreach(_sdl_target SDL3-shared SDL3-static SDL3_test)
    if(TARGET ${_sdl_target})
      set_target_properties(${_sdl_target} PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    endif()
  endforeach()

  # 平台分支不能直接写 "z"（那会拉系统 libz）：zlib 的静态库由这里统一给出。
  set(TTPLAYER_ZLIB_TARGET ZLIB::ZLIB)

  # 3rd/ 下的上游历史代码有少量警告，我们不改人家源码，也不让它们进主工程日志。
  # （产品的 -Wall/-Wextra 门禁只针对 ttplayer 自己的源码。）
  foreach(_tt_vendor_target zlibstatic zlib archive_static liblzma bz2static SDL3-static)
    if(TARGET ${_tt_vendor_target})
      if(MSVC)
        target_compile_options(${_tt_vendor_target} PRIVATE /w)
      else()
        target_compile_options(${_tt_vendor_target} PRIVATE -w)
      endif()
    endif()
  endforeach()
else()
  # 系统库兜底
  # SDL3：三平台各走本机最常见发现路径
  #   mac=Homebrew、linux=pkg-config(sdl3)、win(MSYS2/MinGW)=find_library
  find_package(SDL3 QUIET CONFIG)
  if(NOT TARGET SDL3::SDL3)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(SDL3 IMPORTED_TARGET sdl3)
    endif()
  endif()
  if(NOT TARGET SDL3::SDL3 AND NOT TARGET PkgConfig::SDL3)
    find_library(SDL3_LIBRARY SDL3 REQUIRED)
    find_path(SDL3_INCLUDE_DIR SDL3/SDL.h REQUIRED)
  endif()

  # libarchive 子集声明 shim.h 已随重构搬进 src/clibarchive/include（macOS SDK 不装 archive.h，ABI 只用 3.4/3.5 时代稳定接口）。
  find_library(ARCHIVE_LIBRARY NAMES archive libarchive REQUIRED)
  set(CLIBARCHIVE_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/src/clibarchive/include)
  set(TTPLAYER_ZLIB_TARGET z)
endif()

# FFmpeg 静态库（scripts/build_ffmpeg*.sh 的产物，三平台各自现编）
# 可用 -DFFMPEG_ROOT 覆盖；CI 里各平台把现编产物落到同一 3rd/ffmpeg-build 布局。
set(FFMPEG_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/3rd/ffmpeg-build CACHE PATH "prebuilt static FFmpeg root")
set(FFMPEG_LINK_LIBRARIES)
foreach(_component avformat avcodec swresample avutil)
  find_library(FFMPEG_${_component} NAMES ${_component} PATHS "${FFMPEG_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
  if(MSVC)
    # Debug 必须匹配 /MDd，不能拿 Release 的 CRT 静态对象与 Qt Debug 混链。
    list(APPEND FFMPEG_LINK_LIBRARIES "$<IF:$<CONFIG:Debug>,${FFMPEG_ROOT}/debug/lib/${_component}.lib,${FFMPEG_${_component}}>")
  else()
    list(APPEND FFMPEG_LINK_LIBRARIES "${FFMPEG_${_component}}")
  endif()
endforeach()

# 格式转换用外部编码库（scripts/codec_deps.sh 产物，与 FFmpeg 链接的是同一份）。
# 静态链接顺序：vorbisenc 依赖 vorbis、vorbis 依赖 ogg，被依赖的库必须排在后面；
# 这些库又都是 libavcodec 里 libmp3lame/libvorbis/libopus 编码器的下游。
set(CODEC_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/3rd/codec-build CACHE PATH "prebuilt external codec libs root")
set(CODEC_LINK_LIBRARIES)
foreach(_codec vorbisenc vorbis ogg opus mp3lame)
  find_library(CODEC_${_codec} NAMES ${_codec} PATHS "${CODEC_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
  if(MSVC)
    # Debug 必须匹配 /MDd，不能拿 Release 的 CRT 静态对象与 Qt Debug 混链。
    list(APPEND CODEC_LINK_LIBRARIES "$<IF:$<CONFIG:Debug>,${CODEC_ROOT}/debug/lib/${_codec}.lib,${CODEC_${_codec}}>")
  else()
    list(APPEND CODEC_LINK_LIBRARIES "${CODEC_${_codec}}")
  endif()
endforeach()

qt_add_executable(ttplayer
  src/main.cpp
  src/decoder/FFmpeg.cpp
  src/decoder/Decoder.cpp
  src/decoder/Archive.cpp
  src/decoder/AudioEncoder.cpp
  src/audio/AudioEngine.cpp
  src/audio/EQ.cpp
  src/audio/Spectrum.cpp
  src/audio/RadioStream.cpp
  src/models/Track.cpp
  src/models/Importer.cpp
  src/models/Lyric.cpp
  src/models/CoverArt.cpp
  src/models/TrackFilter.cpp
  src/models/UserPlaylist.cpp
  src/models/GlobalSearch.cpp
  src/models/PlaylistM3U.cpp
  src/models/CueSheet.cpp
  src/models/ReplayGain.cpp
  src/models/LibraryStore.cpp
  src/models/RadioPresets.cpp
  src/models/RadioStations.cpp
  src/models/PlayQueue.cpp
  src/core/PlayerController.cpp
  src/core/Collections.cpp
  src/core/CrashHandler.cpp
  src/core/AudioConvert.cpp
  src/testing/RadioHarness.cpp
  src/testing/Regression.cpp
  src/ui/Theme.cpp
  src/ui/AppIcon.cpp
  src/ui/Painter.cpp
  src/ui/SkinParts.cpp
  src/ui/SkinWidgets.cpp
  src/ui/TransportBar.cpp
  src/ui/PlaylistView.cpp
  src/ui/PlaylistWindow.cpp
  src/ui/QueueWindow.cpp
  src/ui/EqWindow.cpp
  src/ui/LyricWindow.cpp
  src/ui/CoverWindow.cpp
  src/ui/PropertyWindow.cpp
  src/ui/ConvertWindow.cpp
  src/ui/TrayController.cpp
  src/ui/SpectrumView.cpp
  src/ui/SkinDock.cpp
  src/ui/SkinWindow.cpp
  src/ui/SettingsWindow.cpp
  src/ui/MainWindow.cpp
)
target_include_directories(ttplayer PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/src
  ${FFMPEG_ROOT}/include
  ${CLIBARCHIVE_INCLUDE}
)
if(SDL3_INCLUDE_DIR)
  target_include_directories(ttplayer PRIVATE ${SDL3_INCLUDE_DIR})
endif()
target_link_directories(ttplayer PRIVATE ${FFMPEG_ROOT}/lib)

# 静态 FFmpeg 依赖系统库：链接顺序按依赖，系统库按平台分道
target_link_libraries(ttplayer PRIVATE
  Qt6::Widgets Qt6::Gui Qt6::Core Qt6::Network Qt6::Core5Compat Qt6::Concurrent Qt6::Sql
  ${ARCHIVE_LIBRARY}
  # 静态链接顺序按依赖
  ${FFMPEG_LINK_LIBRARIES}
  # avcodec 的外部编码器（mp3/vorbis/opus）在运行时引用这些库
  ${CODEC_LINK_LIBRARIES}
)
if(SDL3_LIBRARY)
  target_link_libraries(ttplayer PRIVATE ${SDL3_LIBRARY})
elseif(TARGET SDL3::SDL3)
  target_link_libraries(ttplayer PRIVATE SDL3::SDL3)
elseif(TARGET PkgConfig::SDL3)
  target_link_libraries(ttplayer PRIVATE PkgConfig::SDL3)
endif()

# 可选：Core5Compat 提供 QTextCodec，Lyric 用它解 GB18030/GBK 中文歌词
if(TARGET Qt6::Core5Compat)
  target_link_libraries(ttplayer PRIVATE Qt6::Core5Compat)
  target_compile_definitions(ttplayer PRIVATE TTPLAYER_HAVE_TEXTCODEC=1)
endif()

if(APPLE)
  # CMake 3.27 的 AppleClang-OBJCXX 模块只有旧表（C++20 写 -std=c++2a），
  # 而同版本 AppleClang-CXX 在 clang ≥ 13 已改 -std=c++20；
  # 两种拼写对 clang 等价，这里对齐字面，避免同一工程里出现两种 -std。
  if(CMAKE_OBJCXX_COMPILER_VERSION VERSION_GREATER_EQUAL 13.0)
    set(CMAKE_OBJCXX20_STANDARD_COMPILE_OPTION "-std=c++20")
    set(CMAKE_OBJCXX20_EXTENSION_COMPILE_OPTION "-std=gnu++20")
  endif()
  target_sources(ttplayer PRIVATE src/platform/MediaSession_mac.mm)
  set_source_files_properties(src/platform/MediaSession_mac.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  # pthread 只经 Threads::Threads 进链接行：vendored SDL3-static 的 INTERFACE_LINK_OPTIONS
  # 已带 -lpthread，再手写一个 pthread 会触发 ld 的 duplicate libraries 警告。
  target_link_libraries(ttplayer PRIVATE ${TTPLAYER_ZLIB_TARGET} m Threads::Threads
    "-framework CoreFoundation" "-framework CoreVideo" "-framework CoreMedia"
    "-framework AudioToolbox" "-framework CoreAudio" "-framework MediaPlayer")
elseif(UNIX)
  find_package(Qt6 REQUIRED COMPONENTS DBus)
  target_sources(ttplayer PRIVATE src/platform/MediaSession_linux.cpp)
  target_link_libraries(ttplayer PRIVATE Qt6::DBus)
  # Linux：静态 FFmpeg 需 dl/Threads/m；zlib 由 vendored 静态库或系统库提供
  target_link_libraries(ttplayer PRIVATE m Threads::Threads dl ${TTPLAYER_ZLIB_TARGET})
elseif(WIN32)
  target_compile_definitions(ttplayer PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
  target_sources(ttplayer PRIVATE src/platform/MediaSession_win.cpp)
  # Windows（MinGW）：静态 FFmpeg 需的一批 advapi/ws 系统库 + winpthreads；dbghelp 供崩溃栈符号化
  target_link_libraries(ttplayer PRIVATE
    ws2_32 secur32 bcrypt advapi32 user32 ole32 oleaut32 uuid shell32 strmiids
    gdi32 vfw32 ntdll dbghelp windowsapp)
  # 新版 vcpkg 的 libz.lib 由 ZLIBConfig 导出；旧版本仍可走 FindZLIB。
  find_package(ZLIB QUIET CONFIG)
  if(NOT TARGET ZLIB::ZLIB)
    find_package(ZLIB REQUIRED)
  endif()
  target_link_libraries(ttplayer PRIVATE ZLIB::ZLIB)
  if(MINGW)
    target_link_libraries(ttplayer PRIVATE m winpthread)
  endif()
endif()
# Qt 管理应用入口；SDL 不得把 main 重写为 SDL_main。
target_compile_definitions(ttplayer PRIVATE TTPLAYER_QT=1 SDL_MAIN_HANDLED)
if(MSVC)
  target_compile_options(ttplayer PRIVATE /W4 /utf-8 /permissive-)
else()
  target_compile_options(ttplayer PRIVATE -Wall -Wextra -Wpedantic)
endif()

option(TTPLAYER_BUNDLE "Build a macOS application bundle for distribution" OFF)
if(APPLE AND TTPLAYER_BUNDLE)
  configure_file(packaging/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
  set_target_properties(ttplayer PROPERTIES MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.ttplayer.TTPlayer"
    MACOSX_BUNDLE_BUNDLE_NAME "千千静听"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.1.5")
endif()
if(WIN32)
  set_target_properties(ttplayer PROPERTIES WIN32_EXECUTABLE TRUE)
endif()
install(TARGETS ttplayer BUNDLE DESTINATION . RUNTIME DESTINATION bin)
if(UNIX AND NOT APPLE)
  install(FILES packaging/ttplayer.desktop DESTINATION share/applications)
  install(FILES packaging/ttplayer.svg DESTINATION share/icons/hicolor/scalable/apps)
endif()
if(WIN32 AND DEFINED ENV{TTPLAYER_VCPKG_ROOT})
  install(DIRECTORY "$ENV{TTPLAYER_VCPKG_ROOT}/bin/" DESTINATION bin FILES_MATCHING PATTERN "*.dll")
endif()
if(NOT APPLE OR TTPLAYER_BUNDLE)
  if(APPLE)
    if(TARGET SDL3::SDL3)
      # vendored SDL3 默认静态链接：只有动态库才需要拷进 Frameworks。
      get_target_property(_tt_sdl_type SDL3::SDL3 TYPE)
      if(_tt_sdl_type STREQUAL "SHARED_LIBRARY")
        set(_tt_sdl_location "$<TARGET_FILE:SDL3::SDL3>")
      endif()
    elseif(SDL3_LIBRARY AND SDL3_LIBRARY MATCHES "\\.(dylib|so)$")
      set(_tt_sdl_location "${SDL3_LIBRARY}")
    endif()
    # macdeployqt resolves Qt frameworks, but does not reliably resolve an SDL @rpath
    # after install has stripped the build-time rpaths. Copy the real dylib, not its symlink.
    if(_tt_sdl_location)
      install(CODE "file(REAL_PATH \"${_tt_sdl_location}\" _sdl_real)\nfile(INSTALL DESTINATION \"\${CMAKE_INSTALL_PREFIX}/ttplayer.app/Contents/Frameworks\" TYPE FILE FILES \"\${_sdl_real}\")")
    endif()
    if(TARGET Qt6::QOffscreenIntegrationPlugin)
      install(FILES "$<TARGET_FILE:Qt6::QOffscreenIntegrationPlugin>" DESTINATION "ttplayer.app/Contents/PlugIns/platforms")
    endif()
  endif()
  qt_generate_deploy_app_script(TARGET ttplayer OUTPUT_SCRIPT ttplayer_deploy NO_UNSUPPORTED_PLATFORM_ERROR)
  install(SCRIPT ${ttplayer_deploy})
  if(APPLE)
    # macdeployqt 把 sqldrivers 整个目录搬进来，其中 mimer 插件链到本机不存在的
    # /usr/local/lib/libmimerapi.dylib，加载必失败；只留 state.db 需要的 sqlite 插件。
    install(CODE "file(REMOVE \"\${CMAKE_INSTALL_PREFIX}/ttplayer.app/Contents/PlugIns/sqldrivers/libqsqlmimer.dylib\")")
  endif()
endif()
set(CPACK_PACKAGE_NAME TTPlayer)
set(CPACK_PACKAGE_VERSION 1.1.5)
include(CPack)

# ---- CTest 注册（R27）----
# 每个探针一个测试：无头 offscreen + SDL dummy + 独立隔离存档（TTPLAYER_QT_STATE 落在
# 构建目录，库文件 <探针>.db 随同目录隔离，绝不碰用户 ~/.../TTPlayer/state.db）。
# WORKING_DIRECTORY 指仓库根，探针按 QDir::currentPath()+"/testlib/" 取素材。
# 退出码 0/1 直接映射 ctest PASS/FAIL。
# 与 scripts/selftest.sh 同源：脚本给分档/计时/state 守卫，ctest 给 IDE / CI 矩阵入口。
enable_testing()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_test(NAME qt.fixtures COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/selftest_fixtures.py" "${CMAKE_CURRENT_BINARY_DIR}/fixtures")
set_tests_properties(qt.fixtures PROPERTIES FIXTURES_SETUP audio_samples TIMEOUT 120)
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/src/testing/suites.txt" QT_TEST_PROBES)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/testing/suites.txt")
foreach(_p IN LISTS QT_TEST_PROBES)
  add_test(NAME qt.${_p} COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/selftest_guard.py" "$<TARGET_FILE:ttplayer>")
  set_tests_properties(qt.${_p} PROPERTIES
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    FIXTURES_REQUIRED audio_samples
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;SDL_AUDIODRIVER=dummy;TTPLAYER_SELFTEST=1;TTPLAYER_TESTDIR=${CMAKE_CURRENT_BINARY_DIR}/fixtures;TTPLAYER_SILENT_OUTPUT=1;TTPLAYER_QT_STATE=${CMAKE_CURRENT_BINARY_DIR}/selftest-ctest/${_p}.json;TTPLAYER_QT_${_p}_PROBE=1"
    TIMEOUT 120)
endforeach()
