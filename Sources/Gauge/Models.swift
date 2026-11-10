import Foundation

enum Provider: String, CaseIterable, Codable {
    case codex, claude

    var name: String { self == .codex ? "Codex" : "Claude" }
    var mark: String { self == .codex ? "CodexMark" : "ClaudeMark" }
    var cacheName: String { self == .codex ? "usage-v1.json" : "usage-claude-v1.json" }
    var refreshInterval: TimeInterval {
        switch self {
        case .codex: return 60
        // Claude's usage endpoint rate limits aggressively; raise to 300 if 429s are frequent.
        case .claude: return 60
        }
    }
    var home: URL { self == .codex ? codexHome : claudeHome }

    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "\(rawValue)Enabled") as? Bool
                ?? FileManager.default.fileExists(atPath: home.path)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "\(rawValue)Enabled") }
    }
    static var enabled: [Provider] { allCases.filter(\.isEnabled) }
}

struct UsageWindow: Codable {
    var label: String
    var percent: Double
    var reset: Date?
    func countdown(at now: Date = Date()) -> String {
        guard let reset else { return "" }
        let minutes = Int(reset.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "resetting…" }
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes / 60 % 24)h" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct UsageSnapshot: Codable {
    var plan: String?
    var windows: [UsageWindow]
    var credits: String?
    var fetchedAt: Date
}

struct Bucket: Codable {
    var cost = 0.0
    var tokens = 0.0
    var unpriced = 0.0
    var costText: String { String(format: "$%.2f%@", cost, unpriced > 0 ? "*" : "") }
    var tokenText: String {
        for (divisor, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where tokens >= divisor {
            return String(format: "%.2f%@", tokens / divisor, suffix)
        }
        return String(format: "%.0f", tokens)
    }
}

struct Estimate: Codable {
    var today = Bucket()
    var week = Bucket()
    var month = Bucket()
    // Seven daily costs per provider, keyed by Provider.rawValue.
    var dailyCosts: [String: [Double]] = [:]
    var warning: String?
}

let codexHome: URL = {
    if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
}()

let claudeHome: URL = {
    if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
}()

let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Gauge", isDirectory: true)

func loadJSON<T: Decodable>(_ name: String, as type: T.Type) -> T? {
    autoreleasepool {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

func saveJSON<T: Encodable>(_ value: T, name: String) {
    autoreleasepool {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let url = supportDirectory.appendingPathComponent(name)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* A cache write must not prevent displaying live data. */ }
    }
}

private let dateLock = NSLock()

func parseDate(_ value: Any?) -> Date? {
    dateLock.lock()
    defer { dateLock.unlock() }
    if let number = value as? Double {
        guard number.isFinite else { return nil }
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }
    guard let text = value as? String else { return nil }
    return fractionalISO.date(from: text) ?? plainISO.date(from: text)
}
private let fractionalISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let plainISO = ISO8601DateFormatter()
