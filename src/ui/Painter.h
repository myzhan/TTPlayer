#pragma once

// 自绘工具：统一毛玻璃重构后，全窗只有一套玻璃语言——
//   浅蓝玻璃底（drawBody）+ 1px 发丝分隔（drawHairline）+ 控件静止透明/仅 hover 轻亮（drawHoverFace）。
// 旧的三段面凸起按钮（drawGlassButton）与深蓝内嵌槽（drawWell 的暗压边）一并退役。
// 玻璃 alpha 一律从 GlassStyle::glassAlpha() 取单一值。

#include <QColor>
#include <QRectF>

class QPainter;

namespace Painter {

/// 统一玻璃层：竖向渐变 top→bottom + 外描边 + 可选上半反光。alpha 单一（glassAlpha）。
/// 内容区不再铺深蓝槽，直接复用这一层（top/bottom 传 windowTop/windowBottom）。
void drawBody(QPainter *p, const QRectF &rect, const QColor &top, const QColor &bottom,
              float alpha, qreal radius, const QColor &edge, bool gloss);

/// 兼容旧签名：统一后与 drawBody 同调（不再画暗压边），仅铺统一玻璃 + 可选发丝边。
void drawWell(QPainter *p, const QRectF &rect, const QColor &top, const QColor &bottom,
              float alpha, qreal radius);

/// 控件表面：静止完全透明（仅可选极淡发丝），hover 轻亮一层半透白，pressed 再深一档。
/// 这是统一毛玻璃下所有按钮/行/标签的唯一画法。
void drawHoverFace(QPainter *p, const QRectF &rect, bool hot, bool pressed,
                   qreal radius, bool hairlineRest = false);

/// 1px 发丝分隔线（水平或垂直），用于区域之间取代深槽压边与 groupbox 边框。
void drawHairline(QPainter *p, const QRectF &rect, bool horizontal);

} // namespace Painter
