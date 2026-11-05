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

    // Read only: Codex owns credential refresh and its chosen storage backend.
    private func credentials() throws -> [String: Any] {
        if let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = object["tokens"] as? [String: Any], tokens["access_token"] is String {
            return tokens
        }
        throw GaugeError(message: "Sign in with Codex first (codex login). No readable auth.json credentials.")
    }

    func fetch() async throws -> UsageSnapshot {
        let tokens = try credentials()
        guard let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw GaugeError(message: "Codex credentials are missing. Run codex login.")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Gauge/1.0", forHTTPHeaderField: "User-Agent")
        if let account = tokens["account_id"] as? String {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GaugeError(message: "Unexpected usage response.") }
        guard http.statusCode == 200 else {
            let message: String
            switch http.statusCode {
            case 401: message = "Codex session expired. Sign in again with Codex."
            case 403: message = "Codex usage access denied."
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
            windows.append(try window(block, label: label))
        }
        guard !windows.isEmpty else { throw GaugeError(message: "No usage windows in Codex response.") }
        windows.sort { $0.label == "5-hour" && $1.label != "5-hour" }
        if let review = payload["code_review_rate_limit"] as? [String: Any],
           let block = review["primary_window"] as? [String: Any] {
            windows.append(try window(block, label: "Code review"))
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

    private func window(_ block: [String: Any], label: String) throws -> UsageWindow {
        guard let number = block["used_percent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              (0...100).contains(number.doubleValue) else {
            throw GaugeError(message: "Invalid usage percentage in Codex response.")
        }
        return UsageWindow(label: label, percent: number.doubleValue,
                           reset: parseDate(block["reset_at"] ?? block["resets_at"]))
    }
}
