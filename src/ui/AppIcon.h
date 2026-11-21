#pragma once

#include <QIcon>
#include <QPixmap>

// 应用图标：蓝玻璃圆角底 + 白色耳机（千千静听意象）。
// 不依赖任何图片资源，运行时 Dock / 窗口标题栏 / Cmd-Tab 图标都由这一份代码现画。
// .app 包里的 Finder/.icns 图标由打包脚本（R26）用同一套几何导出，本机不入库二进制。
namespace AppIcon {

// 画一枚 side 边长的图标（16~1024 按比例推，小尺寸走加粗比例不糊）
QPixmap pixmap(int side);

// 多尺寸 QIcon（供 setWindowIcon）
QIcon icon();

} // namespace AppIcon
