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
}

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

    var subtitle: String {
        let e = engineTitles[engine] ?? engine
        let r = route == "nw" ? "原生 NW.js" : "Wine"
        let l = languages.first { $0.0 == lang }?.1 ?? lang
        return route == "nw" ? "\(e) · \(r)" : "\(e) · \(r) · \(l)"
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
            list.append(Game(
                id: name, title: kv["title"] ?? name, engine: kv["engine"] ?? "",
                route: kv["route"] ?? "wine", lang: kv["lang"] ?? "ja",
                bottle: kv["bottle"] ?? "", dir: kv["dir"] ?? "", imported: kv["imported"] ?? ""))
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
