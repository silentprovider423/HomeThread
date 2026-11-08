import Foundation

/// Fehler vom Server (JSON `{"error": …}`) oder vom Netz.
struct APIError: Error, LocalizedError, Equatable {
    var status: Int
    var code: String
    var retryAfter: Int?
    var left: Int?

    static let offline = APIError(status: 0, code: "offline")

    var isNetwork: Bool { status == 0 || status >= 500 || status == 502 || status == 503 }

    var errorDescription: String? {
        switch code {
        case "offline": return String(localized: "Keine Verbindung zum Server")
        case "invalid":
            if let left { return String(localized: "Benutzername, Passwort oder Code falsch. Noch \(left) Versuch(e).") }
            return String(localized: "Benutzername, Passwort oder Code falsch.")
        case "locked":
            let m = max(1, ((retryAfter ?? 60) + 59) / 60)
            return String(localized: "Zu viele Fehlversuche. Gesperrt für noch \(m) Min.")
        case "rate_limited": return String(localized: "Zu viele Anfragen – bitte kurz warten.")
        case "unauthorized": return String(localized: "Anmeldung abgelaufen oder Gerät abgemeldet.")
        case "weak_password": return String(localized: "Das Passwort braucht mindestens 12 Zeichen.")
        case "too_large": return String(localized: "Die Datei ist zu groß (höchstens 95 MB).")
        case "not_https": return String(localized: "Außerhalb des Heimnetzes nur mit https:// möglich.")
        case "bad_url": return String(localized: "Die Server-Adresse ist ungültig.")
        default: return String(localized: "Serverfehler (\(status)): \(code)")
        }
    }
}

struct LoginResult {
    var token: String
    var deviceId: String
    var user: UserInfo
}

/// Verbindung zum HomeThread-Server. Token im Kopf `Authorization: Bearer`.
final class APIClient {
    let base: URL
    var token: String?
    private let session: URLSession

    init(base: URL, token: String? = nil) {
        self.base = base
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "HomeThread/1.0"]
        session = URLSession(configuration: cfg)
    }

    /// Adresse prüfen: https Pflicht, außer für Heimnetz-Adressen (192.168.x, 10.x, *.local, localhost …).
    static func normalize(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = (isLocalHost(s) ? "http://" : "https://") + s }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty, u.scheme == "http" || u.scheme == "https" else {
            throw APIError(status: -1, code: "bad_url")
        }
        if u.scheme == "http" && !isLocalHost(host) { throw APIError(status: -1, code: "not_https") }
        return u
    }

    static func isLocalHost(_ hostOrURL: String) -> Bool {
        let h = hostOrURL.split(separator: ":").first.map(String.init)?.split(separator: "/").first.map(String.init) ?? hostOrURL
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".home") || h.hasSuffix(".lan") || !h.contains(".") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    private func request(_ method: String, _ path: String, json: Any? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        r.httpMethod = method
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Any {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: r)
        } catch {
            throw APIError.offline
        }
        return try decode(data, resp)
    }

    private func decode(_ data: Data, _ resp: URLResponse) throws -> Any {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        guard (200..<300).contains(status) else {
            let d = obj as? [String: Any] ?? [:]
            throw APIError(status: status, code: d["error"] as? String ?? "http_\(status)",
                           retryAfter: d["retry_after"] as? Int, left: d["left"] as? Int)
        }
        return obj
    }

    // MARK: Anmeldung

    func health() async throws -> Bool {
        let d = try await send(request("GET", "/api/health")) as? [String: Any]
        return d?["ok"] as? Bool == true
    }

    func login(username: String, password: String, code: String, deviceName: String, platform: String) async throws -> LoginResult {
        let d = try await send(request("POST", "/auth/login", json: [
            "username": username, "password": password, "code": code, "device_name": deviceName, "platform": platform,
        ])) as? [String: Any] ?? [:]
        guard let tok = d["token"] as? String, let did = d["device_id"] as? String,
              let u = (d["user"] as? [String: Any]).flatMap(UserInfo.init(json:)) else {
            throw APIError(status: 200, code: "bad_response")
        }
        return LoginResult(token: tok, deviceId: did, user: u)
    }

    func resetPassword(username: String, code: String, newPassword: String) async throws {
        _ = try await send(request("POST", "/auth/reset", json: ["username": username, "code": code, "new_password": newPassword]))
    }

    func logout() async throws {
        _ = try await send(request("POST", "/auth/logout", json: [String: Any]()))
    }

    func me() async throws -> (UserInfo, String) {
        let d = try await send(request("GET", "/api/me")) as? [String: Any] ?? [:]
        guard let u = (d["user"] as? [String: Any]).flatMap(UserInfo.init(json:)), let did = d["device_id"] as? String else {
            throw APIError(status: 200, code: "bad_response")
        }
        return (u, did)
    }

    func changePassword(current: String, new: String, code: String) async throws {
        _ = try await send(request("POST", "/api/account/password", json: ["current": current, "new": new, "code": code]))
    }

    func devices() async throws -> [DeviceInfo] {
        let d = try await send(request("GET", "/api/devices")) as? [String: Any] ?? [:]
        return (d["devices"] as? [[String: Any]] ?? []).map {
            DeviceInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", platform: $0["platform"] as? String ?? "",
                       created: Date(timeIntervalSince1970: $0["created"] as? Double ?? 0),
                       lastSeen: Date(timeIntervalSince1970: $0["last_seen"] as? Double ?? 0),
                       current: $0["current"] as? Bool ?? false)
        }
    }

    func revokeDevice(_ id: String) async throws {
        _ = try await send(request("DELETE", "/api/devices/\(id)"))
    }

    func renameDevice(_ id: String, name: String) async throws {
        _ = try await send(request("PATCH", "/api/devices/\(id)", json: ["name": name]))
    }

    func users() async throws -> [UserInfo] {
        let d = try await send(request("GET", "/api/users")) as? [String: Any] ?? [:]
        return (d["users"] as? [[String: Any]] ?? []).compactMap(UserInfo.init(json:))
    }

    // MARK: Abgleich

    struct SyncPage {
        var changes: [[String: Any]]
        var next: Int
        var more: Bool
    }

    func sync(since: Int, limit: Int = 500, room: String? = nil) async throws -> SyncPage {
        var path = "/api/sync?since=\(since)&limit=\(limit)"
        if let room { path += "&room=\(room)" }
        let d = try await send(request("GET", path)) as? [String: Any] ?? [:]
        return SyncPage(changes: d["changes"] as? [[String: Any]] ?? [], next: d["next"] as? Int ?? since, more: d["more"] as? Bool ?? false)
    }

    func ops(_ ops: [[String: Any]]) async throws -> [[String: Any]] {
        let d = try await send(request("POST", "/api/ops", json: ["ops": ops])) as? [String: Any] ?? [:]
        return d["results"] as? [[String: Any]] ?? []
    }

    func putBlob(id: String, file: URL, mime: String, filename: String) async throws {
        var r = request("PUT", "/api/blobs/\(id)")
        r.setValue(mime, forHTTPHeaderField: "Content-Type")
        r.setValue(filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "X-Filename")
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.upload(for: r, fromFile: file)
        } catch {
            throw APIError.offline
        }
        _ = try decode(data, resp)
    }

    func getBlob(id: String, to dest: URL) async throws {
        let r = request("GET", "/api/blobs/\(id)")
        let tmp: URL, resp: URLResponse
        do {
            (tmp, resp) = try await session.download(for: r)
        } catch {
            throw APIError.offline
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw APIError(status: status, code: "http_\(status)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
