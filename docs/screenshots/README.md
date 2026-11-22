# Qt 界面截图

以下九张 PNG 于 2026-11-22 在 macOS 14.0 arm64 上，从按当前源码生成的本地打包版 `TTPlayer 1.1.5 Qt 6.8.3 arm64` 实际运行的窗口截取。使用默认深色皮肤、Qt offscreen、2 倍像素比例、dummy 音频输出与静音门。窗口保留应用的玻璃透明度，导出文档配图时统一叠在深灰底（`#242424`）上，便于在白底和深底页面阅读。搜索截图将窗口拉宽到 640 逻辑像素，便于读全曲名与来源；不改变正常窗口的默认尺寸。桌面壁纸、系统合成、吸附和置顶效果需要在桌面上另验。

| 窗口 | 截图时的状态 |
| --- | --- |
| [主面板](main.png) | 正在播放示例 FLAC《夜航》，默认音量 80%，可见耳机图标、封面、频谱和左右电平 |
| [播放列表](playlist.png) | 默认列表包含六首示例曲目和一台内置电台，当前曲目高亮；时长左侧有收藏爱心，总时长为 00:04:57，电台不计时 |
| [全局搜索](search.png) | 在真实搜索框输入“夜航”，结果为《夜航》和《夜航变奏》，显示默认列表及最近播放等来源 |
| [网络电台](radio.png) | 选中「网络电台」页，显示两个示例直播台和「音乐台」分类；截图时未连外网电台 |
| [均衡器](equalizer.png) | 十个频段均在 0 dB，左侧显示音量与前置增益 |
| [内嵌同步歌词](lyric.png) | FLAC 的 lyrics 标签包含 LRC，第一行随播放时间高亮；同名外置 LRC 的备用正文未被使用 |
| [内嵌纯文本歌词](lyric-plain.png) | FLAC 的 lyrics 标签没有时间标签，显示自由滚动的文本区；同名外置 LRC 的备用正文未被使用 |
| [封面](cover.png) | 显示曲目目录里的自绘 300 × 300 海港封面和曲目信息 |
| [设置](settings.png) | 「播放」页显示顺序播放、无缝播放与睡眠定时器；窗口使用统一玻璃皮肤 |

## 更新配图

先准备当前 Qt 打包版、临时目录及示例媒体。用本地生成的音频、自己可分发的封面和歌词，避免把个人曲库、真实电台地址或绝对路径带入截图。示例曲目建议做成立体声，专辑也不要和搜索关键字同名——搜索按标题、艺术家、专辑和文件名匹配，专辑撞词会把命中数放大。以下示例从仓库根目录运行，生成一张可以检查的主面板截图：

```sh
shot_dir=$(mktemp -d build/screenshots.XXXXXX)
ffmpeg -v error -f lavfi -i 'sine=frequency=440:duration=12' \
  -ac 2 -metadata title=夜航 -metadata artist=TTPlayer -metadata album=晚风 \
  "$shot_dir/夜航.flac"
env QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 SDL_AUDIODRIVER=dummy \
  TTPLAYER_SELFTEST=1 TTPLAYER_SILENT_OUTPUT=1 \
  TTPLAYER_QT_STATE="$shot_dir/state.json" TTPLAYER_QT_SHOT="$shot_dir/main.png" \
  python3 scripts/selftest_guard.py build/dist/ttplayer.app/Contents/MacOS/ttplayer "$shot_dir/夜航.flac"
```

每张图使用新的隔离目录，不复用旧截图存档。`TTPLAYER_QT_STATE` 指定隔离的 `state.json` 路径，实际 SQLite 存档 `state.db` 及其 `-wal` / `-shm` 同在该目录；旧目录残留的电台分类会影响下一张图。主面板探针会等 800 ms 让频谱分析器热身后再抓图。音频、封面、歌词及截图中间产物均留在 `build/` 或临时目录，不提交到仓库。

文档配图用 ffmpeg 把透明窗口合成到统一背景（本机没有 ImageMagick 也能跑）：

```sh
size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$shot_dir/main.png")
ffmpeg -v error -f lavfi -i "color=c=0x242424:s=$size:d=1" -i "$shot_dir/main.png" \
  -filter_complex "[0:v]format=rgba[b];[b][1:v]overlay=shortest=1:format=auto,format=rgb24" \
  -frames:v 1 "$shot_dir/main-doc.png"
```

单独抓取面板时，把变量名 `TTPLAYER_QT_SHOT` 换成 `TTPLAYER_QT_SHOT_PLAYLIST`、`TTPLAYER_QT_SHOT_SEARCH`、`TTPLAYER_QT_SHOT_RADIO`、`TTPLAYER_QT_SHOT_EQ`、`TTPLAYER_QT_SHOT_LYRIC`、`TTPLAYER_QT_SHOT_COVER` 或 `TTPLAYER_QT_SHOT_SETTINGS`，并指定对应的输出文件名。列表与搜索传入六首带标签的曲目，标题依次为《夜航》《夜航变奏》《海上的灯》《晚风》《归港》《天色将明》，时长为 42、45、48、51、54、57 秒，艺术家为 TTPlayer，专辑为「海港来信」。搜索走真实搜索框输入“夜航”；电台页自建两台 example.com 示例台和「音乐台」分类，不播放电台。歌词分别传入包含内嵌 LRC 和纯文本标签的音频；封面传入目录内带 `cover.png` 的音频；设置截图展示默认的播放页。Windows 和 Linux 可将示例中的可执行文件换成相应平台的 Qt 产物。

截图时检查页面高亮、行内容、总时长、搜索词及歌词正文，逐张查看 PNG 后再替换配图。守卫核对真实用户的 `state.db`、`state.db-wal`、`state.db-shm`、`state.json` 与 `resume.json`，截图前后必须逐字节一致；若正在运行的实例更新了现场，先查明来源，不用旧快照覆盖用户的新修改。
