#include "Spectrum.h"

#include <cmath>

void SpectrumAnalyzer::setSampleRate(double rate) {
    if (rate <= 0 || rate == m_rate) return;
    m_rate = rate;
    m_bandLo.clear();   // 频带边界随采样率重算（ensureTables 里懒做）
}

void SpectrumAnalyzer::feed(const float *l, const float *r, int frames) {
    if (!m_enabled) return;
    if (m_ring.empty()) m_ring.assign(kRingSize, 0.0f);
    for (int i = 0; i < frames; ++i) {
        m_ring[m_ringWrite] = (l[i] + r[i]) * 0.5f;
        m_ringWrite = (m_ringWrite + 1) % kRingSize;
    }
}

void SpectrumAnalyzer::ensureTables() {
    if (!m_re.empty()) return;
    m_re.assign(kFFTSize, 0.0f);
    m_im.assign(kFFTSize, 0.0f);
    m_window.assign(kFFTSize, 0.0f);
    m_bitRev.assign(kFFTSize, 0);
    for (int i = 0; i < kFFTSize; ++i) {
        // Hann 窗：压频谱泄漏，柱高更接近听感
        m_window[i] = float(0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * i / (kFFTSize - 1)));
        uint32_t rev = 0;
        for (int b = 0; b < 11; ++b) rev |= (uint32_t(i >> b) & 1) << (10 - b);
        m_bitRev[i] = rev;
    }
    // 64 段对数频带：30 Hz ~ min(16k, nyquist)
    m_bandLo.assign(kBands, 0);
    m_bandHi.assign(kBands, 0);
    const double nyq = m_rate * 0.5;
    const double lo = 30.0, hi = std::min(16000.0, nyq * 0.98);
    const double binsPerHz = kFFTSize / m_rate;
    for (int b = 0; b < kBands; ++b) {
        const double f0 = lo * std::pow(hi / lo, double(b) / kBands);
        const double f1 = lo * std::pow(hi / lo, double(b + 1) / kBands);
        m_bandLo[b] = float(std::max(1.0, std::floor(f0 * binsPerHz)));
        m_bandHi[b] = float(std::max(double(m_bandLo[b]) + 1.0, std::ceil(f1 * binsPerHz)));
    }
}

bool SpectrumAnalyzer::bands(float *out) {
    if (!m_enabled) return false;
    if (m_ring.size() < kFFTSize) return false;
    ensureTables();

    // 取最近 kFFTSize 个样本（环形缓冲回卷拷贝）
    const uint32_t start = (m_ringWrite + kRingSize - kFFTSize) % kRingSize;
    for (int i = 0; i < kFFTSize; ++i) {
        m_re[i] = m_ring[(start + i) % kRingSize] * m_window[i];
        m_im[i] = 0.0f;
    }

    // 原位 radix-2 FFT
    for (uint32_t i = 0; i < kFFTSize; ++i) {
        const uint32_t j = m_bitRev[i];
        if (j > i) { std::swap(m_re[i], m_re[j]); std::swap(m_im[i], m_im[j]); }
    }
    for (int len = 2; len <= kFFTSize; len <<= 1) {
        const double ang = -2.0 * 3.14159265358979323846 / len;
        const float wr = float(std::cos(ang)), wi = float(std::sin(ang));
        for (int i = 0; i < kFFTSize; i += len) {
            float curR = 1.0f, curI = 0.0f;
            for (int j = 0; j < len / 2; ++j) {
                const float ur = m_re[i + j], ui = m_im[i + j];
                const float vr = m_re[i + j + len / 2] * curR - m_im[i + j + len / 2] * curI;
                const float vi = m_re[i + j + len / 2] * curI + m_im[i + j + len / 2] * curR;
                m_re[i + j] = ur + vr; m_im[i + j] = ui + vi;
                m_re[i + j + len / 2] = ur - vr; m_im[i + j + len / 2] = ui - vi;
                const float nR = curR * wr - curI * wi;
                curI = curR * wi + curI * wr;
                curR = nR;
            }
        }
    }

    // 功率 → 每带均值 → sqrt 压动态范围
    for (int b = 0; b < kBands; ++b) {
        double sum = 0;
        int n = 0;
        const int lo = int(m_bandLo[b]), hi = std::min(int(m_bandHi[b]), kFFTSize / 2);
        for (int k = lo; k < hi; ++k) {
            sum += double(m_re[k]) * m_re[k] + double(m_im[k]) * m_im[k];
            ++n;
        }
        const double avg = n > 0 ? sum / n : 0.0;
        out[b] = float(std::min(1.0, std::sqrt(avg * 4.0 / kFFTSize) * 2.0));
    }
    return true;
}
