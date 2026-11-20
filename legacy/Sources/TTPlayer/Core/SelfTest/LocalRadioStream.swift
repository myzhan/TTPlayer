import Foundation
import Network

/// 自检用的本地电台服务器：只听 127.0.0.1，把一份音频文件按设定速率推给客户端。
///
/// 为什么要有它：需求不许拿公网电台的稳定性当验收凭据（F02「电台不应用前置增益」、
/// F11 的断流/慢速/旧回调/未知码率都要「按剧本演」的流），而真服务器给不了
/// 「发 3 秒就掐断」这种条件。这里发的字节与 AudioToolbox/FFmpeg 收到的完全同源，
/// 走的也是 URLSession → ICY 拆分 → 解码 → playerNode 那条真链路，不是替身。
final class LocalRadioStream {
    struct Config {
        var statusCode = 200
        var statusText = "OK"
        var contentType = "audio/mpeg"
        /// 头部里带的台名；空串 = 不给 icy-name（验「未知值不伪造」）
        var icyName = "TT Local"
        /// >0 就按 ICY 规则每隔这么多音频字节插一块元数据
        var metaint = 0
        /// 第一块 ICY 标题；`titleRefresh` 为真时每次元数据都换一个新序号
        var title = "TT - One"
        var titleRefresh = false
        /// 每秒推多少字节：慢速/欠载场景把它调小
        var bytesPerSecond = 64_000
        /// 推够这么多字节就主动掐断（断流重连场景）；nil = 推完文件后挂住不断
        var closeAfterBytes: Int?
        /// 额外响应头（302 的 Location、未知码率要藏的字段都从这里给）
        var extraHeaders: [(String, String)] = []
    }

    let file: URL
    /// 改动即刻对下一个连接生效（同一个进程里改剧本，不重开服务器）
    var config = Config()
    /// 发送与状态改都跑在 `queue` 上，断言从主线程读，所以这几项统一过一把锁
    private let statLock = NSLock()
    private var _connections = 0
    private var _servedBytes = 0
    private var _lastDropBy = ""
    private var _active: [NWConnection] = []
    /// 累计连接次数与推送字节：断线重连、缓冲不足那些断言都读这里
    var connections: Int { statLock.lock(); defer { statLock.unlock() }; return _connections }
    var servedBytes: Int { statLock.lock(); defer { statLock.unlock() }; return _servedBytes }
    /// 最近一次连接被谁掐的：`self` = 服务器按剧本断的，`client` = 客户端自己停的
    var lastDropBy: String { statLock.lock(); defer { statLock.unlock() }; return _lastDropBy }
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "ttplayer.selftest.radio")

    init(file: URL) {
        self.file = file
    }

    /// 起服务器并返回播放地址（`http://127.0.0.1:端口/live`）。起不来返回 nil
    func start() -> URL? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        let params = NWParameters.tcp
        do {
            let l = try NWListener(using: params, on: .any)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn, body: data) }
            // 端口要等 listener 真起来了才知道（`.any` 让系统挑一个空闲口）
            let sem = DispatchSemaphore(value: 0)
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready:
                    guard let p = l?.port else { return }
                    self.port = p.rawValue
                    l?.stateUpdateHandler = nil
                    sem.signal()
                case .failed, .cancelled:
                    l?.stateUpdateHandler = nil
                    sem.signal()
                default:
                    break
                }
            }
            l.start(queue: queue)
            guard sem.wait(timeout: .now() + 2) == .success, port > 0 else {
                l.cancel()
                return nil
            }
            listener = l
            return URL(string: "http://127.0.0.1:\(port)/live")
        } catch {
            return nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        statLock.lock()
        let list = _active
        _active.removeAll()
        statLock.unlock()
        for c in list { c.cancel() }
    }

    /// 只回错误码就掐断（404/500 之类的失败场景）
    func failWith(status: Int) {
        config.statusCode = status
        config.statusText = status == 404 ? "Not Found" : "Server Error"
        config.bytesPerSecond = 0
        config.closeAfterBytes = 0
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection, body: Data) {
        statLock.lock()
        _connections += 1
        _active.append(conn)
        statLock.unlock()
        let cfg = config
        conn.start(queue: queue)
        // 请求行不必解析：客户端只会发一个 GET，读完第一块就直接回响应头
        var head = "HTTP/1.1 \(cfg.statusCode) \(cfg.statusText)\r\n"
        head += "Content-Type: \(cfg.contentType)\r\n"
        head += "icy-notice1: selftest\r\n"
        if !cfg.icyName.isEmpty { head += "icy-name: \(cfg.icyName)\r\n" }
        if cfg.metaint > 0 { head += "icy-metaint: \(cfg.metaint)\r\n" }
        head += "icy-br: unknown\r\n"          // 故意给个读不出来的值（F11「未知不伪造」）
        for (k, v) in cfg.extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        conn.send(content: head.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.pump(conn, body: body, cfg: cfg, sent: 0, audioInBlock: 0, titleSeq: 0, pushed: 0)
        })
    }

    /// 按速率一块块推。`audioInBlock` 记当前音频段已推多少字节（ICY 元数据要按间隔插），
    /// `pushed` 是这一次连接推了多少（掉线剧本按连接单独算，不被上一个连接干扰）
    ///
    /// 元数据必须正好插在每 `metaint` 个音频字节之后：客户端的 `ICYDemuxer` 是
    /// 按整数字节计数的，多推一个字节它就把下一个音频字节当元数据长度读，整条流从此
    /// 错位（实测：FFmpeg 一路报 invalid band type / TNS filter order，解码器只能拿
    /// 错误补偿填静音，自检偶发「频谱全 0」）。所以跨界那一块要切短，剩下的下一轮再发。
    private func pump(_ conn: NWConnection, body: Data, cfg: Config,
                      sent: Int, audioInBlock: Int, titleSeq: Int, pushed: Int) {
        let leftInBody = body.count - sent % max(1, body.count)
        let chunk = min(8_192, max(1, cfg.bytesPerSecond / 20), leftInBody)
        let start = sent % max(1, body.count)
        var audio = chunk
        if cfg.metaint > 0, audioInBlock + chunk > cfg.metaint {
            audio = cfg.metaint - audioInBlock          // 正好停在元数据边界上
        }
        var out = Data(body[start..<start + audio])
        var metaInserted = false
        if cfg.metaint > 0, audioInBlock + audio == cfg.metaint {
            // 元数据块：1 字节长度（×16）+ 内容，补齐到 16 的倍数
            let text = cfg.titleRefresh ? "\(cfg.title) #\(titleSeq)" : cfg.title
            let kv = "StreamTitle='\(text)';"
            let padded = (kv.count + 15) / 16 * 16
            var meta = Data([UInt8(padded / 16)])
            meta.append(Data(kv.utf8))
            meta.append(Data(repeating: 0, count: padded - kv.count))
            out.append(meta)
            metaInserted = true
        }
        servedBytesAdd(out.count)
        let pushedNow = pushed + audio
        if let cap = cfg.closeAfterBytes, pushedNow >= cap {
            statLock.lock()
            _lastDropBy = "self"
            statLock.unlock()
            conn.cancel()
            return
        }
        let delay = cfg.bytesPerSecond > 0
            ? Double(out.count) / Double(cfg.bytesPerSecond) : 0.2
        conn.send(content: out, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil {
                self.statLock.lock()
                if self._lastDropBy.isEmpty { self._lastDropBy = "client" }
                self._active.removeAll { $0 === conn }
                self.statLock.unlock()
                return
            }
            // 文件推完就从头再来：直播本来就没有「放到结尾」这回事
            let nextSent = sent + audio
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.pump(conn, body: body, cfg: cfg,
                          sent: nextSent >= body.count ? 0 : nextSent,
                          audioInBlock: metaInserted ? 0 : audioInBlock + audio,
                          titleSeq: metaInserted ? titleSeq + 1 : titleSeq,
                          pushed: pushedNow)
            }
        })
    }

    private func servedBytesAdd(_ n: Int) {
        statLock.lock()
        _servedBytes += n
        statLock.unlock()
    }
}
