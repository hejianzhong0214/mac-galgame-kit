// GalBox — 把 Windows 游戏拖进来，自动用 Wine 配好并一键启动
// 所有处理都交给 gal 脚本（打包在 .app 里，启动时同步到 ~/Games/gal/kit）
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 路径

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let galHome = home.appendingPathComponent("Games/gal")
    static let kit = galHome.appendingPathComponent("kit")
    static let gal = kit.appendingPathComponent("bin/gal")
    static let launch = galHome.appendingPathComponent("launch")
    static let logs = galHome.appendingPathComponent("logs")
    static let appLog = logs.appendingPathComponent("galbox.log")
    static let translateConfig = galHome.appendingPathComponent("config/translate.json")
    static let translator = kit.appendingPathComponent("GalTranslator.app")
    static let templateReady = galHome.appendingPathComponent("bottles/_template/.gal-template-ready")
}

let translatorURL = "http://127.0.0.1:47011"

let engineTitles: [String: String] = [
    "renpy": "Ren'Py", "macapp": "macOS 版", "mz": "RPG Maker MZ", "mv": "RPG Maker MV",
    "rgss3": "RPG Maker VX Ace", "rgss2": "RPG Maker VX", "rgss1": "RPG Maker XP",
    "tyrano": "TyranoScript", "nscripter": "NScripter", "kirikiri": "吉里吉里",
    "siglus": "SiglusEngine", "reallive": "RealLive", "unity": "Unity",
    "catsystem2": "CatSystem2", "bgi": "BGI", "wolf": "Wolf RPG", "nwjs": "NW.js",
    "exe": "Windows 游戏",
]

let languages: [(String, String)] = [
    ("ja", "日文"), ("zh", "简体中文"), ("tw", "繁体中文"), ("ko", "韩文"), ("none", "不转区"),
]

struct Game: Identifiable, Hashable {
    let id: String
    var title: String
    var engine: String
    var route: String
    var lang: String
    var bottle: String
    var dir: String
    var imported: String
    var translate: Bool
    var displayFit: Bool
    var wineDevel: Bool

    var subtitle: String {
        let e = engineTitles[engine] ?? engine
        let r = route == "nw" ? "原生 NW.js" : "Wine"
        let l = languages.first { $0.0 == lang }?.1 ?? lang
        let t = translate ? " · 机翻已开" : ""
        return route == "nw" ? "\(e) · \(r)\(t)" : "\(e) · \(r) · \(l)\(t)"
    }
}

// MARK: - 模型

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    @Published var games: [Game] = []
    @Published var log = ""
    @Published var busy = false
    @Published var lang = "ja"
    @Published var running: Set<String> = []
    @Published var setupError: String?

    private var queue: [URL] = []
    private var procs: [String: Process] = [:]
    private var logFile: FileHandle?

    init() {
        installKit()
        openLogFile()
        refresh()
    }

    // 把 .app 里的脚本同步到 ~/Games/gal/kit，生成的启动器都指向这里，挪动 .app 也不受影响
    private func installKit() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("kit") else {
            setupError = "应用包里缺少 kit 目录"
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Paths.galHome, withIntermediateDirectories: true)
            if fm.fileExists(atPath: Paths.kit.path) { try fm.removeItem(at: Paths.kit) }
            try fm.copyItem(at: src, to: Paths.kit)
        } catch {
            setupError = "安装脚本失败：\(error.localizedDescription)"
        }
        let wine = Paths.galHome.appendingPathComponent("runtimes/Wine Stable.app")
        if setupError == nil, !fm.fileExists(atPath: wine.path),
           !fm.fileExists(atPath: "/Applications/Wine Stable.app") {
            setupError = "还没装 Wine。在终端执行 gal setup（或 gal setup --wine-tarball <文件>）后再用。"
        }
    }

    private func openLogFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.appLog.path) {
            fm.createFile(atPath: Paths.appLog.path, contents: nil)
        }
        logFile = try? FileHandle(forWritingTo: Paths.appLog)
        logFile?.seekToEndOfFile()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.launch, includingPropertiesForKeys: nil)) ?? []
        var list: [Game] = []
        for f in files where f.pathExtension == "meta" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            var kv: [String: String] = [:]
            for line in text.split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") {
                    kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
                }
            }
            let name = f.deletingPathExtension().lastPathComponent
            let wineFile = Paths.galHome.appendingPathComponent("bottles/\(kv["bottle"] ?? "")/.gal-wine")
            let wineApp = (try? String(contentsOf: wineFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            list.append(Game(
                id: name, title: kv["title"] ?? name, engine: kv["engine"] ?? "",
                route: kv["route"] ?? "wine", lang: kv["lang"] ?? "ja",
                bottle: kv["bottle"] ?? "", dir: kv["dir"] ?? "", imported: kv["imported"] ?? "",
                translate: kv["translate"] == "on",
                displayFit: (kv["display"] ?? "native") == "fit",
                wineDevel: wineApp == "Wine Devel"))
        }
        games = list.sorted { $0.imported > $1.imported }
    }

    // MARK: 导入

    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        busy = true
        append("\n▶ 导入 \(url.lastPathComponent)\n")
        gal(["import", "-l", lang, url.path]) { status in
            let m = Model.shared
            m.append(status == 0 ? "✓ 导入完成\n" : "✗ 导入失败（退出码 \(status)）\n")
            m.busy = false
            m.refresh()
            m.next()
        }
    }

    // 运行 gal 子命令，输出实时追加到日志
    func gal(_ args: [String], done: @escaping @MainActor (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.gal.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in Model.shared.append(s) }
        }
        p.terminationHandler = { proc in
            let st = proc.terminationStatus
            Task { @MainActor in done(st) }
        }
        do {
            try p.run()
        } catch {
            append("无法运行 gal：\(error.localizedDescription)\n")
            done(-1)
        }
    }

    func append(_ s: String) {
        let clean = s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        log += clean
        if log.count > 30000 { log = String(log.suffix(20000)) }
        if let d = clean.data(using: .utf8) { logFile?.write(d) }
    }

    // MARK: 游戏操作

    func start(_ g: Game) {
        let cmd = Paths.launch.appendingPathComponent("\(g.id).command")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [cmd.path]
        p.terminationHandler = { _ in
            Task { @MainActor in
                Model.shared.running.remove(g.id)
                Model.shared.procs[g.id] = nil
            }
        }
        do {
            try p.run()
            running.insert(g.id)
            procs[g.id] = p
            append("▶ 启动 \(g.title)\n")
        } catch {
            append("启动失败：\(error.localizedDescription)\n")
        }
    }

    func stop(_ g: Game) {
        if g.bottle.isEmpty {
            procs[g.id]?.terminate()
        } else {
            gal(["kill", "-b", g.bottle]) { _ in }
        }
    }

    func remove(_ g: Game) {
        gal(["remove", g.id]) { _ in Model.shared.refresh() }
    }

    // 切换容器用的 Wine：开发版修好了 Unity 6 鼠标点不动的问题
    func setWineDevel(_ g: Game, _ on: Bool) {
        busy = true
        append("\n▶ \(g.title) 改用 Wine \(on ? "开发版" : "稳定版")（会顺带升级容器，存档不受影响）\n")
        gal(["wine", "-b", g.bottle, on ? "devel" : "stable"]) { st in
            let m = Model.shared
            m.append(st == 0 ? "✓ 完成，重新启动游戏生效\n" : "✗ 失败（退出码 \(st)）\n")
            m.busy = false
            m.refresh()
        }
    }

    func setDisplay(_ g: Game, fit: Bool) {
        gal(["display", g.id, fit ? "fit" : "native"]) { _ in Model.shared.refresh() }
    }

    func setTranslate(_ g: Game, _ on: Bool) {
        busy = true
        append("\n▶ \(on ? "开启" : "关闭")机翻：\(g.title)\n")
        gal(["translate", g.id, on ? "on" : "off"]) { st in
            let m = Model.shared
            m.append(st == 0 ? "✓ 完成\n" : "✗ 失败（退出码 \(st)）\n")
            m.busy = false
            m.refresh()
        }
    }

    // MARK: 设置

    @Published var apiKey = ""
    @Published var model = "deepseek-chat"
    @Published var baseURL = "https://api.deepseek.com"
    @Published var testResult = ""
    @Published var templateStatus = ""

    func loadSettings() {
        if let d = try? Data(contentsOf: Paths.translateConfig),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            apiKey = j["apiKey"] as? String ?? ""
            model = (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "deepseek-chat"
            baseURL = (j["baseURL"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.deepseek.com"
        }
        templateStatus = FileManager.default.fileExists(atPath: Paths.templateReady.path)
            ? ((try? String(contentsOf: Paths.templateReady, encoding: .utf8)) ?? "已就绪")
            : "还没有构建"
    }

    func saveSettings() {
        let j: [String: Any] = [
            "provider": "deepseek",
            "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": model.trimmingCharacters(in: .whitespaces),
            "baseURL": baseURL.trimmingCharacters(in: .whitespaces),
        ]
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.translateConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) {
            try? d.write(to: Paths.translateConfig, options: .atomic)
            // key 只给自己看
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.translateConfig.path)
        }
    }

    // 确保 GalTranslator 在运行，返回是否就绪
    func ensureTranslator() async -> Bool {
        if await translatorHealthy() { return true }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: Paths.translator, configuration: cfg)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await translatorHealthy() { return true }
        }
        return false
    }

    private func translatorHealthy() async -> Bool {
        guard let u = URL(string: translatorURL + "/health") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 2
        guard let (d, _) = try? await URLSession.shared.data(for: req) else { return false }
        return String(decoding: d, as: UTF8.self) == "ok"
    }

    func testTranslate() {
        saveSettings()
        testResult = "测试中…"
        Task { @MainActor in
            guard await self.ensureTranslator() else {
                self.testResult = "GalTranslator 没有启动"
                return
            }
            let sample = "先輩、今日も一緒に帰りませんか？"
            var comps = URLComponents(string: translatorURL + "/translate")!
            comps.queryItems = [
                .init(name: "from", value: "ja"), .init(name: "to", value: "zh-CN"),
                .init(name: "text", value: sample),
            ]
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 120
            do {
                let (d, r) = try await URLSession.shared.data(for: req)
                let s = String(decoding: d, as: UTF8.self)
                let ok = (r as? HTTPURLResponse)?.statusCode == 200
                self.testResult = ok ? "\(sample)\n→ \(s)" : "失败：\(s)"
            } catch {
                self.testResult = "失败：\(error.localizedDescription)"
            }
        }
    }

    func buildTemplate() {
        busy = true
        append("\n▶ 构建运行库模板容器（要下载约 200 MB，十几分钟）\n")
        gal(["template", "build"]) { st in
            let m = Model.shared
            m.append(st == 0 ? "✓ 模板构建完成\n" : "✗ 模板构建失败（退出码 \(st)）\n")
            m.busy = false
            m.loadSettings()
        }
    }

    func reveal(_ g: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.dir)])
    }

    func openLog(_ g: Game) {
        let f = Paths.logs.appendingPathComponent("\(g.id).log")
        if FileManager.default.fileExists(atPath: f.path) {
            NSWorkspace.shared.open(f)
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择游戏的 exe、游戏文件夹或 zip"
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }
}

// MARK: - 界面

struct ContentView: View {
    @ObservedObject var m = Model.shared
    @State private var targeted = false
    @State private var pendingRemove: Game?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = m.setupError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            dropZone
            HStack {
                Text("游戏库").font(.headline)
                Spacer()
                Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新")
                Button {
                    m.loadSettings()
                    showSettings = true
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("设置：机翻服务、运行库模板")
            }
            library
            logView
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 600)
        .confirmationDialog(
            "删除「\(pendingRemove?.title ?? "")」？",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            presenting: pendingRemove
        ) { g in
            Button("删除", role: .destructive) { m.remove(g) }
        } message: { _ in
            Text("会删除它的容器和存档。你原来的游戏文件不会动。")
        }
        .sheet(isPresented: $showSettings) { SettingsView(m: m) }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            if m.busy {
                ProgressView().controlSize(.large)
                Text("正在处理…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                Text("把游戏的 exe、文件夹或 zip 拖到这里")
                    .font(.title3)
                HStack(spacing: 12) {
                    Button("选择文件…") { m.choose() }
                    Picker("转区", selection: $m.lang) {
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(width: 170)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in Model.shared.enqueue([url]) } }
                }
            }
            return true
        }
    }

    private var library: some View {
        Group {
            if m.games.isEmpty {
                Text("还没有游戏。拖一个进来试试。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(m.games) { g in row(g) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minHeight: 180)
    }

    private func row(_ g: Game) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(g.title).font(.body.weight(.medium)).lineLimit(1)
                Text(g.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if m.running.contains(g.id) {
                Button("结束") { m.stop(g) }
            } else {
                Button("开始") { m.start(g) }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button(g.translate ? "关闭机翻" : "开启机翻") { m.setTranslate(g, !g.translate) }
                    .disabled(m.busy)
                if g.route != "nw" {
                    Toggle("画面适应屏幕", isOn: Binding(
                        get: { g.displayFit }, set: { m.setDisplay(g, fit: $0) }))
                    Toggle("使用 Wine 开发版（修鼠标点不动）", isOn: Binding(
                        get: { g.wineDevel }, set: { m.setWineDevel(g, $0) }))
                        .disabled(m.busy || m.running.contains(g.id))
                }
                Divider()
                Button("在 Finder 中显示") { m.reveal(g) }
                Button("查看运行日志") { m.openLog(g) }
                Divider()
                Button("删除…", role: .destructive) { pendingRemove = g }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(m.log.isEmpty ? "处理日志会显示在这里" : m.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(m.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .onChange(of: m.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title2.weight(.semibold))

            GroupBox("机翻服务（DeepSeek）") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在 platform.deepseek.com 申请 API key 后填在这里。key 只保存在本机 ~/Games/gal/config/translate.json。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("API key（sk-…）", text: $m.apiKey)
                        .textFieldStyle(.roundedBorder)
                    DisclosureGroup("高级", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("模型", text: $m.model).textFieldStyle(.roundedBorder)
                            TextField("接口地址", text: $m.baseURL).textFieldStyle(.roundedBorder)
                            Text("兼容 OpenAI 格式的其他服务也能用，改接口地址和模型即可。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    }
                    HStack {
                        Button("保存") { m.saveSettings() }
                        Button("保存并测试翻译") { m.testTranslate() }
                    }
                    if !m.testResult.isEmpty {
                        Text(m.testResult)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
            }

            GroupBox("屏幕识别权限") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("吉里吉里等视觉小说用屏幕识别取字，需要在系统设置里允许 GalTranslator 录制屏幕。第一次用时 macOS 会弹窗询问。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置的屏幕录制页") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
                .padding(6)
            }

            GroupBox("运行库模板容器") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("预装 VC++ 2005–2022、DirectX 9/10/11 组件、XACT、LAVFilters 视频解码和 DXVK。新导入的游戏直接克隆它，启动时自动加载这些 DLL。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(m.templateStatus)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button(m.templateStatus.contains("ok") ? "重新构建" : "构建") { m.buildTemplate() }
                        .disabled(m.busy)
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("完成") {
                    m.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 把文件拖到 Dock 图标上、或 open -a GalBox.app <文件> 时走这里
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Model.shared.enqueue(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GalBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("GalBox", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
