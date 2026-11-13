// GalTranslator — 本机翻译中转 + 悬浮字幕窗
//
// 监听 127.0.0.1:47011，所有游戏内的翻译插件都调用它：
//   GET  /health                               → ok
//   GET  /translate?from=ja&to=zh-CN&text=...  → 纯文本译文（XUnity CustomTranslate 用）
//   POST /batch   {"from","to","texts":[...]}  → {"translations":[...]}（整包离线翻译用）
//   POST /overlay {"text","from"?,"to"?}       → 翻译并显示在悬浮字幕窗（Textractor 用）
//   POST /ocr/start {"game","from"?}           → 屏幕识别：截取识别框里的游戏画面，OCR 后翻译显示
//   POST /ocr/stop                             → 停止屏幕识别
//   GET  /ocr/recognize?path=<png>&lang=ja     → 只做一次 OCR（诊断用）
//
// 配置: ~/Games/gal/config/translate.json（GalBox 设置里写入）
// 缓存: ~/Games/gal/cache/translate-<from>-<to>.json，同一句只请求一次
import AppKit
import Network
import ScreenCaptureKit
import SwiftUI
import Vision

let listenPort: UInt16 = 47011
let galHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/gal")
let configURL = galHome.appendingPathComponent("config/translate.json")
let cacheDir = galHome.appendingPathComponent("cache")
let logURL = galHome.appendingPathComponent("logs/translator.log")

// MARK: - 日志

let logQueue = DispatchQueue(label: "log")
func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    logQueue.async {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }
}

// MARK: - 配置

struct TranslateConfig: Codable {
    var provider: String?   // deepseek | openai | echo
    var apiKey: String?
    var model: String?
    var baseURL: String?
    var target: String?

    static func load() -> TranslateConfig {
        guard let d = try? Data(contentsOf: configURL),
              let c = try? JSONDecoder().decode(TranslateConfig.self, from: d) else {
            return TranslateConfig()
        }
        return c
    }
}

func languageName(_ code: String) -> String {
    switch code.lowercased() {
    case "ja", "ja-jp": return "日语"
    case "zh", "zh-cn", "zh-hans", "zh_cn": return "简体中文"
    case "zh-tw", "zh-hant", "zh_tw": return "繁体中文"
    case "en": return "英语"
    case "ko": return "韩语"
    default: return code
    }
}

enum TranslateError: LocalizedError {
    case noKey, http(Int, String), badReply(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "还没有设置翻译服务的 API key（在 GalBox 设置里填写）"
        case .http(let c, let b): return "翻译服务返回 \(c): \(b.prefix(300))"
        case .badReply(let s): return "翻译服务回复无法解析: \(s.prefix(300))"
        }
    }
}

// MARK: - 翻译（带缓存）

actor Translator {
    static let shared = Translator()

    private var caches: [String: [String: String]] = [:]
    private var dirty: Set<String> = []
    private var saveScheduled = false

    private func cacheURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent("translate-\(key).json")
    }

    private func cache(_ key: String) -> [String: String] {
        if let c = caches[key] { return c }
        var c: [String: String] = [:]
        if let d = try? Data(contentsOf: cacheURL(key)),
           let j = try? JSONDecoder().decode([String: String].self, from: d) {
            c = j
        }
        caches[key] = c
        return c
    }

    private func store(_ key: String, _ pairs: [(String, String)]) {
        var c = cache(key)
        for (s, t) in pairs { c[s] = t }
        caches[key] = c
        dirty.insert(key)
        if !saveScheduled {
            saveScheduled = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.flush()
            }
        }
    }

    func flush() {
        saveScheduled = false
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        for key in dirty {
            if let c = caches[key], let d = try? JSONEncoder().encode(c) {
                try? d.write(to: cacheURL(key), options: .atomic)
            }
        }
        dirty.removeAll()
    }

    func translate(_ texts: [String], from: String, to: String) async throws -> [String] {
        let key = "\(from)-\(to)".replacingOccurrences(of: "/", with: "_")
        let c = cache(key)
        var out = texts.map { c[$0] }
        var missing: [String] = []
        for (i, t) in texts.enumerated() where out[i] == nil {
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[i] = t
            } else if !missing.contains(t) {
                missing.append(t)
            }
        }
        if !missing.isEmpty {
            var got: [(String, String)] = []
            var start = 0
            while start < missing.count {
                let chunk = Array(missing[start..<min(start + 40, missing.count)])
                let res = try await callModel(chunk, from: from, to: to)
                got.append(contentsOf: zip(chunk, res).map { ($0, $1) })
                start += chunk.count
            }
            store(key, got)
            let dict = Dictionary(got, uniquingKeysWith: { a, _ in a })
            for i in out.indices where out[i] == nil { out[i] = dict[texts[i]] ?? texts[i] }
        }
        return out.map { $0 ?? "" }
    }

    private func callModel(_ texts: [String], from: String, to: String) async throws -> [String] {
        let cfg = TranslateConfig.load()
        let provider = cfg.provider ?? "deepseek"
        if provider == "echo" { return texts.map { "【译】" + $0 } }

        guard let apiKey = cfg.apiKey, !apiKey.isEmpty else { throw TranslateError.noKey }
        let base = (cfg.baseURL?.isEmpty == false ? cfg.baseURL! : "https://api.deepseek.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = cfg.model?.isEmpty == false ? cfg.model! : "deepseek-chat"

        let system = """
        你是专业的日本 galgame 汉化译者。把输入 JSON 里 texts 数组中的每一条\(languageName(from))文本翻译成\(languageName(to))。
        要求：
        1. 逐条翻译，输出条数和顺序必须与输入完全一致，不要合并或拆分。
        2. 换行、空格、控制符和占位符保持原样，例如 \\n、\\C[1]、\\N[1]、\\V[1]、<...>、{...}、%s、%d、#{...}。
        3. 人名和专有名词前后一致；语气自然，贴合角色口吻；不要添加任何解释或注释。
        4. 已经是目标语言的文本原样返回。
        5. 原文可能来自屏幕文字识别，个别字识别错了时按上下文理解后翻译，不要指出错误。
        只输出 JSON：{"translations": ["...", "..."]}
        """
        let userJSON = String(
            data: try JSONSerialization.data(withJSONObject: ["texts": texts]), encoding: .utf8)!
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userJSON],
            ],
            "temperature": 1.3,
            "response_format": ["type": "json_object"],
            "stream": false,
        ]
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(decoding: data, as: UTF8.self)
        guard code == 200 else { throw TranslateError.http(code, raw) }

        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let arr = inner["translations"] as? [Any]
        else { throw TranslateError.badReply(raw) }

        let res = arr.map { "\($0)" }
        if res.count == texts.count { return res }
        // 条数对不上：逐条重译，保证一一对应
        log("条数不一致（\(texts.count) → \(res.count)），改为逐条翻译")
        if texts.count == 1 { return [res.joined(separator: "\n")] }
        var one: [String] = []
        for t in texts { one.append(contentsOf: try await callModel([t], from: from, to: to)) }
        return one
    }
}

// MARK: - 悬浮字幕窗

@MainActor
final class Overlay: ObservableObject {
    static let shared = Overlay()
    @Published var original = ""
    @Published var translated = "GalTranslator 已启动，游戏文字会显示在这里"
    @Published var locked = false {
        didSet { panel?.ignoresMouseEvents = locked }
    }
    var panel: NSPanel?
    private var lastText = ""

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.backgroundColor = NSColor.black.withAlphaComponent(0.72)
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: OverlayView(model: self))
            p.setFrameAutosaveName("GalTranslatorOverlay")
            if p.frame.origin == .zero, let s = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: s.midX - 380, y: s.minY + 40))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil) } else { show() }
    }

    // 返回 false 表示和上一句相同，不必重复翻译
    func accept(_ text: String) -> Bool {
        if text == lastText { return false }
        lastText = text
        original = text
        translated = "……"
        show()
        return true
    }

    func update(_ text: String) { translated = text }
}

struct OverlayView: View {
    @ObservedObject var model: Overlay
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.original)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(3)
            Text(model.translated)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
    }
}

// MARK: - 屏幕识别（OCR）

func ocrLanguages(_ from: String) -> [String] {
    switch from.lowercased() {
    case "ja", "ja-jp": return ["ja-JP"]
    case "en": return ["en-US"]
    case "ko": return ["ko-KR"]
    case "zh-tw", "zh-hant": return ["zh-Hant"]
    default: return ["ja-JP"]
    }
}

func recognizeText(_ img: CGImage, from: String) async -> String {
    await withCheckedContinuation { cont in
        let req = VNRecognizeTextRequest { r, _ in
            let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
            // 从上到下排；Vision 的坐标原点在左下
            let lines = obs.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
            cont.resume(returning: lines.joined(separator: "\n"))
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ocrLanguages(from)
        req.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: img).perform([req])
            } catch {
                cont.resume(returning: "")
            }
        }
    }
}

// 识别框：半透明橙色边框，拖动和拉伸来框住游戏的对话框
final class FrameView: NSView {
    var locked = false { didSet { needsDisplay = true } }
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        // 完全透明的区域收不到鼠标，解锁时填一层很淡的颜色好拖动
        NSColor.systemOrange.withAlphaComponent(locked ? 0.0 : 0.08).setFill()
        path.fill()
        NSColor.systemOrange.withAlphaComponent(locked ? 0.35 : 0.9).setStroke()
        path.lineWidth = locked ? 1.5 : 3
        path.stroke()
        if !locked {
            let s = "识别区域：拖到游戏对话框上，拖边角调大小，菜单栏「译」里锁定" as NSString
            s.draw(at: NSPoint(x: 10, y: bounds.height - 22), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.systemOrange,
            ])
        }
    }
}

@MainActor
final class OCRController {
    static let shared = OCRController()

    var window: NSWindow?
    var view: FrameView?
    var timer: Timer?
    var game = "default"
    var from = "ja"
    var running = false
    var paused = false
    var locked = false
    private var busy = false
    private var pending = ""
    private var pendingCount = 0
    private var lastShown = ""
    private var content: SCShareableContent?
    private var contentTime = Date.distantPast
    private var warnedPermission = false

    private var frameKey: String { "ocrFrame.\(game)" }

    func start(game: String, from: String, rect: NSRect?) {
        self.game = game
        self.from = from
        running = true
        paused = false
        pending = ""
        pendingCount = 0
        lastShown = ""
        showFrame(rect)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in await OCRController.shared.tick() }
        }
        Overlay.shared.show()
        Overlay.shared.original = ""
        Overlay.shared.translated = "屏幕识别已开启：把橙色框拖到游戏的对话框上，调好后在菜单栏「译」里锁定"
        log("屏幕识别开始: \(game)")
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        saveFrame()
        window?.orderOut(nil)
        log("屏幕识别停止: \(game)")
    }

    func setLocked(_ v: Bool) {
        locked = v
        view?.locked = v
        window?.ignoresMouseEvents = v
        if v { saveFrame() }
    }

    private func defaultRect() -> NSRect {
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: s.minX + s.width * 0.12, y: s.minY + s.height * 0.06,
                      width: s.width * 0.76, height: s.height * 0.22)
    }

    private func showFrame(_ rect: NSRect?) {
        if window == nil {
            let w = NSWindow(contentRect: defaultRect(), styleMask: [.borderless, .resizable],
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .statusBar
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.minSize = NSSize(width: 120, height: 40)
            let v = FrameView()
            w.contentView = v
            window = w
            view = v
        }
        if let rect {
            window?.setFrame(rect, display: true)
        } else if let s = UserDefaults.standard.string(forKey: frameKey) {
            window?.setFrame(NSRectFromString(s), display: true)
        } else {
            window?.setFrame(defaultRect(), display: true)
        }
        setLocked(locked)
        window?.orderFrontRegardless()
    }

    private func saveFrame() {
        if let f = window?.frame { UserDefaults.standard.set(NSStringFromRect(f), forKey: frameKey) }
    }

    private func capture() async -> CGImage? {
        guard let w = window, let screen = w.screen ?? NSScreen.main else { return nil }
        do {
            if content == nil || Date().timeIntervalSince(contentTime) > 5 {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                contentTime = Date()
            }
            guard let content else { return nil }
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            guard let display = content.displays.first(where: { $0.displayID == num?.uint32Value })
                    ?? content.displays.first else { return nil }
            // 截图时排除自己的识别框和字幕窗
            let me = ProcessInfo.processInfo.processIdentifier
            let mine = content.windows.filter { $0.owningApplication?.processID == me }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            let cfg = SCStreamConfiguration()
            let rect = w.frame
            let sf = screen.frame
            cfg.sourceRect = CGRect(x: rect.minX - sf.minX, y: sf.maxY - rect.maxY,
                                    width: rect.width, height: rect.height)
            let scale = screen.backingScaleFactor
            cfg.width = max(1, Int(rect.width * scale))
            cfg.height = max(1, Int(rect.height * scale))
            cfg.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            if !warnedPermission {
                warnedPermission = true
                log("截屏失败: \(error.localizedDescription)")
                Overlay.shared.update("需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕与系统录音，打开 GalTranslator，然后重新启动游戏")
            }
            return nil
        }
    }

    func tick() async {
        guard running, !paused, !busy else { return }
        busy = true
        defer { busy = false }
        guard let img = await capture() else { return }
        let text = await recognizeText(img, from: from)
        let norm = text.filter { !$0.isWhitespace }
        guard norm.count >= 2 else { pendingCount = 0; return }
        // 打字机效果会让文字逐字出现，连续两次识别结果一样才算一句完整的话
        if norm == pending { pendingCount += 1 } else { pending = norm; pendingCount = 1 }
        guard pendingCount == 2, norm != lastShown else { return }
        lastShown = norm
        guard Overlay.shared.accept(text) else { return }
        do {
            let res = try await Translator.shared.translate([text], from: from, to: "zh-CN")
            Overlay.shared.update(res[0])
        } catch {
            Overlay.shared.update("（翻译失败：\(error.localizedDescription)）")
        }
    }
}

// MARK: - HTTP 服务（只监听本机回环）

struct Request {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var body = Data()
}

func respond(_ c: NWConnection, _ status: Int, _ body: Data, _ type: String = "text/plain; charset=utf-8") {
    let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
    var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
    head += "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
    var d = Data(head.utf8)
    d.append(body)
    c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
}

func respondJSON(_ c: NWConnection, _ status: Int, _ obj: Any) {
    let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    respond(c, status, d, "application/json; charset=utf-8")
}

func handle(_ r: Request, _ c: NWConnection) {
    Task {
        do {
            switch (r.method, r.path) {
            case (_, "/health"):
                respond(c, 200, Data("ok".utf8))

            case ("GET", "/translate"):
                let text = r.query["text"] ?? ""
                let res = try await Translator.shared.translate(
                    [text], from: r.query["from"] ?? "ja", to: r.query["to"] ?? "zh-CN")
                respond(c, 200, Data(res[0].utf8))

            case ("POST", "/batch"):
                let j = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] ?? [:]
                let texts = (j["texts"] as? [Any] ?? []).map { "\($0)" }
                let res = try await Translator.shared.translate(
                    texts, from: j["from"] as? String ?? "ja", to: j["to"] as? String ?? "zh-CN")
                respondJSON(c, 200, ["translations": res])

            case ("POST", "/overlay"):
                let j = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] ?? [:]
                let text = (j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fresh = await MainActor.run { Overlay.shared.accept(text) }
                guard !text.isEmpty, fresh else { respond(c, 200, Data()); return }
                let res = try await Translator.shared.translate(
                    [text], from: j["from"] as? String ?? "ja", to: j["to"] as? String ?? "zh-CN")
                await MainActor.run { Overlay.shared.update(res[0]) }
                respond(c, 200, Data(res[0].utf8))

            case ("POST", "/ocr/start"):
                let j = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
                var rect: NSRect? = nil
                if let a = j["rect"] as? [Double], a.count == 4 { rect = NSRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
                await MainActor.run {
                    OCRController.shared.start(
                        game: j["game"] as? String ?? "default", from: j["from"] as? String ?? "ja", rect: rect)
                }
                respond(c, 200, Data("ok".utf8))

            case ("POST", "/ocr/stop"):
                await MainActor.run { OCRController.shared.stop() }
                respond(c, 200, Data("ok".utf8))

            case ("GET", "/ocr/recognize"):
                let path = r.query["path"] ?? ""
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    respond(c, 500, Data("无法读取图片".utf8)); return
                }
                let text = await recognizeText(img, from: r.query["lang"] ?? "ja")
                respond(c, 200, Data(text.utf8))

            default:
                respond(c, 404, Data("not found".utf8))
            }
        } catch {
            log("\(r.method) \(r.path) 失败: \(error.localizedDescription)")
            if r.path == "/overlay" {
                await MainActor.run { Overlay.shared.update("（翻译失败：\(error.localizedDescription)）") }
            }
            respond(c, 500, Data(error.localizedDescription.utf8))
        }
    }
}

final class Connection {
    let c: NWConnection
    var buf = Data()
    init(_ c: NWConnection) { self.c = c }

    func start() {
        c.start(queue: .global())
        receive()
    }

    private func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
            if let data { self.buf.append(data) }
            if let req = self.parse() {
                handle(req, self.c)
            } else if done || err != nil || self.buf.count > 8 << 20 {
                self.c.cancel()
            } else {
                self.receive()
            }
        }
    }

    // 收齐请求头和 Content-Length 指定的正文才返回
    private func parse() -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return Request() }
        var length = 0
        for l in lines {
            let parts = l.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = end.upperBound
        guard buf.count - bodyStart >= length else { return nil }

        var r = Request()
        r.method = String(first[0])
        let comps = URLComponents(string: "http://127.0.0.1" + String(first[1]))
        r.path = comps?.path ?? "/"
        for q in comps?.queryItems ?? [] { r.query[q.name] = q.value ?? "" }
        r.body = buf.subdata(in: bodyStart..<(bodyStart + length))
        return r
    }
}

final class Server {
    var listener: NWListener?

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenPort)!)
            l.newConnectionHandler = { Connection($0).start() }
            l.stateUpdateHandler = { s in
                if case .failed(let e) = s {
                    log("监听失败: \(e)")
                    // 端口被占用多半是已经有一个在运行
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
            l.start(queue: .global())
            listener = l
            log("监听 127.0.0.1:\(listenPort)")
        } catch {
            log("无法监听: \(error)")
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 应用（菜单栏图标，无 Dock 图标）

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = Server()
    var item: NSStatusItem?
    var lockItem: NSMenuItem?
    var frameLockItem: NSMenuItem?
    var pauseItem: NSMenuItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        server.start()
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.title = "译"
        let m = NSMenu()
        m.addItem(withTitle: "显示 / 隐藏字幕窗", action: #selector(toggle), keyEquivalent: "")
        let lock = NSMenuItem(title: "锁定字幕窗（鼠标穿透）", action: #selector(lockToggle), keyEquivalent: "")
        m.addItem(lock)
        lockItem = lock
        m.addItem(.separator())
        let fl = NSMenuItem(title: "锁定识别框（屏幕识别）", action: #selector(frameLockToggle), keyEquivalent: "")
        m.addItem(fl)
        frameLockItem = fl
        let pz = NSMenuItem(title: "暂停屏幕识别", action: #selector(pauseToggle), keyEquivalent: "")
        m.addItem(pz)
        pauseItem = pz
        m.addItem(.separator())
        m.addItem(withTitle: "打开翻译日志", action: #selector(openLog), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "退出 GalTranslator", action: #selector(quit), keyEquivalent: "")
        for i in m.items { i.target = self }
        it.menu = m
        item = it
    }

    func applicationWillTerminate(_ n: Notification) {
        let s = DispatchSemaphore(value: 0)
        Task { await Translator.shared.flush(); s.signal() }
        _ = s.wait(timeout: .now() + 2)
    }

    @objc func toggle() { Task { @MainActor in Overlay.shared.toggle() } }
    @objc func lockToggle() {
        Task { @MainActor in
            Overlay.shared.locked.toggle()
            self.lockItem?.state = Overlay.shared.locked ? .on : .off
        }
    }
    @objc func frameLockToggle() {
        Task { @MainActor in
            let o = OCRController.shared
            o.setLocked(!o.locked)
            self.frameLockItem?.state = o.locked ? .on : .off
        }
    }
    @objc func pauseToggle() {
        Task { @MainActor in
            let o = OCRController.shared
            o.paused.toggle()
            self.pauseItem?.state = o.paused ? .on : .off
        }
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = AppDelegate()
        app.delegate = d
        app.run()
    }
}
