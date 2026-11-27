#if canImport(AppKit)
import AppKit
import CryptoKit
import Foundation
import GizmoCore
import Network
import Security

/// Spotify's Web API, after signing in once in the browser (Authorization
/// Code with PKCE, so no client secret). Fills the up-next side of the
/// album art carousel from the player queue, lists your playlists, and
/// plays one on request. The refresh token lives in the login Keychain.
public actor SpotifyProvider: Provider {
    public nonisolated let id = "spotify"
    private var bus: EventBus?
    private var settings: SpotifySettings
    private weak var media: MediaProvider?
    private var token: Token?
    private var status = SpotifyStatus()
    private var listener: NWListener?
    private var verifier: String?
    private var state: String?
    private var lastTrackKey: String?
    private var watch: Task<Void, Never>?
    private let keychain = Keychain(service: "io.thomasmelak.gizmobar.spotify")

    static let spotifyApp = "com.spotify.client"
    static let scopes = [
        "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing",
        "playlist-read-private", "playlist-read-collaborative", "user-read-private",
    ]

    struct Token {
        var access: String
        var refresh: String
        var expires: Date
    }

    public init(settings: SpotifySettings, media: MediaProvider) {
        self.settings = settings
        self.media = media
    }

    public func start(bus: EventBus) async {
        self.bus = bus
        status.configured = settings.isConfigured
        if let refresh = keychain.read(), settings.isConfigured {
            token = Token(access: "", refresh: refresh, expires: .distantPast)
            status.signedIn = true
            await loadAccount()
        }
        await publish()
        watch = Task { [weak self] in
            for await event in await bus.subscribe(prefixes: [Topic.media]) {
                guard let status = event.payload.decode(NowPlayingStatus.self) else { continue }
                await self?.mediaChanged(status)
            }
        }
    }

    public func stop() async {
        watch?.cancel()
        listener?.cancel()
    }

    public func update(settings: SpotifySettings) async {
        guard settings != self.settings else { return }
        self.settings = settings
        status.configured = settings.isConfigured
        await publish()
    }

    // MARK: Sign in

    /// Opens Spotify's sign-in page; the browser comes back to a one-shot
    /// listener on 127.0.0.1.
    public func login() async {
        guard let clientID = settings.clientID, !clientID.isEmpty else {
            status.error = "Add client_id under [spotify] in config.toml"
            return await publish()
        }
        let verifier = Self.randomString(64)
        let state = Self.randomString(16)
        self.verifier = verifier
        self.state = state
        do {
            try startListener()
        } catch {
            status.error = "Can't listen on port \(settings.port): \(error.localizedDescription)"
            return await publish()
        }
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: settings.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        status.signingIn = true
        status.error = nil
        await publish()
        let target = url.url!
        await MainActor.run { _ = NSWorkspace.shared.open(target) }
        // Give up waiting after 5 minutes.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            await self?.cancelLogin()
        }
    }

    public func logout() async {
        keychain.delete()
        token = nil
        status = SpotifyStatus(configured: settings.isConfigured)
        await media?.setUpNext(Self.spotifyApp, nil)
        await publish()
    }

    private func cancelLogin() async {
        guard status.signingIn else { return }
        listener?.cancel()
        listener = nil
        status.signingIn = false
        await publish()
    }

    private func startListener() throws {
        listener?.cancel()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(settings.port)))
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            let owner = self
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let query = Self.callbackQuery(request)
                let ok = query["code"] != nil
                let body = ok
                    ? "<h3 style='font-family:-apple-system'>Signed in to Spotify. You can close this tab.</h3>"
                    : "<h3 style='font-family:-apple-system'>Sign-in didn't finish: \(query["error"] ?? "no code").</h3>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                if query["code"] != nil || query["error"] != nil {
                    Task { await owner?.finishLogin(query) }
                }
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    /// `GET /callback?code=...&state=... HTTP/1.1` → its query items.
    static func callbackQuery(_ request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: "http://127.0.0.1" + parts[1]),
              url.path == "/callback" else { return [:] }
        var out: [String: String] = [:]
        for item in url.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    private func finishLogin(_ query: [String: String]) async {
        listener?.cancel()
        listener = nil
        status.signingIn = false
        guard query["state"] == state, let code = query["code"], let verifier, let clientID = settings.clientID else {
            status.error = query["error"].map { "Spotify: \($0)" } ?? "Sign-in didn't match; try again"
            return await publish()
        }
        let form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": settings.redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ]
        do {
            try await requestToken(form)
            status.signedIn = true
            status.error = nil
            await loadAccount()
            lastTrackKey = nil
        } catch {
            status.error = "Spotify sign-in failed: \(error.localizedDescription)"
        }
        await publish()
    }

    private func requestToken(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw SpotifyError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let refresh = json["refresh_token"] as? String ?? token?.refresh ?? ""
        let expiresIn = json["expires_in"] as? Double ?? 3600
        token = Token(access: access, refresh: refresh, expires: Date().addingTimeInterval(expiresIn - 60))
        if !refresh.isEmpty { keychain.write(refresh) }
    }

    /// A fresh access token, refreshing it when it has expired.
    private func accessToken() async -> String? {
        guard var t = token else { return nil }
        if t.expires > Date(), !t.access.isEmpty { return t.access }
        guard let clientID = settings.clientID else { return nil }
        do {
            try await requestToken(["grant_type": "refresh_token", "refresh_token": t.refresh, "client_id": clientID])
            t = token ?? t
            return t.access
        } catch SpotifyError.http(let code) where code == 400 || code == 401 {
            // Revoked or expired: sign out so the popover offers sign-in.
            await logout()
            return nil
        } catch {
            return nil
        }
    }

    // MARK: API

    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Any? {
        guard let access = await accessToken() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 { token?.expires = .distantPast }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func loadAccount() async {
        if let me = await api("/me") as? [String: Any] {
            status.user = me["display_name"] as? String ?? me["id"] as? String
        }
        guard let page = await api("/me/playlists?limit=30") as? [String: Any],
              let items = page["items"] as? [[String: Any]] else { return }
        var playlists: [PlaylistRef] = []
        for item in items {
            guard let name = item["name"] as? String, let uri = item["uri"] as? String else { continue }
            let art = await Self.cacheImage(Self.image(item["images"], near: 64), key: uri)
            let tracks = (item["tracks"] as? [String: Any])?["total"] as? Int
            playlists.append(PlaylistRef(name: name, uri: uri, artworkPath: art?.path, tracks: tracks))
        }
        status.playlists = playlists
    }

    /// Plays a playlist (or any Spotify URI) in the Spotify app.
    public func play(_ uri: String) async {
        guard uri.hasPrefix("spotify:") else { return }
        let escaped = uri.replacingOccurrences(of: "\"", with: "")
        _ = try? await Command.run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to play track \"\(escaped)\""])
    }

    // MARK: Queue

    private func mediaChanged(_ np: NowPlayingStatus) async {
        guard status.signedIn, let spotify = np.sources.first(where: { $0.id == Self.spotifyApp }),
              let key = spotify.track?.key, key != lastTrackKey else { return }
        lastTrackKey = key
        // Spotify updates its queue a moment after the track changes.
        try? await Task.sleep(for: .milliseconds(800))
        guard lastTrackKey == key else { return }
        await refreshQueue()
    }

    public func refreshQueue() async {
        guard let q = await api("/me/player/queue") as? [String: Any],
              let items = q["queue"] as? [[String: Any]] else { return }
        var cards: [TrackCard] = []
        for item in items.prefix(3) {
            guard let title = item["name"] as? String else { continue }
            let uri = item["uri"] as? String
            let artist = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
                ?? ((item["show"] as? [String: Any])?["name"] as? String) ?? ""
            let images = (item["album"] as? [String: Any])?["images"] ?? item["images"]
            let file = await Self.cacheImage(Self.image(images, near: 300), key: uri ?? title)
            cards.append(TrackCard(title: title, artist: artist, artworkPath: file?.path,
                                   artColor: file.flatMap(MediaProvider.color(of:)), uri: uri))
        }
        await media?.setUpNext(Self.spotifyApp, cards)
    }

    // MARK: Helpers

    private func publish() async {
        await bus?.publish(topic: Topic.spotify, payload: JSONValue(encoding: status))
    }

    /// The image URL closest to `near` pixels wide.
    static func image(_ images: Any?, near: Int) -> URL? {
        guard let list = images as? [[String: Any]] else { return nil }
        let best = list.min { a, b in
            abs((a["width"] as? Int ?? near) - near) < abs((b["width"] as? Int ?? near) - near)
        }
        return (best?["url"] as? String).flatMap(URL.init(string:))
    }

    static func cacheImage(_ url: URL?, key: String) async -> URL? {
        guard let url else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gizmobar/spotify", isDirectory: true)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let file = dir.appendingPathComponent(digest)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return file
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(rng.next(upperBound: UInt(chars.count)))] })
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)" }
            .sorted().joined(separator: "&")
    }
}

enum SpotifyError: Error { case http(Int) }

/// One generic password in the login Keychain.
struct Keychain: Sendable {
    let service: String
    var account = "refresh-token"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}
#endif
