#pragma once

// 10 段图示均衡：RBJ peaking biquad，处理链上与 AVAudioUnitEQ 位置对应
// （playerNode → [EQ] → fade → 音量 → 设备）。系数按采样率预算，换率重算。

#include <array>

class Equalizer {
public:
    static constexpr int kBands = 10;
    static const std::array<double, kBands> &frequencies();

    /// gainDb 每段 [-12, 12]；越界夹掉（与 Swift 版滑块量程一致）
    void setGains(const std::array<double, kBands> &gainDb);
    const std::array<double, kBands> &gains() const { return m_gains; }
    void setEnabled(bool on) { m_enabled = on; }
    bool enabled() const { return m_enabled; }
    void setSampleRate(double rate);

    /// 就地处理非交织立体声一段
    void process(float *l, float *r, int frames);

    void reset();

private:
    struct Biquad {
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
        double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        inline float step(float in) {
            const double out = b0 * in + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = in; y2 = y1; y1 = out;
            return float(out);
        }
    };
    void recompute();

    std::array<double, kBands> m_gains {};
    std::array<Biquad, kBands> m_ch[2];
    double m_rate = 44100;
    bool m_enabled = false;
};
