#include "Theme.h"

#include <QApplication>
#include <QStyleFactory>
#include <QPalette>

// 色值：Winamp 式深色磨砂皮肤 —— 炭黑玻璃壳 + 亮字 + 橙黄 accent。改这里就是改皮肤主色。
// 深底亮字：壳/well 都是深色，前景一律走亮色系（inkOnGlass* / titleText 皆浅色）。
namespace {
constexpr QColor rgb(uint value, float alpha = 1.0f) {
    return QColor((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, int(alpha * 255));
}
}

namespace Theme {
const QColor windowTop = rgb(0x3C4248);    // 壳顶（较亮的炭灰）
const QColor windowBottom = rgb(0x1C2024); // 壳底（沉下去）
const QColor panel = rgb(0x2A2E32);
const QColor skinEdge = rgb(0x565C62); // 边缘微亮描边（玻璃轮廓）
const QColor innerHighlight = QColor(255, 255, 255, int(0.22 * 255));
const QColor shellDivider = rgb(0x4A5056);

const QColor titleTop = rgb(0x454B51);
const QColor titleBottom = rgb(0x262A2E);
const QColor titleText = rgb(0xEDEFF1); // 深底亮字

const QColor wellTop = rgb(0x14171A);
const QColor wellBottom = rgb(0x0C0E10);
const QColor listBackground = rgb(0x101315);
const QColor wellBevelDark = rgb(0x000000);
const QColor wellBevelLight = rgb(0x454B51);
// 滑槽：比壳更沉一档，深玻璃上读作一条微凹轨道。
const QColor groove = rgb(0x24282C);

const QColor textPrimary = rgb(0xE8EAEC);
const QColor textSecondary = rgb(0xA6ACB2);
const QColor textAccent = rgb(0xF2A93B); // 橙黄 accent
const QColor textHighlight = rgb(0xFFFFFF);

const QColor buttonLightTop = rgb(0x4E545A);
const QColor buttonLightMid = rgb(0x3A3E42);
const QColor buttonLightBottom = rgb(0x24282C);
const QColor buttonDownTop = rgb(0x24282C);
const QColor buttonDownMid = rgb(0x33373B);
const QColor buttonDownBottom = rgb(0x4A5056);
const QColor buttonTop = rgb(0x4A5056);
const QColor buttonBottom = rgb(0x2C3034);
const QColor buttonHotTop = rgb(0x565C62);
const QColor buttonHotBottom = rgb(0x383C40);
const QColor buttonFace = rgb(0x3A3E42);
const QColor buttonHot = rgb(0x484C50);
const QColor buttonPressed = rgb(0x22262A);
const QColor buttonEdge = rgb(0x5A6066);
const QColor border = rgb(0x4A5056);

const QColor flatText = rgb(0xE0E2E4);
const QColor flatTextHot = rgb(0xFFFFFF);
const QColor flatHotBG = rgb(0x4A5056, 0.55f);
const QColor flatEdgeHot = rgb(0x6A7076, 0.8f);
const QColor flatTextOnLight = rgb(0xE0E2E4);
const QColor flatTextOnLightHot = rgb(0xFFFFFF);
const QColor flatHotOnLightBG = rgb(0x4A5056, 0.9f);

// 频谱：落在深底上，柱色走橙黄 accent（底部深、顶部亮），峰帽暖白，网格淡墨。
const QColor spectrumTop = rgb(0xF7C860);
const QColor spectrumBottom = rgb(0xE08A20);
const QColor spectrumPeak = rgb(0xFFF2D0);
const QColor spectrumGrid = rgb(0x8A9096, 0.15f);

const QColor meterGreen = rgb(0x7FD08A);
const QColor meterYellow = rgb(0xF0DC82);
const QColor meterRed = rgb(0xE88C7A);

// 区域之间 1px 发丝分隔线（深底上取微亮灰，静止时低调）。
const QColor hairline = rgb(0x5A6066, 0.5f);
// 深底亮字：壳/well 都是深色，前景走亮色系。
const QColor inkOnGlass = rgb(0xEDEFF1);       // 主文字
const QColor inkOnGlassSoft = rgb(0xB0B6BC);   // 次级文字
const QColor inkOnGlassAccent = rgb(0xF2A93B); // 强调/选中（橙黄 accent）
} // namespace Theme

namespace Fonts {
// 跨平台字体栈：Qt 逐族回退取首个可用，末位 sans-serif 保证一定有匹配（消除 macOS
// 专有 .AppleSystemUIFont 在 Windows/Linux 上的 "missing font family" 回退不一致）。
static QFont uiFont(int pt, bool bold) {
    QFont f;
#ifdef Q_OS_MACOS
    // macOS：只列本机确定存在的族（Helvetica Neue 拉丁 + PingFang SC 中文），避免
    // QCocoa 逐族解析别名时打 "Populating font family aliases ... missing font family"
    // 告警（Arial/Noto/DejaVu/Microsoft YaHei/sans-serif 在 macOS 上都不是实存族名，
    // 列了只会拖慢启动）。Helvetica Neue 恒在，无需 generic 兜底；styleHint 已是 SansSerif。
    f.setFamilies({QStringLiteral("Helvetica Neue"), QStringLiteral("PingFang SC")});
#else
    f.setFamilies({QStringLiteral("Helvetica Neue"), QStringLiteral("Arial"), QStringLiteral("Noto Sans"),
                   QStringLiteral("DejaVu Sans"), QStringLiteral("PingFang SC"), QStringLiteral("Microsoft YaHei"),
                   QStringLiteral("sans-serif")});
#endif
#ifdef Q_OS_WIN
    // Windows：Segoe UI 做拉丁字体优先，中文用微软雅黑 UI 打头，字号减 1 pt。
    --pt;
    QStringList families = f.families();
    families.removeAll(QStringLiteral("Segoe UI"));
    families.removeAll(QStringLiteral("Microsoft YaHei UI"));
    families.removeAll(QStringLiteral("Microsoft YaHei"));
    families.prepend(QStringLiteral("Segoe UI"));
    families.prepend(QStringLiteral("Microsoft YaHei"));
    families.prepend(QStringLiteral("Microsoft YaHei UI"));
    f.setFamilies(families);
#endif
    f.setStyleHint(QFont::SansSerif);
    f.setPointSize(pt);
    f.setBold(bold);
    return f;
}
const QFont base = uiFont(13, false);
const QFont small = uiFont(12, false);
const QFont tiny = uiFont(11, false);
const QFont title = uiFont(13, true);
const QFont panelTitle = uiFont(13, true);

static QFont numericFont(const QFont &textFont) {
#ifdef Q_OS_WIN
    QFont f = textFont;
    // 纯数字/时间/百分比用 Segoe UI；静态创建，绘制时不重建字体族列表。
    QStringList families = f.families();
    families.removeAll(QStringLiteral("Segoe UI"));
    families.prepend(QStringLiteral("Segoe UI"));
    f.setFamilies(families);
    return f;
#else
    return textFont;
#endif
}
const QFont numericSmall = numericFont(small);
const QFont numericTiny = numericFont(tiny);
} // namespace Fonts

void Theme::applyAppStyle(QApplication *app) {
    // 1) 控件风格统一走 Fusion：不受各 OS 原生 style（mac=aqua / win=vista / linux=gtk）影响。
    if (QStyle *fusion = QStyleFactory::create(QStringLiteral("Fusion"))) app->setStyle(fusion);
    // 2) 固定调色板：与皮肤同调（浅壳配深字、深槽配亮字），不随系统深/浅色漂移。
    QPalette pal;
    pal.setColor(QPalette::Window, Theme::panel);
    pal.setColor(QPalette::WindowText, Theme::titleText);
    pal.setColor(QPalette::Base, Theme::listBackground);
    pal.setColor(QPalette::Text, Theme::textPrimary);
    pal.setColor(QPalette::Button, Theme::panel);
    pal.setColor(QPalette::ButtonText, Theme::titleText);
    pal.setColor(QPalette::Highlight, Theme::textAccent);
    pal.setColor(QPalette::HighlightedText, Theme::wellBevelDark);
    pal.setColor(QPalette::ToolTipBase, Theme::panel);
    pal.setColor(QPalette::ToolTipText, Theme::titleText);
    pal.setColor(QPalette::PlaceholderText, Theme::textSecondary);
    app->setPalette(pal);
    // 3) 应用级默认字体：未显式 setFont 的原生控件也拿到同一跨平台字体栈。
    app->setFont(Fonts::base);
}

GlassNotifier &GlassNotifier::instance() {
    static GlassNotifier n;
    return n;
}

void GlassStyle::setEnabled(bool on) {
    if (on == s_enabled) return;
    s_enabled = on;
    GlassNotifier::instance().changed();
}

void GlassStyle::setTransparency(float v) {
    const float clamped = qBound(0.0f, v, 1.0f);
    if (qAbs(clamped - s_transparency) <= 0.001f) return;
    s_transparency = clamped;
    GlassNotifier::instance().changed();
}
