# TTPlayer Qt6 —— 跨平台重构（C++20 + Qt Widgets + FFmpeg 静态库 + SDL2 输出）
#
# 工程代码在 src/，CMakeLists.txt 在仓库根。
# 解码层沿用 3rd/ffmpeg-build 的静态库（同一份产物、同一套链接顺序：avformat → avcodec → swresample → avutil）。
# libarchive 稳定子集声明已搬进 src/clibarchive/include。
# 输出层：设备 IO 用 SDL2（mac=CoreAudio/win=WASAPI/linux=ALSA），EQ/fade/频谱在回调里自绘。
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

# SDL2（输出设备抽象）：三平台各走本机最常见发现路径
#   mac=Homebrew、linux=pkg-config(sdl2)、win(MSYS2/MinGW)=find_library
find_package(SDL2 QUIET CONFIG)
if(NOT TARGET SDL2::SDL2)
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(SDL2 IMPORTED_TARGET sdl2)
  endif()
endif()
if(NOT TARGET SDL2::SDL2 AND NOT TARGET PkgConfig::SDL2)
  find_library(SDL2_LIBRARY SDL2 REQUIRED)
  find_path(SDL2_INCLUDE_DIR SDL2/SDL.h REQUIRED)
endif()

# libarchive 子集声明 shim.h 已随重构搬进 src/clibarchive/include（macOS SDK 不装 archive.h，ABI 只用 3.4/3.5 时代稳定接口）。
find_library(ARCHIVE_LIBRARY NAMES archive libarchive REQUIRED)
set(CLIBARCHIVE_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/src/clibarchive/include)

# FFmpeg 静态库（scripts/build_ffmpeg*.sh 的产物，三平台各自现编）
# 可用 -DFFMPEG_ROOT 覆盖；CI 里各平台把现编产物落到同一 3rd/ffmpeg-build 布局。
set(FFMPEG_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/3rd/ffmpeg-build CACHE PATH "prebuilt static FFmpeg root")
foreach(_component avformat avcodec swresample avutil)
  find_library(FFMPEG_${_component} NAMES ${_component} PATHS "${FFMPEG_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
endforeach()

qt_add_executable(ttplayer
  src/main.cpp
  src/decoder/FFmpeg.cpp
  src/decoder/Decoder.cpp
  src/decoder/Archive.cpp
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
if(SDL2_INCLUDE_DIR)
  target_include_directories(ttplayer PRIVATE ${SDL2_INCLUDE_DIR})
endif()
target_link_directories(ttplayer PRIVATE ${FFMPEG_ROOT}/lib)

# 静态 FFmpeg 依赖系统库：链接顺序按依赖，系统库按平台分道
target_link_libraries(ttplayer PRIVATE
  Qt6::Widgets Qt6::Gui Qt6::Core Qt6::Network Qt6::Core5Compat Qt6::Concurrent Qt6::Sql
  ${ARCHIVE_LIBRARY}
  # 静态链接顺序按依赖
  ${FFMPEG_avformat} ${FFMPEG_avcodec} ${FFMPEG_swresample} ${FFMPEG_avutil}
)
if(SDL2_LIBRARY)
  target_link_libraries(ttplayer PRIVATE ${SDL2_LIBRARY})
elseif(TARGET SDL2::SDL2)
  target_link_libraries(ttplayer PRIVATE SDL2::SDL2)
elseif(TARGET PkgConfig::SDL2)
  target_link_libraries(ttplayer PRIVATE PkgConfig::SDL2)
endif()

# 可选：Core5Compat 提供 QTextCodec，Lyric 用它解 GB18030/GBK 中文歌词
if(TARGET Qt6::Core5Compat)
  target_link_libraries(ttplayer PRIVATE Qt6::Core5Compat)
  target_compile_definitions(ttplayer PRIVATE TTPLAYER_HAVE_TEXTCODEC=1)
endif()

if(APPLE)
  enable_language(OBJCXX)
  # CMake 3.27 的 AppleClang-OBJCXX 模块只有旧表（C++20 写 -std=c++2a），
  # 而同版本 AppleClang-CXX 在 clang ≥ 13 已改 -std=c++20；
  # 两种拼写对 clang 等价，这里对齐字面，避免同一工程里出现两种 -std。
  if(CMAKE_OBJCXX_COMPILER_VERSION VERSION_GREATER_EQUAL 13.0)
    set(CMAKE_OBJCXX20_STANDARD_COMPILE_OPTION "-std=c++20")
    set(CMAKE_OBJCXX20_EXTENSION_COMPILE_OPTION "-std=gnu++20")
  endif()
  target_sources(ttplayer PRIVATE src/platform/MediaSession_mac.mm)
  set_source_files_properties(src/platform/MediaSession_mac.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_libraries(ttplayer PRIVATE z m pthread
    "-framework CoreFoundation" "-framework CoreVideo" "-framework CoreMedia"
    "-framework AudioToolbox" "-framework CoreAudio" "-framework MediaPlayer")
elseif(UNIX)
  find_package(Qt6 REQUIRED COMPONENTS DBus)
  target_sources(ttplayer PRIVATE src/platform/MediaSession_linux.cpp)
  target_link_libraries(ttplayer PRIVATE Qt6::DBus)
  # Linux：静态 FFmpeg 需 dl/pthread/m，只开了 zlib
  target_link_libraries(ttplayer PRIVATE m pthread dl z)
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
    if(TARGET SDL2::SDL2)
      set(_tt_sdl_location "$<TARGET_FILE:SDL2::SDL2>")
    else()
      set(_tt_sdl_location "${SDL2_LIBRARY}")
    endif()
    # macdeployqt resolves Qt frameworks, but does not reliably resolve an SDL @rpath
    # after install has stripped the build-time rpaths. Copy the real dylib, not its symlink.
    install(CODE "file(REAL_PATH \"${_tt_sdl_location}\" _sdl_real)\nfile(INSTALL DESTINATION \"\${CMAKE_INSTALL_PREFIX}/ttplayer.app/Contents/Frameworks\" TYPE FILE FILES \"\${_sdl_real}\")")
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
