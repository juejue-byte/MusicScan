import AuthenticationServices
import Foundation
import Security
import SwiftUI
import UIKit
import WebKit

/// Sign-in with Supabase Auth, talking to its REST API directly (no package to add).
///
/// - First launch: an anonymous account, with no screen. The server counts the free page and Pro pages against it.
/// - Email: a sign-in link (Supabase's default email), back into the app through musicscan://auth-callback. On an anonymous account the email is added to that same account, so its pages and
///   purchases carry over.
/// - Apple and Google: behind `AuthFlags`, through Supabase's hosted sign-in page (ASWebAuthenticationSession).
///
/// The access token reaches the server two ways: as `Authorization: Bearer` on the app's own requests, and as the
/// `musicscan_session` cookie in the editor's web view (set before each load and after each refresh), so the editor's
/// fetch('api/...') calls carry it too. See server/auth.py.
/// Purchases are not here: StoreKit lives in Store*.swift and should send `AuthManager.shared.userID` as the
/// transaction's appAccountToken.
enum AuthFlags {
    static let email = true
    static let apple = false   // turn on once the Apple provider is configured in Supabase
    static let google = false  // turn on once the Google provider is configured; App Review then requires Apple too
    static let callbackScheme = "musicscan"  // add musicscan://auth-callback to Supabase > Auth > URL Configuration
}

struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String?
    var isAnonymous: Bool
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var session: AuthSession?
    @Published var lastError: String?

    private let base: URL?
    private let apiKey: String
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<AuthSession?, Never>?
    private weak var cookieStore: WKHTTPCookieStore?
    private var cookieServer: URL?
    private var webAuth: ASWebAuthenticationSession?
    private let presenter = WebAuthPresenter()

    var isConfigured: Bool { base != nil && !apiKey.isEmpty }
    var userID: String? { session?.userID }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let url = (info["SupabaseURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        base = url.hasPrefix("https://") ? URL(string: url) : nil
        apiKey = (info["SupabasePublishableKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        session = Keychain.load()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in _ = await AuthManager.shared.accessToken() }  // keeps the web view's cookie fresh
        }
    }

    // MARK: tokens

    /// Signs in anonymously the first time; later launches reuse the saved session.
    func start() async {
        guard isConfigured else { return }
        if startTask == nil {
            startTask = Task { @MainActor in
                if session == nil { await signInAnonymously() } else { _ = await accessToken() }
            }
        }
        await startTask?.value
        if session == nil { startTask = nil }  // offline or refused: try again next time
    }

    /// A token that is valid for at least another 10 minutes (refreshed if needed), or nil when signed out/offline.
    func accessToken() async -> String? {
        guard isConfigured else { return nil }
        if session == nil { await start() }
        guard let s = session else { return nil }
        if s.expiresAt.timeIntervalSinceNow > 600 { return s.accessToken }
        let task = refreshTask ?? Task { @MainActor in
            defer { refreshTask = nil }
            do {
                let r = try await post("token?grant_type=refresh_token", ["refresh_token": s.refreshToken])
                return adopt(r)
            } catch AuthError.server(let code, _) where code == 400 || code == 401 {
                // the refresh token was revoked or already used: start again with a fresh anonymous account
                setSession(nil)
                await signInAnonymously()
                return session
            } catch {
                return nil  // offline: keep the session, try again later
            }
        }
        refreshTask = task
        return await task.value?.accessToken
    }

    /// The `Authorization` header value for a request to the MusicScan server, or nil when not signed in.
    func bearer() async -> String? {
        await accessToken().map { "Bearer " + $0 }
    }

    /// Puts the token into the web view's cookie store for `server`, before the editor loads.
    func prepareWebView(_ store: WKHTTPCookieStore, for server: URL) async {
        cookieStore = store
        cookieServer = server
        await applyCookie()
    }

    private func applyCookie() async {
        guard let store = cookieStore, let server = cookieServer, let host = server.host, let s = session else { return }
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: host, .path: "/", .name: "musicscan_session", .value: s.accessToken, .expires: s.expiresAt,
        ]
        if server.scheme == "https" { props[.secure] = "TRUE" }
        if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
    }

    // MARK: sign-in methods

    func signInAnonymously() async {
        do { adopt(try await post("signup", [String: String]())) } catch { report(error) }
    }

    static var redirectURL: String { "\(AuthFlags.callbackScheme)://auth-callback" }

    /// Email sign-in: Supabase emails a link (its default template). Tapping it on this iPad or iPhone opens the app
    /// through musicscan://auth-callback (`handleCallback`). On a guest account the email is attached to that same
    /// account, so its pages and purchases carry over.
    func sendEmailLink(_ email: String) async -> Bool {
        let redirect = "redirect_to=" + (Self.redirectURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        do {
            if let s = session, s.isAnonymous {
                _ = try await send("user?" + redirect, method: "PUT", body: ["email": email], token: s.accessToken)
            } else {
                _ = try await post("otp?" + redirect, ["email": email, "create_user": true] as [String: Any])
            }
            lastError = nil
            return true
        } catch { report(error); return false }
    }

    /// The email link (or Apple/Google) came back: musicscan://auth-callback#access_token=…&refresh_token=…
    func handleCallback(_ url: URL) {
        guard url.scheme == AuthFlags.callbackScheme else { return }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var q: [String: Any] = [:]
        for item in parts?.queryItems ?? [] { q[item.name] = item.value }
        for pair in (parts?.fragment ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { q[kv[0]] = kv[1] }
        }
        if let e = q["error_description"] as? String {
            lastError = e.replacingOccurrences(of: "+", with: " ")
            return
        }
        if let access = q["access_token"] as? String {
            q["expires_in"] = Double(q["expires_in"] as? String ?? "3600") ?? 3600
            q["user"] = AuthManager.claims(access)
            adopt(q)
        } else if var s = session {
            // a confirmed email change can come back without tokens: refresh so the session carries the email
            s.expiresAt = .distantPast
            setSession(s)
            Task { _ = await accessToken() }
        }
    }

    /// A 6-digit code instead of the link, once custom SMTP lets the email templates include {{ .Token }}.
    func verifyEmailCode(_ email: String, code: String) async -> Bool {
        let attaching = session?.isAnonymous ?? false
        do {
            let r = try await post("verify", ["type": attaching ? "email_change" : "email", "email": email,
                                             "token": code.trimmingCharacters(in: .whitespaces)])
            if r["access_token"] != nil { adopt(r) } else if attaching, var s = session {
                // email added to the anonymous account: refresh so the token carries it
                s.expiresAt = .distantPast
                setSession(s)
                _ = await accessToken()
            }
            lastError = nil
            return true
        } catch { report(error); return false }
    }

    /// Apple or Google through Supabase's hosted page. Starts a separate account (the anonymous one is not merged).
    func signIn(provider: String) {
        guard let base else { return }
        var parts = URLComponents(url: base.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "provider", value: provider),
                            URLQueryItem(name: "redirect_to", value: AuthManager.redirectURL)]
        guard let url = parts.url else { return }
        let web = ASWebAuthenticationSession(url: url, callbackURLScheme: AuthFlags.callbackScheme) { [weak self] cb, err in
            Task { @MainActor in
                guard let self else { return }
                self.webAuth = nil
                if let err, (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self.report(err) }
                if let cb { self.handleCallback(cb) }
            }
        }
        web.presentationContextProvider = presenter
        web.prefersEphemeralWebBrowserSession = false
        webAuth = web
        web.start()
    }

    /// Back to a fresh anonymous account on this device.
    func signOut() async {
        if let s = session { _ = try? await send("logout", method: "POST", body: [String: String](), token: s.accessToken) }
        setSession(nil)
        await signInAnonymously()
    }

    // MARK: plumbing

    @discardableResult
    private func adopt(_ r: [String: Any]) -> AuthSession? {
        guard let access = r["access_token"] as? String, let refresh = r["refresh_token"] as? String else { return nil }
        let expiresIn = (r["expires_in"] as? Double) ?? (r["expires_in"] as? Int).map(Double.init) ?? 3600
        let user = r["user"] as? [String: Any] ?? AuthManager.claims(access)
        let s = AuthSession(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn),
                            userID: user["id"] as? String ?? user["sub"] as? String ?? "",
                            email: (user["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            isAnonymous: user["is_anonymous"] as? Bool ?? false)
        setSession(s)
        lastError = nil
        return s
    }

    private func setSession(_ s: AuthSession?) {
        session = s
        Keychain.save(s)
        Task { await applyCookie() }
    }

    private func report(_ error: Error) {
        if case AuthError.server(_, let msg) = error { lastError = msg } else { lastError = error.localizedDescription }
    }

    /// The claims inside a token (only to read the user id and email; the server does the real verification).
    static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              var c = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        c["id"] = c["sub"]
        return c
    }

    private func post(_ path: String, _ body: Any) async throws -> [String: Any] {
        try await send(path, method: "POST", body: body, token: nil)
    }

    private func send(_ path: String, method: String, body: Any, token: String?) async throws -> [String: Any] {
        guard let base, let url = URL(string: "auth/v1/" + path, relativeTo: base.appendingPathComponent("/")) else {
            throw AuthError.server(0, "Sign-in is not set up in this build.")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = json["msg"] as? String ?? json["error_description"] as? String ?? json["message"] as? String
            throw AuthError.server(code, msg ?? "Sign-in failed (HTTP \(code)).")
        }
        return json
    }
}

enum AuthError: Error { case server(Int, String) }

private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

/// The session in the Keychain (this device only, kept across app updates).
private enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "musicscan.auth", kSecAttrAccount as String: "session"]

    static func load() -> AuthSession? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ s: AuthSession?) {
        SecItemDelete(query as CFDictionary)
        guard let s, let data = try? JSONEncoder().encode(s) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Account section (shown in the Server sheet for now; the Sky design's settings screen can reuse it)

struct AccountSection: View {
    @ObservedObject private var auth = AuthManager.shared
    @State private var email = ""
    @State private var codeSent = false
    @State private var busy = false

    var body: some View {
        if auth.isConfigured {
            Section {
                if let s = auth.session {
                    LabeledContent("Signed in as", value: s.isAnonymous ? "Guest on this device" : (s.email ?? "Your account"))
                } else {
                    Text(busy ? "Connecting…" : "Not connected").foregroundStyle(.secondary)
                }
                if auth.session?.isAnonymous ?? true {
                    if AuthFlags.email { emailRows }
                    if AuthFlags.apple { Button("Continue with Apple") { auth.signIn(provider: "apple") } }
                    if AuthFlags.google { Button("Continue with Google") { auth.signIn(provider: "google") } }
                } else {
                    Button("Sign out", role: .destructive) { Task { busy = true; await auth.signOut(); busy = false } }
                }
                if let err = auth.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Your free page and Pro pages belong to this account. Add your email to keep them if you reinstall or use another iPad or iPhone.")
            }
            .task { if auth.session == nil { busy = true; await auth.start(); busy = false } }
        }
    }

    @ViewBuilder private var emailRows: some View {
        TextField("you@example.com", text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button(busy ? "Sending…" : codeSent ? "Send the link again" : "Email me a sign-in link") {
            Task { busy = true; codeSent = await auth.sendEmailLink(email); busy = false }
        }
        .disabled(busy || !email.contains("@"))
        if codeSent {
            Text("Open the email on this iPad or iPhone and tap the link. It brings you back here, signed in.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
