import Foundation
import AppKit

struct QuotaWindow {
    let id: String
    let name: String
    let used: Double
    let resetsAt: Double?
    var remaining: Double { max(0, 100 - used) }
    var payload: [String: Any] { ["id": id, "name": name, "remaining": remaining, "resetsAt": resetsAt as Any? ?? NSNull()] }
}

func quotaWindows(_ result: [String: Any]) -> [QuotaWindow] {
    let buckets: [String: Any]
    if let all = result["rateLimitsByLimitId"] as? [String: Any], !all.isEmpty { buckets = all }
    else if let one = result["rateLimits"] as? [String: Any] { buckets = [one["limitId"] as? String ?? "codex": one] }
    else { return [] }
    return buckets.keys.sorted().flatMap { key -> [QuotaWindow] in
        guard let bucket = buckets[key] as? [String: Any] else { return [] }
        return ["primary", "secondary"].compactMap { kind in
            guard let window = bucket[kind] as? [String: Any], let used = window["usedPercent"] as? Double, used.isFinite, (0...100).contains(used) else { return nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            let label: String
            if let minutes { label = minutes >= 1440 ? "\(minutes / 1440) 天额度" : minutes >= 60 ? "\(minutes / 60) 小时额度" : "\(minutes) 分钟额度" }
            else { label = kind == "primary" ? "主要额度" : "次要额度" }
            let title = bucket["limitName"] as? String
            return QuotaWindow(id: key + "." + kind, name: (buckets.count > 1 ? (title ?? key) + " · " : "") + label, used: used, resetsAt: window["resetsAt"] as? Double)
        }
    }
}

func quotaAlerts(_ windows: [QuotaWindow], now: Double, seen: inout Set<String>) -> [String] {
    var currentKeys = Set<String>(), messages: [String] = []
    for window in windows {
        guard let reset = window.resetsAt, reset > now else { continue }
        let prefix = "\(window.id):\(reset):"
        for threshold in [20, 5] { currentKeys.insert(prefix + String(threshold)) }
        guard window.remaining < 20 else { continue }
        let threshold = window.remaining < 5 ? 5 : 20
        let key = prefix + String(threshold)
        if !seen.contains(key) {
            seen.insert(key)
            if threshold == 5 { seen.insert(prefix + "20") }
            messages.append("Codex · \(window.name)剩余不足 \(threshold)%")
        }
    }
    seen.formIntersection(currentKeys)
    return messages
}

final class CodexConnection {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var nextID = 0
    private var callbacks: [Int: ([String: Any]?) -> Void] = [:]
    private var timeout: Timer?
    var updated: (([String: Any]) -> Void)?
    var failed: (() -> Void)?
    private(set) var ready = false
    static func executable() -> URL? {
        var candidates = ["/Applications/Codex.app/Contents/Resources/codex", "/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        for id in ["com.openai.codex", "com.openai.chat"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                candidates.append(app.appending(path: "Contents/Resources/codex").path)
                candidates.append(app.appending(path: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path)
            }
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    func start() {
        guard process == nil, let executable = Self.executable() else { failed?(); return }
        let token = UUID(); generation = token
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable; task.arguments = ["app-server", "--listen", "stdio://"]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = URL.applicationSupportDirectory.appending(path: "IslandNote")
        process = task; input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in if self?.generation == token { self?.receive(data) } }
        }
        task.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.process === task else { return }
            self.ready = false; self.process = nil; self.failed?()
        } }
        do {
            try FileManager.default.createDirectory(at: task.currentDirectoryURL!, withIntermediateDirectories: true)
            try task.run()
            request("initialize", params: ["clientInfo": ["name": "island_note", "title": "随手记", "version": "2.0.0"]]) { [weak self] result in
                guard let self, result != nil else { self?.failed?(); return }
                self.send(["method": "initialized"])
                self.request("account/read", params: ["refreshToken": false]) { [weak self] response in
                    guard let self else { return }
                    guard let account = response?["account"] as? [String: Any], let type = account["type"] as? String, type.lowercased().contains("chatgpt") else { self.failed?(); return }
                    self.ready = true; self.refresh()
                }
            }
        } catch { stop(); failed?() }
    }
    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        do { try input?.write(contentsOf: data + Data([10])) } catch { failed?() }
    }
    private func request(_ method: String, params: [String: Any]? = nil, completion: @escaping ([String: Any]?) -> Void) {
        nextID += 1; let id = nextID; callbacks[id] = completion
        var payload: [String: Any] = ["method": method, "id": id]; if let params { payload["params"] = params }; send(payload)
        // Every request has a bounded wait; a stalled child never blocks the app UI.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in Task { @MainActor in
            guard let self, let callback = self.callbacks.removeValue(forKey: id) else { return }; callback(nil)
        } }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        if buffer.count > 2_000_000 { buffer.removeAll(); failed?(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = json["id"] as? Int { callbacks.removeValue(forKey: id)?(json["result"] as? [String: Any]) }
            else if json["method"] as? String == "account/rateLimits/updated", let result = json["params"] as? [String: Any] { updated?(result) }
        }
    }
    func refresh() {
        guard ready else { return }
        request("account/rateLimits/read") { [weak self] result in
            guard let result else { self?.failed?(); return }; self?.updated?(result)
        }
    }
    func stop() {
        generation = UUID(); buffer.removeAll()
        ready = false; callbacks.removeAll(); try? input?.close(); input = nil
        let previous = process; process = nil
        if previous?.isRunning == true { previous?.terminate() }
    }
}

final class AgentUsage {
    var changed: (([String: Any]) -> Void)?
    var alert: ((String) -> Void)?
    private let connection = CodexConnection()
    private var timer: Timer?
    private var windows: [QuotaWindow] = []
    private var lastUpdated: Double?
    private var error: String?
    private var emitted = Set<String>()
    private var checking = false
    private(set) var enabled: Bool
    init() {
        // This personal build enables only Codex, explicitly selected by the user.
        enabled = UserDefaults.standard.object(forKey: "codexEnabled") as? Bool ?? false
        emitted = Set(UserDefaults.standard.stringArray(forKey: "quotaAlertKeys") ?? [])
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            windows = quotaWindows(cached); lastUpdated = cached["_updatedAt"] as? Double
        }
        connection.updated = { [weak self] result in self?.receive(result) }
        connection.failed = { [weak self] in
            self?.checking = false; self?.error = "暂时无法更新，请检查 Codex 登录与网络"; self?.publish()
        }
    }
    private var cacheURL: URL { URL.applicationSupportDirectory.appending(path: "IslandNote/codex-quota-v2.json") }
    func start() {
        if enabled { refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        publish()
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "codexEnabled")
        if value { refresh() } else { connection.stop(); checking = false; error = nil }
        publish()
    }
    func refresh() {
        guard enabled else { return }
        checking = true; publish()
        if connection.ready { connection.refresh() } else { connection.stop(); connection.start() }
    }
    private func receive(_ result: [String: Any]) {
        guard enabled else { return }
        checking = false; let received = quotaWindows(result)
        guard !received.isEmpty else { error = "当前账号未返回可用的订阅额度"; publish(); return }
        windows = received; lastUpdated = Date().timeIntervalSince1970; error = nil
        var cached = result; cached["_updatedAt"] = lastUpdated
        if let data = try? JSONSerialization.data(withJSONObject: cached) { try? data.write(to: cacheURL, options: .atomic) }
        for message in quotaAlerts(windows, now: Date().timeIntervalSince1970, seen: &emitted) { alert?(message) }
        UserDefaults.standard.set(Array(emitted), forKey: "quotaAlertKeys")
        publish()
    }
    func publish() {
        changed?(["enabled": enabled, "windows": enabled ? windows.map(\.payload) : [], "updatedAt": lastUpdated as Any? ?? NSNull(), "error": error as Any? ?? NSNull(), "checking": checking])
    }
    func stop() { timer?.invalidate(); connection.stop() }
}
