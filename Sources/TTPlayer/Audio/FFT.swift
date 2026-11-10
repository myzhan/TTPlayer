import Foundation

/// 迭代式 radix-2 FFT（原地计算，输入长度必须是 2 的幂）
enum FFT {
    /// real: 实部（调用结束仍为实部结果）；imag: 虚部，传 nil 表示输入全 0，结束时写回
    /// 注意：传入非 nil 的 imag 时，其内容会作为输入虚部参与运算，实信号需先清零
    static func transform(real: inout [Float], imag: inout [Float]?) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0 else { return }
        var im = imag ?? [Float](repeating: 0, count: n)
        var re = real
        compute(&re, &im)
        real = re
        imag = im
    }

    /// 核心计算（re/im 长度相等且为 2 的幂）
    static func compute(_ re: inout [Float], _ im: inout [Float]) {
        let n = re.count
        guard n > 1 else { return }

        // 位反转置换
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }

        // 蝶形运算
        let pi = Float.pi
        var len = 2
        while len <= n {
            let ang = -2 * pi / Float(len)
            let wRe = cos(ang), wIm = sin(ang)
            let half = len >> 1
            var i = 0
            while i < n {
                var curRe: Float = 1, curIm: Float = 0
                for k in 0..<half {
                    let a = i + k, b = i + k + half
                    let xRe = re[b] * curRe - im[b] * curIm
                    let xIm = re[b] * curIm + im[b] * curRe
                    re[b] = re[a] - xRe
                    im[b] = im[a] - xIm
                    re[a] += xRe
                    im[a] += xIm
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                i += len
            }
            len <<= 1
        }
    }

    /// 实信号的幅度谱（长度 n/2+1），内部完成加窗可选由调用方负责
    static func magnitudes(real: [Float], imag: [Float]) -> [Float] {
        let n = real.count
        var mags = [Float](repeating: 0, count: n / 2 + 1)
        for i in 0...n / 2 {
            mags[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]) / Float(n)
        }
        return mags
    }
}
