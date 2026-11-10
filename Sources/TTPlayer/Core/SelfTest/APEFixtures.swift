import Foundation

/// APE 自测样本：官方 monkeys-audio 命令行编出来的真码流，base64 内联在源码里。
///
/// 为什么内联而不是放素材目录：本项目只实现了 APE **解码器**，自测没法像 TTA 那样
/// 现场编一份出来；而 `testlib/` 在 .gitignore 里，拿它当唯一素材源的话，
/// 别人 clone 下来这条用例就永远是 SKIP。
///
/// 内容都是 8kHz / 1200 块（0.15 秒）的平包络正弦，幅度 0.9：短到能嵌、长到能跨过预测器
/// 与 NN 滤波器的 512 块滚动窗口。四份样本各盖一条生产分支：
/// 单声道 16bit、联合立体声 16bit、8bit、24bit。
///
/// 重新生成：历史上由 `build/ape-ref/make_fixtures.py` 一次性从上游 mac CLI 产出，v1.19
/// 将解码改接 FFmpeg 后对字工具链已删除（base64 内联的真码流本身仍保留，当下 FFmpeg
/// 开 APE 能嗅探到就行，不再要求逐样本与上游一致）。
enum APEFixtures {
    struct Fixture {
        /// 报错时说的名字
        let name: String
        /// 落临时文件时用的 ASCII 名
        let key: String
        /// 编码时用的压缩级别（只作说明用，参数以文件头为准）
        let level: String
        let channels: Int
        let bitsPerSample: Int
        let sampleRate: Int
        /// 每声道的采样数（APE 叫「块」）
        let blocks: Int
        /// 左声道的正弦频率，用来验波形没解歪
        let leftTone: Double
        /// 右声道频率（立体声才是左边的 1.5 倍，单声道没有）
        let rightTone: Double?
        /// 正弦幅度（0…1）：自测拿它把样本重算一遍当答案，所以这几个字段得和编码时的算式一致
        let toneAmp: Double

        var data: Data { Data(base64Encoded: base64.joined()) ?? Data() }
        private let base64: [String]

        init(name: String, key: String, level: String, channels: Int, bitsPerSample: Int,
             sampleRate: Int, blocks: Int, leftTone: Double, rightTone: Double?,
             toneAmp: Double, base64: [String]) {
            self.name = name
            self.key = key
            self.level = level
            self.channels = channels
            self.bitsPerSample = bitsPerSample
            self.sampleRate = sampleRate
            self.blocks = blocks
            self.leftTone = leftTone
            self.rightTone = rightTone
            self.toneAmp = toneAmp
            self.base64 = base64
        }
    }

    static let mono16 = Fixture(
        name: "单声道 16bit", key: "mono16", level: "Normal",
        channels: 1, bitsPerSample: 16,
        sampleRate: 8000, blocks: 1200, leftTone: 440.0, rightTone: nil,
        toneAmp: 0.9,
        base64: [
        "TUFDIJYPAAA0AAAAGAAAAAQAAAAsAAAAzAMAAAAAAAAAAAAAvILK/+VCF7QtsarrwfdM/tAHAAAAIAEAsAQAAAEAAAAQAAEA",
        "QB8AAHwAAABSSUZGhAkAAFdBVkVmbXQgEAAAAAEAAQBAHwAAgD4AAAIAEABkYXRhYAkAAL+b9Qc4JgAAI7UCdTSd4iA9WZ3T",
        "gDubV8YXAh/B+bw2RszLYdAYOotpr7SxqeBn9022ca6PqCg1x+73imB2lESeyHeNvJlxTRqxwVzTtdP5NAVPRx8zaiV/KPbG",
        "HNtkwn0S6Wbn+mSjB+DtjTHkJB2KxM/ZPwW9HWKCZQsR+6A8/+1sYyTMomDrlAoIU2qk/rK5fj07ViQ/tnPU4l0ODEeRwJzw",
        "9B/UxngLht5RVJ6KDf+/lgqIGjJk0ZYzYDEZKnjMoTAGlhinguk6dpbRjjs6uzrENNbE+sDKZK/opLKR7W+MvBdf9As3/rMU",
        "eEOifem6QoiNKOF/gzTc2A++nS4YRD6VfaJ9KT6g/46WfvUmmegs2fSje7BFSJn/C3BCDK201J7JBOlXmIQuWl0t1uMy/Gg9",
        "A2SfWe+bEM7yrsTKHmsm7T3FnNC3x1kaAudG/trbN6dGM1amNGBtXYpiTiyoKI+Jlwt1CcthGKRIS3fCwifxReJd9U1As/pp",
        "e2vIuAKA/Zw+mtqWdwiJViGbzq82VTamF+Xq20tb3G9/5vHLj3XRDu9plByR0sDp27yMYXSAFpgu/yo7bS/vpX5IAC7UIkdS",
        "JtFfispMRM6mOnOrS/QD9N7RwiDEvq5YigxHkXXU8yGOyexGlpBJBa9SnYs20bG6guLZtlYyuaHWmcoGwMvR4B+z4tPbsoZS",
        "9cwmglr+a+zpCvUSiZbOzqhAtOOg/Fp7S3ngAO/wyxsV0qNZ5JeOwlgNMbSmD1o37JL4BE4MEXiyM0fEg8mDeS9r8t22ehMe",
        "ywAIbz8z/l7ci/eUYH0TeW1B8H6FHK8b1aT460/08b6UZZpeZu/roJjA7zhjLQvJt/evsoadd61B2kcWK8eqXZHFrg3NeFfd",
        "TwkDL3vipgN1u/UEcfgRf7uMSwk3x3sjpR+ETzfMlwxEmpa93LxyGf+WC3lGQCTSGhSnUqkxSdFkmParI7RGaHAmBzRYfIVM",
        "6ILILnsolYnV/x9B1loeJJfebYuJSjolrV2HrMdve1pFAzmaWYM6bAWPg6k0m0JcFr3uivSupYpUC+1emJfSm8VX2p25AqoA",
        "0j+h6R4T/O7dQEsJN7Ca12KM7mmjFv+Nd16Ku+iZI4GRd+LyE13eOHrh3PpNw7zcBIN3NrspYLYUNtEIH5ykgF5TmdNnfbCC",
        "iCtIq2ZmLi7iKPZ16oa97uPQUGv3SNd7t+qWzaqDiPwo89vyAVlJojp1GbhEspfOhMRoYfjGWIB1kccVYDjql51AwVy8EnBI",
        "tNo3Td6+ZZsAAACEAAAAAA==",
        ])

    static let stereo16 = Fixture(
        name: "立体声 16bit", key: "stereo16", level: "High",
        channels: 2, bitsPerSample: 16,
        sampleRate: 8000, blocks: 1200, leftTone: 440.0, rightTone: 660.0,
        toneAmp: 0.9,
        base64: [
        "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",
        ])

    static let stereo8 = Fixture(
        name: "立体声 8bit", key: "stereo8", level: "High",
        channels: 2, bitsPerSample: 8,
        sampleRate: 8000, blocks: 1200, leftTone: 440.0, rightTone: 660.0,
        toneAmp: 0.9,
        base64: [
        "TUFDIJYPAAA0AAAAGAAAAAQAAAAsAAAA3AMAAAAAAAAAAAAAhyW3i9oTXAWtM+enL5uEn7gLAAAAIAEAsAQAAAEAAAAIAAIA",
        "QB8AAHwAAABSSUZGhAkAAFdBVkVmbXQgEAAAAAEAAgBAHwAAgD4AAAIACABkYXRhYAkAAIKSiQcAAAAA7mPeHg+3ovVICFu2",
        "gTqYcr2rwsmUJ3aIOKy2hbVmOVdm1SesTpXobE+jXk62Zua0ZY8/4FANI/y3KyP5/kJIuNMkjjtMRHE/Dganoay/xWxJbIVo",
        "lNoVBRZBeihJwbQqdTUoeTaZ3d233ZGRnWJLVSebbSuTkDr7wIyQdARNffkzff3/yfKaJ4mIK5B6GDhkksQujfFYiT4LP/ue",
        "Shb+e7vt98LWygQ/+TZwTxj7+xpFCgafA+UXjn8CeSrqtHQLadcpHUNbRHnM/SeyE6DhH+1jLh2z2aZD4bAPU/WuNOdpHP8S",
        "aL8mpYXYlZ4bDKztznSMuR+IQWi47DJHtn1Ac0GOVPsiqzvkRGLXEKvbsTpQOe9RY3770tgrp26B0BfrDV5qXpPo1pM+HD3N",
        "3h9EHsvoVLjimy/XK+Jbyp5EPR3MXSQXgNmTFTtSfza28BltR/HcLJ4BpmERCC3NTTNqrwcIjp5gpK9zSOMFY4TzT3Kxozkj",
        "ZuOXAEzOe2rfAyY/J0EwFqRUs6dJVFgZ73G6bTTwcdGxuq3xN2fdwId4/hnAJ5M5GcJ0Qrc4173L4RLjz81y3DP7AVfGeFSL",
        "HPDcnBvcGqHqCpKqd2VNYdxTcluGrBcXsPNE9mKDKNTQSOxKSf6vtrFrN+00LffAERk5/LeiIjwSvzJiatm+LUfFoISvUXQI",
        "mMBLRUeCRxV8BRn5daNUAemQXv1IdhBAnBxX1nDtYSxzojQ60p4r8jPE7nE59ZE/k6JGDldeT1nOwVa4b9EKv2IqHt74XEUr",
        "c+jWQaIoehlLboTL+k9DhmMl5oMWEXPmhhp1Br/ognunfaTn8yNqrvkAuDAVDLy0xiKaUQT2S+DLikfVZbbZWjgFpCXWye6+",
        "2hnvidI4WSQWA/idCrgMW2KR344maFmHwvgr3h58v7qUpxRK5ds6IZGsDvOqGsxuAjCB0RRXTimWFA28yux+BRBm3V2jpj+R",
        "ITDMXLb60jTJ59IwtWRXZhIC9fr2P5Nq8IYoY2sYaGeWqqpJAhfme6j615KW1i1Fel6M+RaVe7pMUl5USqzFyhY/ek1BYX7e",
        "xRKcikjOpBA6QDPB6hNJ2xwnZFFYxN0/1hpM9DG1r6TdY9+XZeqLzlu95NFNDuiwFCr2tXyonTqZLK2huRULoLTlYZy2WeGm",
        "wze4BNvOS17/J//CAvdxGWdzyhD45D/PiLy3iWD4QMet8EfFPtgCy91OZF9Xvv0N8dAiPkvtBOyuUQS0SiLyghPpC4bnWOMb",
        "7shTC6h/3OsUpMKzL8ZQNP7gTZm4wS5teoOpJgAAAAA=",
        ])

    static let mono24 = Fixture(
        name: "单声道 24bit", key: "mono24", level: "High",
        channels: 1, bitsPerSample: 24,
        sampleRate: 8000, blocks: 1200, leftTone: 60.0, rightTone: nil,
        toneAmp: 0.9,
        base64: [
        "TUFDIJYPAAA0AAAAGAAAAAQAAAAsAAAAPAgAAAAAAAAAAAAAU18vVWsYm4tuUAlswDxLjLgLAAAAIAEAsAQAAAEAAAAYAAEA",
        "QB8AAHwAAABSSUZGNA4AAFdBVkVmbXQgEAAAAAEAAQBAHwAAwF0AAAMAGABkYXRhEA4AAJuVkWw7JgAA1gDE2Uiooi0U9NW7",
        "vjJgcxEIHwOL2letR6Yel/5O89GdGPJf/KsOM7M6FuSeKfTfdAzZKTITXf6HQWeboC3jmRpdH/pYFBt3wWecqBj487xaC5rq",
        "M3NUjDyHZ/zigqc5ePVBQRHjeyTKEv4UBtfMyxiO09ph3gkCNcDeASWPlbKWg4yuzw78yOJodAmixlD0mPU3qGSB20bIvBlm",
        "CRnPvxhSmJFbsD2Fn4MSvOQX6FEcNWWAQgH/qeEYJanXZcdJT/GOoKzKkJsqzXtzPhY7oSt3/Z5YLYDnnoJiWT6FSqEEloaK",
        "B15ss5J0JsDH9j+8YMrK2EK50uwJ9S3sp5waDWySOcA5IsW1CIttr/8kSoNkiIpYfsj5PzKhutrRAHHvJyx5FBPYtIxH7drz",
        "ZYOa2uqInN4ud7mxosBCdYNNjRiRRZUlWvgiac9ciajDgzWtFKfN3c6tn/xE0E0hCi++ev/s1dEt771BGfdANJg1rcv+zl06",
        "r/Irufn8vb6L6poBMvN5MvJ4AC5u93mSzp+d3cJ8BDn2ai0V1rp2WfngH8TCghnawcJ19Ufe0QxhItB0YCYl0OEXsGu7B5SH",
        "baoT81BXCxiPgmgn2EcofOj7t/WfBBijiP7tjkZPiY85be3occvCupeDiKq/INWXJ1jrzkvwgyH+U/rJ6VGgxcFOF8FzMKQU",
        "o0VyyW0IzSHGGxBLNiYfMNMILflSlZwfAx1lUMxYYFweGxQ3qybKADHkIY5/0lcaFL+qxSzTwaNhCNTaqdWsSXI9a1KEGPSw",
        "5IZVzEDHNfFnQWTxe8kWF+SyjJ/eZvFF7yGxGw/flSafUZywO8xc5uHV5NXQ6UxGF0cN1xqCalAM06srObwB2CNaGOrOdKWq",
        "0EwwbF4Anf6IiZN71zLg84zIPWFdJg/tRCci0Hmj9PGPYQGVR2TCVMR213leTskj22EZuKWH8DpNyHIamynKWJGHBfqFnhzg",
        "tQJ+QBf7WibGvZfUjWjcdu9ZMxTpt2wuJrkhw9qtX4SmuM71WSLf8F1DbfqYiVWl8dyv0N8U1VX80AJ4G3SGVsXeCbjD4OeF",
        "fTRjzPEJMIuuN3JNgAuNa7u1hLRq38XI1MNkGPNyg8Yn6ZmUgYG1p4ZLb+pYeLCJRtTzXDSvi67cSnUSfhCmX17gIyWWVyZE",
        "5dJiovD84PrZDyCRCuFZJQnx74YK9bpz+Ln1HhzQzQBYai5QrX50pCIl3o1BcwzKyIqgRqM3LLiosMzyPNP4vZYOjtLoOQSy",
        "lqFy6Nv8vBDJNUiWy2Ip773LCANUW0MbEGjFyJdmvTa6FtKhSRquKmRddRQt62j4LbYCK0NpdM5wC6rjuSKz+utB645nkWql",
        "H13qFIXNIlbuc32ecG+9W1F5XsuczAl/sR584ETWZ5huLILaq8H5NWsr0VUJsBwy5h/GolSICgCXHeJ4S3K/wxkrSdOJg94l",
        "g6YTvSEwPfXpkG59726jWtDuYSt/ktcS51mUOTEmavhbh1VHXjluIWM7fEhPOA4dnhNYDhITZyGTAlBfYJKO+Rh7YFLvgIrq",
        "QrXR6W6fe9Ywnki0vZBOzc22dPoZKhgt/NkBcU9fQ5YDx8UGdWP1ajtpgfbulVKewQ0yn+7yKEk96qDRF63+mgWf1WVT1UuD",
        "j94c3gTUNAu7jR4odr3y+C9QtTJqB2jTmpy5g5Uo3bQ/dhMWd8rE/HQqct+ztkif+RX5p0aHVnx3lzLRda/Kx5fnu5Fb0mUk",
        "/QziwKZFmkOtPex4/nSQIZs8h3a46clvtj9eN/8yfu+CcGviq+3zMW9RhgCKjVKEDIW8XAhRHkxZ5TaE14PQ2o5ifErphqUb",
        "r+cxU3FH3E0cu8HLsK1UBnv+zK2KgtDdE7CmcInTW8RTzWpYiXNr1RS+MjZd48ndu6Wd/EzI+bhatG5ASBmcYejizpCHLAHU",
        "VDOvoI+0LRe0N8fQolHO2RBh8lbkn7GgoqE57GmeKcW/GOfDX8Fs5hc4L6ytI7Gr3aLQBgJ+fzN+goCbFa28s86RG0J5L0hu",
        "r7tiIkldSYCUmkjrQLMNEbtRIr0jD5n9H1HkpntMCPWQQKdThEwVFyfh8gqpBS/ihT9sr9PRMuVYYK+aAd8Jg3HYz3C/22tx",
        "Lxa35oTvP7x9uk6n2oiifgffvxXZcHs9teqe1nNItUAb+i/H51chB6G/N54miFj+t+rhTIqWD9WBd15fyjsIuqRDvVhj16Fu",
        "uM1CUyFw9hCdKTvpjy1wIQhGZ4gy0WqSLbIVSGzWn6ek3AYtBmVRNGbOWh5ad4jEvTsEN8jv7vnDPeXkZYqpNFHr5xsa1Ewr",
        "uJAF6wkiZYxwNpTpgJAkOOrDL0aT0/QwnQ0522DmRaZnHxZ+WP6T7J7tI7uL6E4DI5fmTNl2h5CyLhNUFvsMKhf6Xkv52OLq",
        "LvZ3wQd6zZBUpzCypxqDkclJd1Yx9ZqCPPAVXcHcLrWlbl7XmI/77SB5CMAduixg1QsBMzlYq7IIpDfzW+YgV6Wt9WpgVLFq",
        "K3eDZFb7UKJCFJgEd9wwGicXQgBx4qySd5ese6TUXqRRGqfxOV+LG4FxCFCH3Ox+kqZLC+YHRE9J+DjgXhLXZcWVMQSKXbPu",
        "yM0naMUapqoH9dBp5Jhr4GoLDlZwl8bWUa59muLWojmGtEONICuOfjseIqdq8MFY1XwsOc6NwI3NKX0oYjxFzc5QdEOAGDHX",
        "tw4E72RHBRKfzARRzrWesa8fZJ2ytN61iXLUGG5LxWcBmqoAZODNb9MGe5kW4ldFi43wNVAmYlxvfJ69p/RI6AAArvYAAAAA",
        ])

    /// 全部样本
    static let all: [Fixture] = [mono16, stereo16, stereo8, mono24]
}
