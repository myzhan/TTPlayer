# Qt 界面截图

以下八张 PNG 于 2026-11-21 在 macOS arm64 上从本地打包版 `TTPlayer 1.1.5 Qt 6.8.3 arm64` 实际运行的窗口截取。使用默认深色皮肤、Qt offscreen 和 2 倍像素比例。窗口保留应用的玻璃透明度，导出文档配图时统一叠在深灰底（`#242424`）上，便于在白底和深底页面阅读。桌面壁纸、系统合成和置顶效果需要在桌面上另验。

| 窗口 | 截图时的状态 |
| --- | --- |
| [主面板](main.png) | 正在播放示例 FLAC《夜航》，可见封面、频谱和左右电平 |
| [播放列表](playlist.png) | 默认列表包含六首示例曲目和内置电台，当前曲目高亮 |
| [全局搜索](search.png) | 在真实搜索框输入“夜航”，结果为《夜航》和《夜航变奏》，显示匹配来源 |
| [网络电台](radio.png) | 选中「网络电台」页，显示两个示例直播台和自建分类；截图时未连外网电台 |
| [待播队列](queue.png) | 当前播放项之外有四个待播项，含下一首播放和稍后播放 |
| [均衡器](equalizer.png) | 十个频段均在 0 dB，左侧显示音量与前置增益 |
| [歌词](lyric.png) | 本地 FLAC 配同名 LRC，第一行随播放时间高亮 |
| [封面](cover.png) | 显示曲目目录里的 300 × 300 示范封面和曲目信息 |

## 更新配图

先准备当前 Qt 打包版、临时目录及示例媒体。用本地生成的音频、自己可分发的封面和歌词，避免把个人曲库、真实电台地址或绝对路径带入截图。示例曲目建议做成立体声，专辑也不要和搜索关键字同名——搜索按标题、艺术家、专辑和文件名匹配，专辑撞词会把命中数放大。以下示例从仓库根目录运行，生成一张可以检查的主面板截图：

```sh
shot_dir=$(mktemp -d)
ffmpeg -v error -f lavfi -i 'sine=frequency=440:duration=12' \
  -ac 2 -metadata title=夜航 -metadata artist=TTPlayer -metadata album=晚风 \
  "$shot_dir/夜航.flac"
env QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 SDL_AUDIODRIVER=dummy \
  TTPLAYER_SELFTEST=1 TTPLAYER_SILENT_OUTPUT=1 \
  TTPLAYER_QT_STATE="$shot_dir/state.json" TTPLAYER_QT_SHOT="$shot_dir/main.png" \
  python3 scripts/selftest_guard.py build/dist/ttplayer.app/Contents/MacOS/ttplayer "$shot_dir/夜航.flac"
```

`TTPLAYER_QT_STATE` 只指定 `state.json`，同主名的媒体库 `state.db` 落在同一目录；换一批截图要把两份一起清掉，否则左栏会残留上一次截图的电台分类。主面板探针会等 800 ms 让频谱分析器热身后再抓图，同一份素材重复运行应当得到几乎相同的频谱。

文档配图用 ffmpeg 把透明窗口合成到统一背景（本机没有 ImageMagick 也能跑）：

```sh
size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$shot_dir/main.png")
ffmpeg -v error -f lavfi -i "color=c=0x242424:s=$size:d=1" -i "$shot_dir/main.png" \
  -filter_complex "[0:v]format=rgba[b];[b][1:v]overlay=shortest=1:format=auto,format=rgb24" \
  -frames:v 1 "$shot_dir/main-doc.png"
```

单独抓取面板时，把变量名 `TTPLAYER_QT_SHOT` 换成 `TTPLAYER_QT_SHOT_PLAYLIST`、`TTPLAYER_QT_SHOT_SEARCH`、`TTPLAYER_QT_SHOT_RADIO`、`TTPLAYER_QT_SHOT_EQ`、`TTPLAYER_QT_SHOT_LYRIC`、`TTPLAYER_QT_SHOT_COVER` 或 `TTPLAYER_QT_SHOT_QUEUE`，并指定对应的输出文件名。列表传入多首带标签的曲目；搜索走真实搜索框输入“夜航”；电台页自建两台示例台和「音乐台」分类；歌词、封面传入带同名 LRC 或目录内 `cover.png` 的音频；队列探针自带示例条目，不传曲目可以避开启动时的异步导入与队列现场抢时序。Windows 和 Linux 可将示例中的可执行文件换成相应平台的 Qt 产物。

截图时检查页面高亮、行内容和搜索词，逐张查看原始 PNG 后再替换同名文件。真实用户的 `state.json` 与 `resume.json` 由守卫核对，正在播放的实例可能自行更新进度，遇到变化须查明来源并重新分批校验。
