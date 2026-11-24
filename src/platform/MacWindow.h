#pragma once
class QWidget;

// macOS：把副面板（播放列表/歌词/均衡器/封面/队列）归组到主窗之下，使其不单独出现在
// App Exposé（Dock「显示所有窗口」）网格、只占主窗那一个 tile。实测：collectionBehavior
// （primary/auxiliary 只管全屏与 Stage Manager、transient 只管 Mission Control）与 Qt::Tool
// 的 utility style mask（实际没设上）都无法移出 App Exposé，唯一有效的是「非普通层」——
// 于是分两种手段：置顶时把 level 设 NSFloatingWindowLevel（浮动层本身即被剔除）；未置顶时
// 用 [主窗 addChildWindow:面板] 在普通层归组（可被别的 app 覆盖），并紧跟 orderFrontRegardless
// 修正「失焦→回焦后挂上的 child 不进可见层」导致的面板“消失”。hidesOnDeactivate=NO 防失焦隐藏。
// 返回 true 表示已成功施加；平台窗尚未 realize/expose 时返回 false，调用方应择机重试。
// 非 cocoa 平台为 no-op，返回 false。
bool macApplyPanelUtility(QWidget *panel);
