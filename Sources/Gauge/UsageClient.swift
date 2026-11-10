import Foundation

struct GaugeError: LocalizedError {
    var message: String
    var retryAfter: TimeInterval = 60
    var errorDescription: String? { message }
}

actor UsageClient {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    func fetch(_ provider: Provider) async throws -> UsageSnapshot {
        switch provider {
        case .codex: return try await fetchCodex()
        case .claude: return try await fetchClaude()
        }
    }

    private func get(_ url: String, token: String, headers: [String: String], provider: Provider) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Gauge/1.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GaugeError(message: "Unexpected usage response.") }
        guard http.statusCode == 200 else {
            let message: String
            switch http.statusCode {
            case 401: message = "\(provider.name) session expired. Sign in again with \(provider.name)."
            case 403: message = "\(provider.name) usage access denied."
            case 429: message = "Too many requests. Waiting before retrying."
            default: message = "Usage request failed (HTTP \(http.statusCode))."
            }
            let header = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let retry = Double(header) ?? formatter.date(from: header)?.timeIntervalSinceNow ?? 60
            throw GaugeError(message: message, retryAfter: max(60, retry))
        }
        return data
    }

    // Read only: Codex owns credential refresh and its chosen storage backend.
    private func codexCredentials() throws -> [String: Any] {
        if let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = object["tokens"] as? [String: Any], tokens["access_token"] is String {
            return tokens
        }
        throw GaugeError(message: "Sign in with Codex first (codex login). No readable auth.json credentials.")
    }

    private func fetchCodex() async throws -> UsageSnapshot {
        let tokens = try codexCredentials()
        guard let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw GaugeError(message: "Codex credentials are missing. Run codex login.")
        }
        var headers: [String: String] = [:]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        let data = try await get("https://chatgpt.com/backend-api/wham/usage", token: token, headers: headers, provider: .codex)
        let object = try JSONSerialization.jsonObject(with: data)
        var payload = object as? [String: Any] ?? [:]
        if let items = (object as? [[String: Any]]) ?? payload["snapshots"] as? [[String: Any]] ?? payload["data"] as? [[String: Any]] {
            payload = items.first(where: { $0["limit_id"] as? String == "codex" }) ?? items.first ?? [:]
        }
        let limits = payload["rate_limit"] as? [String: Any] ?? payload
        var windows: [UsageWindow] = []
        for (key, fallback) in [("primary_window", "5-hour"), ("secondary_window", "Weekly")] {
            guard let block = limits[key] as? [String: Any] else { continue }
            let seconds = (block["limit_window_seconds"] as? Double)
                ?? (block["limit_window_minutes"] as? Double).map { $0 * 60 }
            let label = seconds.map { $0 >= 6 * 86400 ? "Weekly" : ($0 >= 4 * 3600 && $0 <= 6 * 3600 ? "5-hour" : "Usage") } ?? fallback
            windows.append(try window(block, label: label, percent: block["used_percent"]))
        }
        guard !windows.isEmpty else { throw GaugeError(message: "No usage windows in Codex response.") }
        windows.sort { $0.label == "5-hour" && $1.label != "5-hour" }
        if let review = payload["code_review_rate_limit"] as? [String: Any],
           let block = review["primary_window"] as? [String: Any] {
            windows.append(try window(block, label: "Code review", percent: block["used_percent"]))
        }
        var creditText: String?
        if let credits = payload["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true { creditText = "Credits: unlimited" }
            else if let balance = credits["balance"], let value = Double("\(balance)"), value > 0 {
                creditText = "Credits: \(balance)"
            }
        }
        return UsageSnapshot(plan: payload["plan_type"] as? String, windows: windows,
                             credits: creditText, fetchedAt: Date())
    }

    // Read only: Claude Code owns token refresh. On macOS it keeps credentials in the
    // login Keychain, readable through /usr/bin/security like Claude Code itself does;
    // .credentials.json is its fallback store.
    private func claudeCredentials() throws -> [String: Any] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var sources: [Data?] = []
        if (try? process.run()) != nil {
            sources.append(pipe.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
        }
        sources.append(try? Data(contentsOf: claudeHome.appendingPathComponent(".credentials.json")))
        for case let data? in sources {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oauth = object["claudeAiOauth"] as? [String: Any], oauth["accessToken"] is String {
                return oauth
            }
        }
        throw GaugeError(message: "Sign in with Claude Code first (claude /login). No readable credentials.")
    }

    private func fetchClaude() async throws -> UsageSnapshot {
        let oauth = try claudeCredentials()
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw GaugeError(message: "Claude credentials are missing. Run claude /login.")
        }
        if let expiresAt = parseDate(oauth["expiresAt"]), expiresAt < Date() {
            throw GaugeError(message: "Claude session expired. Open Claude Code to refresh it.")
        }
        let data = try await get("https://api.anthropic.com/api/oauth/usage", token: token,
                                 headers: ["anthropic-beta": "oauth-2025-04-20"], provider: .claude)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        for (key, label) in [("five_hour", "5-hour"), ("seven_day", "Weekly")] {
            guard let block = payload[key] as? [String: Any] else { continue }
            windows.append(try window(block, label: label, percent: block["utilization"], provider: .claude))
        }
        guard !windows.isEmpty else { throw GaugeError(message: "No usage windows in Claude response.") }
        return UsageSnapshot(plan: oauth["subscriptionType"] as? String, windows: windows,
                             credits: nil, fetchedAt: Date())
    }

    private func window(_ block: [String: Any], label: String, percent: Any?,
                        provider: Provider = .codex) throws -> UsageWindow {
        guard let number = percent as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0 else {
            throw GaugeError(message: "Invalid usage percentage in \(provider.name) response.")
        }
        return UsageWindow(label: label, percent: min(number.doubleValue, 100),
                           reset: parseDate(block["reset_at"] ?? block["resets_at"]))
    }
}
