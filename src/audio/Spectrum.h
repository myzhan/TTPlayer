#pragma once

// 频谱分析：2048 点 radix-2 FFT + 64 段对数频带（输出口径固定）。
// 回调线程 feed() 只拷贝环形缓冲（微秒级），UI 线程 analyze() 才付 FFT 的钱。

#include <cstdint>
#include <vector>

class SpectrumAnalyzer {
public:
    static constexpr int kBands = 64;

    void setSampleRate(double rate);

    /// 音频回调线程：喂非交织立体声（混成单声道即可，柱状图不分工）
    void feed(const float *l, const float *r, int frames);

    /// UI 线程：取最近一窗的 64 段能量（0..1，已开方压动态范围）；未 enable 时直接返回 false
    bool bands(float *out /*[kBands]*/);

    void setEnabled(bool on) { m_enabled = on; }
    bool enabled() const { return m_enabled; }

private:
    static constexpr int kFFTSize = 2048;
    static constexpr int kRingSize = 4096;

    void ensureTables();

    std::vector<float> m_ring;
    uint32_t m_ringWrite = 0;
    bool m_enabled = true;
    double m_rate = 44100;

    // FFT 工作区（仅 analyze 线程访问）
    std::vector<float> m_re, m_im, m_window;
    std::vector<uint32_t> m_bitRev;
    std::vector<float> m_bandLo, m_bandHi;
};
