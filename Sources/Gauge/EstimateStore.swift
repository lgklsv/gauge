import Foundation

private struct Rate: Codable {
    var input: Double
    var output: Double
    var cached: Double
    var cacheWrite: Double
}
private struct RateCache: Codable {
    var fetchedAt: Date
    var table: [String: Rate]
}
private struct TokenEvent: Codable {
    var time: Date
    var model: String
    var input: Double
    var cached: Double
    var cacheWrite: Double
    var output: Double
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
}

actor EstimateStore {
    private var files = loadJSON("sessions-v1.json", as: [String: Cursor].self) ?? [:]
    private var rates = loadJSON("rates-v1.json", as: RateCache.self)
    private var importedSwiftBar = loadJSON("swiftbar-imported.json", as: Bool.self) ?? false
    private var retryRatesAt = Date.distantPast

    func refresh() async -> Estimate {
        await refreshRates()
        return scanAndSummarize()
    }

    private func scanAndSummarize() -> Estimate {
        let now = Date()
        let cutoff = now.addingTimeInterval(-32 * 86400)
        let fm = FileManager.default
        let directory = codexHome.appendingPathComponent("sessions")
        var unreadable = false
        let needsImport = !importedSwiftBar
        var changed = importSwiftBarHistory(cutoff: cutoff)
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles]) {
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
                                autoreleasepool { parse(line, cursor: &cursor, cutoff: cutoff) }
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
        } else { unreadable = true }
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
        var result = summarize(now: now)
        if unreadable { result.warning = "Some Codex session logs could not be read. Saved statistics are retained." }
        if rates == nil { result.warning = "Pricing unavailable. Token totals are shown; costs are incomplete." }
        else if now.timeIntervalSince(rates!.fetchedAt) > 2 * 86400 {
            result.warning = "Using saved API prices; pricing refresh failed."
        }
        return result
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
        func number(_ key: String) -> Double {
            guard let value = last[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return 0 }
            return max(0, value.doubleValue.rounded(.down))
        }
        let cached = number("cached_input_tokens")
        let write = number("cache_write_input_tokens")
        let event = TokenEvent(time: date, model: cursor.model,
                               input: max(0, number("input_tokens") - cached - write),
                               cached: cached, cacheWrite: write, output: number("output_tokens"))
        if event.tokens > 0 { cursor.events.append(event) }
    }

    private func refreshRates() async {
        guard Date() >= retryRatesAt,
              rates == nil || Date().timeIntervalSince(rates!.fetchedAt) >= 86400 else { return }
        retryRatesAt = Date().addingTimeInterval(3600)
        do {
            var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
            var table: [String: Rate] = [:]
            for (name, entry) in document {
                guard let input = entry["input_cost_per_token"] as? Double,
                      let output = entry["output_cost_per_token"] as? Double,
                      input.isFinite, output.isFinite, input >= 0, output >= 0 else { continue }
                let cached = entry["cache_read_input_token_cost"] as? Double ?? input
                let write = entry["cache_creation_input_token_cost"] as? Double ?? input
                guard cached.isFinite, write.isFinite, cached >= 0, write >= 0 else { continue }
                table[name.lowercased()] = Rate(input: input, output: output, cached: cached, cacheWrite: write)
            }
            guard !table.isEmpty else { return }
            rates = RateCache(fetchedAt: Date(), table: table)
            saveJSON(rates!, name: "rates-v1.json")
        } catch { /* Keep cached prices offline. */ }
    }

    private func rate(for model: String) -> Rate? {
        let key = String(model.lowercased().split(separator: "[", maxSplits: 1).first ?? "")
        let bare = String(key.split(separator: "/").last ?? "")
        guard !["", "synthetic", "opus", "sonnet", "haiku", "fable"].contains(bare) else { return nil }
        let table = rates?.table ?? [:]
        return table[key] ?? table[bare] ?? (bare.hasPrefix("gpt-") ? table[String(bare.dropFirst(4))] : nil)
    }

    private func summarize(now: Date) -> Estimate {
        var result = Estimate()
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
            for event in cursor.events where event.time <= now {
                let rate = rate(for: event.model)
                var cost = 0.0
                if let rate {
                    cost = event.input * rate.input + event.cached * rate.cached
                    cost += event.cacheWrite * rate.cacheWrite + event.output * rate.output
                }
                if event.time >= today { add(event, cost, rate == nil, to: &result.today) }
                if event.time >= week { add(event, cost, rate == nil, to: &result.week) }
                if event.time >= month { add(event, cost, rate == nil, to: &result.month) }
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.time), to: today).day ?? 99
                if (0..<7).contains(days) { result.dailyCosts[6 - days] += cost }
            }
        }
        return result
    }
}
