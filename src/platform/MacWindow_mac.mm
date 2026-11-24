#include "platform/MacWindow.h"

#include <QGuiApplication>
#include <QWindow>
#include <QWidget>

#import <AppKit/AppKit.h>

bool macApplyPanelUtility(QWidget *panel) {
    if (!panel) return false;
    // offscreen / minimal 等无头平台下 winId() 不是 NSView*，向它发消息会崩；
    // 只在真正的 cocoa 平台上取原生 NSWindow。
    if (QGuiApplication::platformName() != QLatin1String("cocoa")) return false;
    QWindow *handle = panel->windowHandle();
    // 平台窗未暴露（未 realize）时 winId() 不是有效的 NSView*，强转后 ARC 会在
    // objc_retain 上崩溃；返回 false 让调用方（SkinWindow 的有界重试）择机再来。
    if (!handle || !handle->isExposed()) return false;
    // Qt/macOS 上已暴露的顶层窗，winId()（WId）承载内容 NSView*；其 .window 即 NSWindow。
    // __unsafe_unretained 避免强引用赋值时的 objc_retain（万一指针仍非法不会先于校验崩溃）。
    void *ptr = reinterpret_cast<void *>(handle->winId());
    if (!ptr) return false;
    __unsafe_unretained NSView *view = (__bridge NSView *)ptr;
    if (![view isKindOfClass:[NSView class]]) return false;
    NSWindow *window = view.window;
    if (!window) return false;
    // Qt::Tool 建的 NSPanel 默认失焦即隐藏，副面板不该跟着主窗失焦一起消失。
    window.hidesOnDeactivate = NO;
    // 置顶态由 Qt::WindowStaysOnTopHint 决定：置顶=浮动层，不置顶=普通层（能被别的 app 覆盖）。
    const bool pinned = handle->flags().testFlag(Qt::WindowStaysOnTopHint);
    window.level = pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    // App Exposé（Dock「显示所有窗口」）剔除只认非普通层，collectionBehavior 与 utility
    // style mask 均无效（实测）。不置顶时靠 child window 关系把面板并入主窗，令其在普通层
    // 也只占主窗那一个 tile；置顶=浮动层本身即被剔除，不必挂 child（也保住“脱离后原地不动”）。
    if (!pinned) {
        if (QWidget *owner = panel->parentWidget()) {
            QWindow *ownerHandle = owner->windowHandle();
            if (ownerHandle && ownerHandle->isExposed()) {
                void *optr = reinterpret_cast<void *>(ownerHandle->winId());
                if (optr) {
                    __unsafe_unretained NSView *ov = (__bridge NSView *)optr;
                    if ([ov isKindOfClass:[NSView class]]) {
                        NSWindow *ow = ov.window;
                        if (ow && ow != window && ![ow.childWindows containsObject:window]) {
                            [ow addChildWindow:window ordered:NSWindowAbove];
                            // 失焦→回焦后挂上的 child 不会被自动排到可见层（occlusionState 缺
                            // Visible 位、面板“消失”）；显式抬到可见。orderFrontRegardless 不抢焦点。
                            [window orderFrontRegardless];
                        }
                    }
                }
            }
        }
    } else {
        // 取消浮动时把残留的 child 关系也拆掉，免得它既置顶又被绑在窗上。
        for (NSWindow *ow in [NSApp windows])
            [ow removeChildWindow:window];
    }
    return true;
}
