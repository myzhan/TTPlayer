#include "EQ.h"

#include <algorithm>
#include <cmath>

const std::array<double, Equalizer::kBands> &Equalizer::frequencies() {
    static constexpr std::array<double, kBands> f {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    return f;
}

void Equalizer::setGains(const std::array<double, kBands> &gainDb) {
    std::array<double, kBands> clamped;
    std::transform(gainDb.begin(), gainDb.end(), clamped.begin(),
                   [](double g) { return std::clamp(g, -12.0, 12.0); });
    if (clamped == m_gains) return;
    m_gains = clamped;
    recompute();
}

void Equalizer::setSampleRate(double rate) {
    if (rate <= 0 || rate == m_rate) return;
    m_rate = rate;
    recompute();
}

/// RBJ peakingEQ：Q=1.0（经典图示均衡的带宽手感，先钉死，后接均衡器窗可调）
void Equalizer::recompute() {
    const double sr = m_rate;
    for (int b = 0; b < kBands; ++b) {
        const double a = std::pow(10.0, m_gains[b] / 40.0);          // 线性幅度
        const double w0 = 2.0 * 3.14159265358979323846 * std::min(frequencies()[b], sr * 0.45) / sr;
        const double alpha = std::sin(w0) / 2.0;                     // Q = 1
        const double a0 = 1.0 + alpha / a;
        // 标准式：b0 = 1 + alpha*a, b1 = -2cos(w0), b2 = 1 - alpha*a,
        //         a1 = -2cos(w0), a2 = 1 - alpha/a  （同除 a0 = 1 + alpha/a）
        const double b0 = (1.0 + alpha * a) / a0;
        const double b1 = (-2.0 * std::cos(w0)) / a0;
        const double b2 = (1.0 - alpha * a) / a0;
        const double a1 = (-2.0 * std::cos(w0)) / a0;
        const double a2 = (1.0 - alpha / a) / a0;
        for (int ch = 0; ch < 2; ++ch) {
            auto &q = m_ch[ch][b];
            q.b0 = b0; q.b1 = b1; q.b2 = b2; q.a1 = a1; q.a2 = a2;
        }
    }
}

void Equalizer::process(float *l, float *r, int frames) {
    if (!m_enabled) return;
    // Keep one filter's history in registers for the entire callback block.
    // The band order and intermediate float rounding stay the same for each sample.
    for (int band = 0; band < kBands; ++band) {
        auto left = m_ch[0][band];
        auto right = m_ch[1][band];
        for (int frame = 0; frame < frames; ++frame) {
            l[frame] = left.step(l[frame]);
            r[frame] = right.step(r[frame]);
        }
        m_ch[0][band] = left;
        m_ch[1][band] = right;
    }
}

void Equalizer::reset() {
    for (int ch = 0; ch < 2; ++ch)
        for (int b = 0; b < kBands; ++b) m_ch[ch][b] = {};
}
