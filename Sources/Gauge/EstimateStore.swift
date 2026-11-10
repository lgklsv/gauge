import Foundation

private struct Rate: Codable {
    var input: Double
    var output: Double
    var cached: Double
    var cacheWrite: Double
    var cacheWrite1h: Double?
}
private struct RateCache: Codable {
    var fetchedAt: Date
    var table: [String: Rate]
}
private let neededModelsKey = CodingUserInfoKey(rawValue: "neededModels")!

private func rateKeys(for model: String) -> [String] {
    let key = String(model.lowercased().split(separator: "[", maxSplits: 1).first ?? "")
    let bare = String(key.split(separator: "/").last ?? "")
    guard !["", "synthetic", "opus", "sonnet", "haiku", "fable"].contains(bare) else { return [] }
    return bare.hasPrefix("gpt-") ? [key, bare, String(bare.dropFirst(4))] : [key, bare]
}

private struct ModelKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension RateCache {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ModelKey.self)
        fetchedAt = try container.decode(Date.self, forKey: ModelKey(stringValue: "fetchedAt"))
        let tableKey = ModelKey(stringValue: "table")
        guard let models = decoder.userInfo[neededModelsKey] as? Set<String> else {
            table = try container.decode([String: Rate].self, forKey: tableKey)
            return
        }
        let entries = try container.nestedContainer(keyedBy: ModelKey.self, forKey: tableKey)
        table = [:]
        for model in models {
            for key in rateKeys(for: model) {
                let codingKey = ModelKey(stringValue: key)
                if entries.contains(codingKey) {
                    table[model] = try entries.decode(Rate.self, forKey: codingKey)
                    break
                }
            }
        }
    }
}

private struct TokenEvent: Codable {
    var time: Date
    var model: String
    var input: Double
    var cached: Double
    var cacheWrite: Double
    var output: Double
    // Claude only: the share of cacheWrite billed at the 1-hour cache price, and the
    // message id used to drop the repeated records Claude Code writes per response.
    var cacheWrite1h: Double?
    var id: String?
    var tokens: Double { input + cached + cacheWrite + output }
}
private struct Cursor: Codable {
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var modified: Date = .distantPast
    var inode: UInt64 = 0
    var model = ""
    var signature: Data?
    var sawMeta = false
    var forkAnchor: Date?
    var events: [TokenEvent] = []
    var provider: Provider? // nil for cursors saved before Claude support: Codex
}

private func count(_ object: [String: Any]?, _ key: String) -> Double {
    guard let value = object?[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite else { return 0 }
    return max(0, value.doubleValue.rounded(.down))
}

actor EstimateStore {
    private var files = loadJSON("sessions-v1.json", as: [String: Cursor].self) ?? [:]
    // Only prices referenced by retained sessions stay in memory. The complete
    // table remains on disk so a newly used model can be priced offline.
    private var rates: [String: Rate] = [:]
    private var ratesFetchedAt: Date?
    private var pricedModels = Set<String>()
    private var importedSwiftBar = loadJSON("swiftbar-imported.json", as: Bool.self) ?? false
    private var retryRatesAt = Date.distantPast

    func refresh(providers: [Provider]) async -> Estimate {
        let unreadable = scanSessions(providers: providers)
        var models = Set<String>()
        for cursor in files.values where providers.contains(cursor.provider ?? .codex) {
            models.formUnion(cursor.events.lazy.map(\.model))
        }
        await refreshRates(for: models)
        var result = summarize(now: Date(), providers: providers)
        if unreadable { result.warning = "Some session logs could not be read. Saved statistics are retained." }
        if !models.isEmpty && ratesFetchedAt == nil {
            result.warning = "Pricing unavailable. Token totals are shown; costs are incomplete."
        } else if let fetchedAt = ratesFetchedAt, Date().timeIntervalSince(fetchedAt) > 2 * 86400 {
            result.warning = "Using saved API prices; pricing refresh failed."
        }
        return result
    }

    private func scanSessions(providers: [Provider]) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-32 * 86400)
        let fm = FileManager.default
        var unreadable = false
        let needsImport = !importedSwiftBar
        var changed = autoreleasepool { importSwiftBarHistory(cutoff: cutoff) }
        for provider in providers {
            let directory = provider == .codex
                ? codexHome.appendingPathComponent("sessions") : claudeHome.appendingPathComponent("projects")
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else {
                unreadable = true
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                do {
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let modified = attributes[.modificationDate] as? Date ?? .distantPast
                    guard modified >= cutoff else { continue }
                    let old = files[url.path]
                    if let old, old.size == size, old.modified == modified, old.inode == inode { continue }
                    var cursor = old ?? Cursor()
                    if cursor.inode != inode || size < cursor.size || (size == cursor.size && modified != cursor.modified) {
                        cursor = Cursor()
                    }
                    if provider != .codex { cursor.provider = provider }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: cursor.offset)
                    var pending = Data()
                    while true {
                        let didRead = try autoreleasepool { () throws -> Bool in
                            guard let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { return false }
                            pending.append(chunk)
                            while let newline = pending.firstIndex(of: 10) {
                                let end = pending.index(after: newline)
                                let line = Data(pending[..<newline])
                                cursor.offset += UInt64(pending.distance(from: pending.startIndex, to: end))
                                pending.removeSubrange(..<end)
                                autoreleasepool {
                                    if provider == .codex { parse(line, cursor: &cursor, cutoff: cutoff) }
                                    else { parseClaude(line, cursor: &cursor, cutoff: cutoff) }
                                }
                            }
                            return true
                        }
                        if !didRead { break }
                    }
                    // Leave an incomplete final record for the next pass.
                    cursor.size = size
                    cursor.modified = modified
                    cursor.inode = inode
                    files[url.path] = cursor
                    changed = true
                } catch { unreadable = true }
            }
        }
        for path in Array(files.keys) {
            let count = files[path]!.events.count
            files[path]!.events.removeAll { $0.time < cutoff }
            if files[path]!.events.count != count { changed = true }
            // Retain cursors for active empty files; retain events from deleted logs.
            if files[path]!.events.isEmpty && files[path]!.modified < cutoff {
                files.removeValue(forKey: path)
                changed = true
            }
        }
        if changed { saveJSON(files, name: "sessions-v1.json") }
        if needsImport { saveJSON(true, name: "swiftbar-imported.json") }
        return unreadable
    }

    // Preserve estimates for logs already removed by Codex before migration.
    private func importSwiftBarHistory(cutoff: Date) -> Bool {
        guard !importedSwiftBar else { return false }
        importedSwiftBar = true
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/swiftbar-codex-estimate.json")
        guard let data = try? Data(contentsOf: cache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["files"] as? [String: [String: Any]] else { return false }
        var changed = false
        for (path, entry) in entries where files[path] == nil && !FileManager.default.fileExists(atPath: path) {
            var cursor = Cursor()
            for raw in entry["events"] as? [[String: Any]] ?? [] {
                guard let time = parseDate(raw["ts"]), time >= cutoff,
                      let model = raw["model"] as? String else { continue }
                func count(_ key: String) -> Double {
                    let value = raw[key] as? Double ?? 0
                    return value.isFinite ? max(0, value) : 0
                }
                cursor.events.append(TokenEvent(time: time, model: model, input: count("uncached"),
                                                cached: count("cached"), cacheWrite: count("cache_write"),
                                                output: count("output")))
            }
            if !cursor.events.isEmpty { files[path] = cursor; changed = true }
        }
        return changed
    }

    private func parse(_ line: Data, cursor: inout Cursor, cutoff: Date) {
        // Avoid decoding full conversations, tool results, and other large records.
        guard line.range(of: Data("\"token_count\"".utf8)) != nil
                || line.range(of: Data("\"turn_context\"".utf8)) != nil
                || line.range(of: Data("\"session_meta\"".utf8)) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return }
        if record["type"] as? String == "session_meta" {
            guard !cursor.sawMeta else { return }
            cursor.sawMeta = true
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            if payload["forked_from_id"] is String || spawn?["parent_thread_id"] is String {
                cursor.forkAnchor = parseDate(record["timestamp"])
            }
            return
        }
        if record["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String { cursor.model = model }
            return
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let date = parseDate(record["timestamp"]), !cursor.model.isEmpty,
              let signature = try? JSONSerialization.data(withJSONObject: last, options: [.sortedKeys]) else { return }
        guard signature != cursor.signature else { return }
        cursor.signature = signature
        if let anchor = cursor.forkAnchor {
            if date.timeIntervalSince(anchor) < 1 {
                cursor.forkAnchor = date
                return
            }
            cursor.forkAnchor = nil
        }
        guard date >= cutoff else { return }
        let cached = count(last, "cached_input_tokens")
        let write = count(last, "cache_write_input_tokens")
        let event = TokenEvent(time: date, model: cursor.model,
                               input: max(0, count(last, "input_tokens") - cached - write),
                               cached: cached, cacheWrite: write, output: count(last, "output_tokens"))
        if event.tokens > 0 { cursor.events.append(event) }
    }

    private func parseClaude(_ line: Data, cursor: inout Cursor, cutoff: Date) {
        guard line.range(of: Data("\"assistant\"".utf8)) != nil,
              line.range(of: Data("\"usage\"".utf8)) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let date = parseDate(record["timestamp"]), date >= cutoff else { return }
        // Claude Code repeats a response's usage on each of its content block records.
        let id = (message["id"] as? String).map { "\($0):\(record["requestId"] as? String ?? "")" }
        if let id, cursor.events.suffix(16).contains(where: { $0.id == id }) { return }
        let write = count(usage, "cache_creation_input_tokens")
        let write1h = min(write, count(usage["cache_creation"] as? [String: Any], "ephemeral_1h_input_tokens"))
        let event = TokenEvent(time: date, model: model, input: count(usage, "input_tokens"),
                               cached: count(usage, "cache_read_input_tokens"), cacheWrite: write,
                               output: count(usage, "output_tokens"),
                               cacheWrite1h: write1h > 0 ? write1h : nil, id: id)
        if event.tokens > 0 { cursor.events.append(event) }
    }

    private func refreshRates(for models: Set<String>) async {
        guard !models.isEmpty else {
            rates = [:]
            pricedModels = []
            return
        }
        if ratesFetchedAt == nil || models != pricedModels {
            // Decode and filter inside the pool; do not retain the full table.
            let cached: RateCache? = autoreleasepool {
                guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("rates-v2.json")) else { return nil }
                let decoder = JSONDecoder()
                decoder.userInfo[neededModelsKey] = models
                return try? decoder.decode(RateCache.self, from: data)
            }
            if let cached {
                rates = cached.table
                ratesFetchedAt = cached.fetchedAt
            } else {
                rates = rates.filter { models.contains($0.key) }
                ratesFetchedAt = nil
            }
            pricedModels = models
        }
        guard Date() >= retryRatesAt,
              ratesFetchedAt.map({ Date().timeIntervalSince($0) >= 86400 }) ?? true else { return }
        retryRatesAt = Date().addingTimeInterval(3600)
        do {
            var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let filtered: RateCache? = autoreleasepool {
                guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
                var table: [String: Rate] = [:]
                for (name, entry) in document {
                    guard let input = entry["input_cost_per_token"] as? Double,
                          let output = entry["output_cost_per_token"] as? Double,
                          input.isFinite, output.isFinite, input >= 0, output >= 0 else { continue }
                    let cached = entry["cache_read_input_token_cost"] as? Double ?? input
                    let write = entry["cache_creation_input_token_cost"] as? Double ?? input
                    let write1h = entry["cache_creation_input_token_cost_above_1hr"] as? Double
                    guard cached.isFinite, write.isFinite, cached >= 0, write >= 0 else { continue }
                    table[name.lowercased()] = Rate(input: input, output: output, cached: cached, cacheWrite: write,
                                                    cacheWrite1h: write1h.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
                }
                guard !table.isEmpty else { return nil }
                let full = RateCache(fetchedAt: Date(), table: table)
                saveJSON(full, name: "rates-v2.json")
                return RateCache(fetchedAt: full.fetchedAt, table: prices(for: models, in: table))
            }
            if let filtered {
                rates = filtered.table
                ratesFetchedAt = filtered.fetchedAt
            }
        } catch { /* Keep cached prices offline. */ }
    }

    private func prices(for models: Set<String>, in table: [String: Rate]) -> [String: Rate] {
        var selected: [String: Rate] = [:]
        for model in models {
            selected[model] = rateKeys(for: model).lazy.compactMap { table[$0] }.first
        }
        return selected
    }

    private func summarize(now: Date, providers: [Provider]) -> Estimate {
        var result = Estimate()
        for provider in providers { result.dailyCosts[provider.rawValue] = Array(repeating: 0, count: 7) }
        var seen = Set<String>()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let week = now.addingTimeInterval(-7 * 86400)
        let month = now.addingTimeInterval(-30 * 86400)
        func add(_ event: TokenEvent, _ cost: Double, _ unpriced: Bool, to bucket: inout Bucket) {
            bucket.cost += cost
            bucket.tokens += event.tokens
            if unpriced { bucket.unpriced += event.tokens }
        }
        for cursor in files.values {
            let provider = (cursor.provider ?? .codex).rawValue
            guard result.dailyCosts[provider] != nil else { continue }
            for event in cursor.events where event.time <= now {
                // A resumed Claude session may copy earlier responses into a new log.
                if let id = event.id, !seen.insert(id).inserted { continue }
                let rate = rates[event.model]
                var cost = 0.0
                if let rate {
                    let write1h = event.cacheWrite1h ?? 0
                    cost = event.input * rate.input + event.cached * rate.cached + event.output * rate.output
                    cost += (event.cacheWrite - write1h) * rate.cacheWrite + write1h * (rate.cacheWrite1h ?? rate.cacheWrite)
                }
                if event.time >= today { add(event, cost, rate == nil, to: &result.today) }
                if event.time >= week { add(event, cost, rate == nil, to: &result.week) }
                if event.time >= month { add(event, cost, rate == nil, to: &result.month) }
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.time), to: today).day ?? 99
                if (0..<7).contains(days) { result.dailyCosts[provider]![6 - days] += cost }
            }
        }
        return result
    }
}
