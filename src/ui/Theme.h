#pragma once

// 皮肤配色：Winamp 式深色磨砂玻璃（炭黑壳 + 亮字 + 橙黄 accent）。
// 统一毛玻璃重构后：全窗单一深色玻璃调，区域之间只用 1px 发丝线（hairline）分隔。
// GlassStyle 只暴露一个 transparency 主参数，所有层一律从它派生同一个 glassAlpha
//（AGENTS.md 约束）：glassAlpha = transparency。

#include <QColor>
#include <QObject>
#include <QFont>

namespace Theme {

// 面板外壳（炭黑玻璃）
extern const QColor windowTop, windowBottom, panel;
extern const QColor skinEdge, innerHighlight, shellDivider;
// 标题条
extern const QColor titleTop, titleBottom, titleText;
// 内嵌近黑槽
extern const QColor wellTop, wellBottom, listBackground, wellBevelDark, wellBevelLight, groove;
// 文字（深底亮字）
extern const QColor textPrimary, textSecondary, textAccent, textHighlight;
// 控件（深玻璃按钮，三段面才有「鼓起来」的弧度）
extern const QColor buttonTop, buttonBottom;
extern const QColor buttonLightTop, buttonLightMid, buttonLightBottom;
extern const QColor buttonDownTop, buttonDownMid, buttonDownBottom;
extern const QColor buttonHotTop, buttonHotBottom, buttonFace, buttonHot, buttonPressed;
extern const QColor buttonEdge, border;
// 扁平文字按钮（深底：显示区底部的「列表/均衡器/歌词」）
extern const QColor flatText, flatTextHot, flatHotBG, flatEdgeHot;
// 扁平文字按钮（浅底：TTButton）
extern const QColor flatTextOnLight, flatTextOnLightHot, flatHotOnLightBG;
// 频谱（橙黄柱）
extern const QColor spectrumTop, spectrumBottom, spectrumPeak, spectrumGrid;
// 电平表
extern const QColor meterGreen, meterYellow, meterRed;
// 统一毛玻璃：区域之间的 1px 发丝分隔线（取代深槽压边与 groupbox 边框）
extern const QColor hairline;
// 深底亮字：内容区走深玻璃后，文字/前景统一用这套亮色系保可读
extern const QColor inkOnGlass, inkOnGlassSoft, inkOnGlassAccent;

} // namespace Theme

/// 字体（system 13/12/11 + bold 13）
/// 不锁 macOS 专有的 .AppleSystemUIFont（Windows/Linux 解析不到会退到各自系统字体），
/// 而是给一组跨平台优先级字体栈 + sans-serif 兜底（消除 "missing font family" 告警）。
namespace Fonts {
extern const QFont base, small, tiny, title, panelTitle;
// Windows 的纯数字读数使用 Segoe UI；其他平台与对应文本字体完全相同。
extern const QFont numericSmall, numericTiny;
}

/// 跨平台视觉一致的地基：强制 Fusion 控件风格（不跟随各 OS 原生 style）+ 固定调色板
/// （不随系统深/浅色漂移）+ 应用级默认字体。必须在 QApplication 构造后尽早调一次。
class QApplication;
namespace Theme {
void applyAppStyle(QApplication *app);
}

/// 半透明玻璃全局开关：主窗、播放列表、均衡器、歌词四个主面板共用同一 alpha；
/// 设置/属性/队列/封面等辅助窗不跟随，始终保持不透明，避免重叠时透底看不清。
/// 单例 QObject：变更 broadcast changed() 信号，自绘控件 connect 到它的 update。
/// 用信号而非手写回调表：控件析构时 Qt 自动断开连接，不会悬垂。
class GlassNotifier : public QObject {
    Q_OBJECT
public:
    static GlassNotifier &instance();
signals:
    void changed();
};

class GlassStyle {
public:
    static float transparency() { return s_transparency; }
    // 保持已确认的深色样式：壳、槽、按钮共用原有透明度。
    static float bodyAlpha() { return s_transparency; }
    static float wellAlpha() { return s_transparency; }
    static float buttonAlpha() { return s_transparency; }
    static float glassAlpha() { return bodyAlpha(); }
    static bool enabled() { return s_enabled; }

    static void setEnabled(bool on);
    static void setTransparency(float v); // 变化时发 GlassNotifier::changed

private:
    static inline float s_transparency = 0.15f;
    static inline bool s_enabled = true;
};
