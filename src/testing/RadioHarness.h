#pragma once

#include <QTextStream>

class AudioEngine;
class PlayerController;

// R08 取证 harness：本机假电台（QTcpServer）模拟四种网络病态，验证「UI 线程的
// 开流 / 停止」都不被网络阻塞拖死。每次进程只跑一种模式（TTPLAYER_QT_RADIOLIVE_MODE），
// 因为一旦命中「阻塞」就要 _exit——泄漏的阻塞线程会污染同进程后续操作。
//
//   noresp        连上但不发任何字节（含响应头）   → 开流(find_stream_info)应可被取消，UI 不冻
//   slow          慢首包（头/字节每 ~400ms 挤一点）  → 同上，开流不能无限期占 UI
//   stall         发够探测+起播后停发但不断开         → 播放中断流，stop() 不能卡在引擎锁上
//   disconnect    发够后直接关连接                     → 优雅 EOF，stop() 照常秒回
//
// 断言口径：开流与 stop 各自实测耗时；任一超过门槛即 FAIL。before（回调持锁做阻塞 IO）
// 会在 stall 模式让 stop 挂死 → _exit(BLOCKED)；after 应全部在门槛内返回。
int runRadioLiveProbe(AudioEngine *engine, PlayerController &controller, QTextStream &out);
