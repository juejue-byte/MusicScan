import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import SuperwallKit
import WebKit

#if os(iOS)
import UIKit
#endif

struct AuthSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String?
    var provider: String?
    var isAnonymous: Bool

    var userUUID: UUID? {
        UUID(uuidString: userID)
    }

    var displayLabel: String {
        if isAnonymous {
            return "Guest on this device"
        }
        if let email, !email.isEmpty {
            return email
        }
        if let provider, !provider.isEmpty {
            return "Signed in with \(provider.capitalized)"
        }
        return "Your MusicScan account"
    }
}

enum AuthError: LocalizedError {
    case notConfigured
    case server(Int, String)
    case invalidCallback(String)
    case appleSignInUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in is not configured in this build."
        case .server(_, let message):
            return message
        case .invalidCallback(let message):
            return message
        case .appleSignInUnavailable:
            return "Sign in with Apple could not be completed on this device."
        }
    }
}

/// Manages per-user authentication with Supabase Auth over HTTPS REST (no extra SDK dependency).
///
/// User flow:
/// 1. First launch silently creates a guest (anonymous) Supabase account and stores tokens in Keychain.
/// 2. Access tokens are attached to native API calls (`Authorization: Bearer`) and injected into the
///    WKWebView cookie store (`musicscan_session`) before loading and after every refresh.
/// 3. Optional account preservation lets guests link Email, Apple, or Google so their scans and
///    Pro subscription sync across devices, or sign into an existing account from another device.
@MainActor
@Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var session: AuthSession?
    private(set) var isBusy = false
    var lastError: String?
    var statusMessage: String?

    private var supabaseURL: URL?
    private var publishableKey: String
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<AuthSession?, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private weak var cookieStore: WKHTTPCookieStore?
    private var cookieServerURL: URL?

    // Retained during active OAuth / Apple sign-in flows.
    private var pendingPKCEVerifier: String?
    private var pendingAppleNonce: String?
    private var webAuthSession: ASWebAuthenticationSession?
    private let webAuthPresenter = WebAuthPresenter()
    private var appleAuthCoordinator: AppleSignInCoordinator?

    /// Incremented whenever the signed-in user identity changes so views can reload server state if needed.
    private(set) var sessionRevision = 0

    var isConfigured: Bool {
        supabaseURL != nil && !publishableKey.isEmpty
    }

    var userID: String? {
        session?.userID
    }

    var userUUID: UUID? {
        session?.userUUID
    }

    var isGuest: Bool {
        session?.isAnonymous ?? true
    }

    private init() {
        supabaseURL = AppConfig.supabaseURL
        publishableKey = AppConfig.supabasePublishableKey
        session = AuthKeychain.load()
        if let existing = session {
            syncSuperwallIdentity(for: existing)
        }
        startKeepAliveLoop()
    }

    // MARK: - Lifecycle & Bootstrap

    /// Optionally refreshes public Supabase coordinates from the active server's `/api/config`.
    func bootstrapConfig(from serverURL: URL) async {
        guard let configURL = AppConfig.endpoint(base: serverURL, path: "api/config") else { return }
        var request = URLRequest(url: configURL)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let rawURL = json["supabaseUrl"] as? String,
               rawURL.hasPrefix("https://"),
               let parsed = URL(string: rawURL),
               let key = json["supabasePublishableKey"] as? String,
               !key.isEmpty {
                supabaseURL = parsed
                publishableKey = key
            }
        } catch {
            // Keep existing Info.plist / fallback coordinates if server is still waking up.
        }
    }

    /// Quietly establishes an anonymous guest session on first launch, or validates/refreshes an existing session.
    func start() async {
        guard isConfigured else { return }
        if let existingTask = startTask {
            await existingTask.value
            return
        }
        let task = Task { @MainActor in
            if session == nil {
                await signInAnonymously()
            } else {
                _ = await accessToken()
            }
        }
        startTask = task
        await task.value
        if session == nil {
            startTask = nil
        }
    }

    /// Returns a valid access token (refreshing proactively when < 10 minutes remain), or nil if offline.
    func accessToken() async -> String? {
        guard isConfigured else { return nil }
        if session == nil {
            await start()
        }
        guard let current = session else { return nil }
        if current.expiresAt.timeIntervalSinceNow > 600 {
            return current.accessToken
        }
        if let activeRefresh = refreshTask {
            return await activeRefresh.value?.accessToken
        }
        let task = Task<AuthSession?, Never> { @MainActor in
            defer { refreshTask = nil }
            do {
                let response = try await send(
                    "token?grant_type=refresh_token",
                    method: "POST",
                    body: ["refresh_token": current.refreshToken],
                    token: nil
                )
                return adopt(response)
            } catch AuthError.server(let code, _) where code == 400 || code == 401 {
                // Refresh token revoked or already rotated: transparently start a fresh guest session.
                setSession(nil)
                await signInAnonymously()
                return session
            } catch {
                // Offline or transient network issue: preserve the stored session for retry.
                return current
            }
        }
        refreshTask = task
        return await task.value?.accessToken
    }

    func bearerHeader() async -> String? {
        guard let token = await accessToken() else { return nil }
        return "Bearer \(token)"
    }

    // MARK: - WKWebView Cookie Injection

    /// Writes `musicscan_session` into the web view's cookie store before loading so editor `fetch('api/...')` calls are authenticated.
    func prepareWebView(_ store: WKHTTPCookieStore, for serverURL: URL) async {
        cookieStore = store
        cookieServerURL = serverURL
        await start()
        _ = await accessToken()
        await applySessionCookie()
    }

    private func applySessionCookie() async {
        guard let store = cookieStore,
              let serverURL = cookieServerURL,
              let host = serverURL.host else {
            return
        }
        guard let current = session else {
            // Clear stale session cookie if signed out.
            let existing = await store.allCookies()
            for cookie in existing where cookie.name == "musicscan_session" && cookie.domain.contains(host) {
                await store.deleteCookie(cookie)
            }
            return
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "musicscan_session",
            .value: current.accessToken,
            .expires: current.expiresAt,
        ]
        if serverURL.scheme?.lowercased() == "https" {
            properties[.secure] = "TRUE"
        }
        if let cookie = HTTPCookie(properties: properties) {
            await store.setCookie(cookie)
        }
    }

    // MARK: - Anonymous Guest Sign-In

    func signInAnonymously() async {
        do {
            let response = try await send("signup", method: "POST", body: [String: String](), token: nil)
            adopt(response)
        } catch {
            report(error)
        }
    }

    // MARK: - Email Link & OTP Sign-In / Account Linking

    /// Sends a magic sign-in/confirmation link via Supabase Auth.
    /// - Parameters:
    ///   - email: User email address.
    ///   - linkToGuest: When `true` and currently a guest, attaches the email to the same guest account
    ///     so the free page, scans, and Pro subscription carry over. When `false`, signs into an existing account.
    func sendEmailLink(_ email: String, linkToGuest: Bool = true) async -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else {
            lastError = "Please enter a valid email address."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        statusMessage = nil

        let encodedRedirect = AppConfig.authCallbackURLString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let redirectQuery = "redirect_to=\(encodedRedirect)"

        do {
            if linkToGuest, let current = session, current.isAnonymous, let token = await accessToken() {
                _ = try await send(
                    "user?\(redirectQuery)",
                    method: "PUT",
                    body: ["email": trimmed],
                    token: token
                )
                statusMessage = "Check \(trimmed) on this device and tap the confirmation link to keep your account."
            } else {
                _ = try await send(
                    "otp?\(redirectQuery)",
                    method: "POST",
                    body: ["email": trimmed, "create_user": true] as [String: Any],
                    token: nil
                )
                statusMessage = "Check \(trimmed) on this device and tap the sign-in link."
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Verifies a 6-digit email OTP code (supported when custom SMTP templates include `{{ .Token }}`).
    func verifyEmailCode(_ email: String, code: String, linkToGuest: Bool = true) async -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return false }

        isBusy = true
        defer { isBusy = false }
        lastError = nil
        statusMessage = nil

        let attaching = linkToGuest && (session?.isAnonymous ?? false)
        do {
            let response = try await send(
                "verify",
                method: "POST",
                body: [
                    "type": attaching ? "email_change" : "email",
                    "email": trimmedEmail,
                    "token": trimmedCode,
                ],
                token: nil
            )
            if response["access_token"] != nil {
                adopt(response)
            } else if attaching, var current = session {
                current.expiresAt = .distantPast
                setSession(current, bumpRevision: false)
                _ = await accessToken()
            }
            statusMessage = "Email verified and linked to your account."
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Sign in with Apple (Native ASAuthorizationController + Nonce)

    /// Triggers native Sign in with Apple (Face ID / Touch ID) and exchanges the Apple identity token with Supabase.
    func signInWithApple() {
        guard isConfigured else {
            lastError = AuthError.notConfigured.localizedDescription
            return
        }
        lastError = nil
        statusMessage = nil

        let rawNonce = Self.randomURLSafeString(byteCount: 32)
        pendingAppleNonce = rawNonce
        let hashedNonce = Self.sha256Hex(rawNonce)

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce

        let coordinator = AppleSignInCoordinator(
            onSuccess: { [weak self] credential in
                Task { @MainActor in
                    await self?.completeAppleSignIn(credential: credential)
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.appleAuthCoordinator = nil
                    if let authErr = error as? ASAuthorizationError, authErr.code == .canceled {
                        return
                    }
                    self?.report(error)
                }
            }
        )
        appleAuthCoordinator = coordinator

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = coordinator
        controller.presentationContextProvider = coordinator
        controller.performRequests()
    }

    private func completeAppleSignIn(credential: ASAuthorizationAppleIDCredential) async {
        appleAuthCoordinator = nil
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = pendingAppleNonce else {
            pendingAppleNonce = nil
            lastError = AuthError.appleSignInUnavailable.localizedDescription
            return
        }
        pendingAppleNonce = nil

        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await send(
                "token?grant_type=id_token",
                method: "POST",
                body: [
                    "provider": "apple",
                    "id_token": idToken,
                    "nonce": nonce,
                ],
                token: nil
            )
            adopt(response, providerOverride: "apple")
            statusMessage = "Signed in with Apple."
        } catch {
            report(error)
        }
    }

    // MARK: - Sign in / Link with Google (PKCE via ASWebAuthenticationSession)

    /// Starts Google (Gmail) OAuth via Supabase using PKCE (`S256`).
    /// When `linkToGuest` is `true` on an anonymous account, attempts Supabase identity linking first
    /// so the guest's scans and subscription carry over, falling back to standard Google sign-in if manual linking is off.
    func signInWithGoogle(linkToGuest: Bool = true) {
        Task { @MainActor in
            await startOAuth(provider: "google", linkToGuest: linkToGuest)
        }
    }

    private func startOAuth(provider: String, linkToGuest: Bool) async {
        guard let base = supabaseURL else {
            lastError = AuthError.notConfigured.localizedDescription
            return
        }
        isBusy = true
        lastError = nil
        statusMessage = nil

        let verifier = Self.randomURLSafeString(byteCount: 32)
        pendingPKCEVerifier = verifier
        let challenge = Self.pkceChallenge(from: verifier)

        var authorizeURL: URL?

        // Try manual identity linking on an anonymous account first so guest pages/purchases carry over.
        if linkToGuest, let current = session, current.isAnonymous, let token = await accessToken() {
            let encodedRedirect = AppConfig.authCallbackURLString
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let path = "user/identities/authorize?provider=\(provider)&redirect_to=\(encodedRedirect)&skip_http_redirect=true&code_challenge=\(challenge)&code_challenge_method=s256"
            if let linkedResponse = try? await send(path, method: "GET", body: nil, token: token),
               let urlString = linkedResponse["url"] as? String,
               let url = URL(string: urlString) {
                authorizeURL = url
            }
        }

        if authorizeURL == nil {
            var components = URLComponents(
                url: base.appendingPathComponent("auth/v1/authorize"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "provider", value: provider),
                URLQueryItem(name: "redirect_to", value: AppConfig.authCallbackURLString),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "s256"),
            ]
            authorizeURL = components?.url
        }

        isBusy = false

        guard let finalURL = authorizeURL else {
            lastError = "Could not start \(provider.capitalized) sign-in."
            return
        }

        let authSession = ASWebAuthenticationSession(
            url: finalURL,
            callbackURLScheme: AppConfig.authCallbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.webAuthSession = nil
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.report(error)
                    }
                    return
                }
                if let callbackURL {
                    self.handleCallback(callbackURL)
                }
            }
        }
        authSession.presentationContextProvider = webAuthPresenter
        authSession.prefersEphemeralWebBrowserSession = false
        webAuthSession = authSession
        authSession.start()
    }

    // MARK: - Deep Link Callback (`musicscan://auth-callback`)

    /// Handles email confirmation links and OAuth callbacks (both PKCE `?code=` and implicit `#access_token=`).
    func handleCallback(_ url: URL) {
        guard url.scheme?.lowercased() == AppConfig.authCallbackScheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var params: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                params[item.name] = value
            }
        }
        for pair in (components?.fragment ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).removingPercentEncoding ?? String($0)
            }
            if kv.count == 2 {
                params[kv[0]] = kv[1]
            }
        }

        if let errorDescription = params["error_description"] ?? params["error"] {
            lastError = errorDescription.replacingOccurrences(of: "+", with: " ")
            return
        }

        if let authCode = params["code"], let verifier = pendingPKCEVerifier {
            pendingPKCEVerifier = nil
            Task { @MainActor in
                await exchangePKCECode(authCode: authCode, verifier: verifier)
            }
            return
        }

        if let accessToken = params["access_token"], let refreshToken = params["refresh_token"] {
            let expiresIn = Double(params["expires_in"] ?? "3600") ?? 3600
            let payload: [String: Any] = [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "expires_in": expiresIn,
                "user": Self.jwtClaims(accessToken),
            ]
            adopt(payload)
            statusMessage = "You're signed in."
            return
        }

        // Confirmed email change on an existing anonymous session can return without tokens: force refresh.
        if var current = session {
            current.expiresAt = .distantPast
            setSession(current, bumpRevision: false)
            Task { @MainActor in
                _ = await accessToken()
                statusMessage = "Account updated."
            }
        }
    }

    private func exchangePKCECode(authCode: String, verifier: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await send(
                "token?grant_type=pkce",
                method: "POST",
                body: [
                    "auth_code": authCode,
                    "code_verifier": verifier,
                ],
                token: nil
            )
            adopt(response)
            statusMessage = "You're signed in."
        } catch {
            report(error)
        }
    }

    // MARK: - Sign Out

    /// Signs out of the current account and quietly starts a fresh guest account on this device.
    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        statusMessage = nil

        if let current = session {
            _ = try? await send("logout", method: "POST", body: [String: String](), token: current.accessToken)
        }
        setSession(nil)
        if BillingManager.shared.isSuperwallReady {
            Superwall.shared.reset()
        }
        await signInAnonymously()
    }

    // MARK: - Internal Plumbing

    @discardableResult
    private func adopt(_ response: [String: Any], providerOverride: String? = nil) -> AuthSession? {
        guard let access = response["access_token"] as? String,
              let refresh = response["refresh_token"] as? String else {
            return nil
        }
        let expiresIn = (response["expires_in"] as? Double)
            ?? (response["expires_in"] as? Int).map(Double.init)
            ?? 3600
        let claims = Self.jwtClaims(access)
        let userDict = response["user"] as? [String: Any] ?? claims
        let appMetadata = (userDict["app_metadata"] as? [String: Any])
            ?? (claims["app_metadata"] as? [String: Any])
            ?? [:]

        let userID = (userDict["id"] as? String)
            ?? (userDict["sub"] as? String)
            ?? (claims["sub"] as? String)
            ?? ""
        let rawEmail = (userDict["email"] as? String) ?? (claims["email"] as? String)
        let email = rawEmail.flatMap { $0.isEmpty ? nil : $0 }
        let isAnon = (userDict["is_anonymous"] as? Bool)
            ?? (claims["is_anonymous"] as? Bool)
            ?? (email == nil && providerOverride == nil)
        let provider = providerOverride ?? (appMetadata["provider"] as? String)

        let updated = AuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userID: userID,
            email: email,
            provider: provider,
            isAnonymous: isAnon
        )
        // Only bump sessionRevision when switching an already-established user identity (e.g. guest -> signed-in
        // or signing out), avoiding a duplicate cold-start WebView reload during initial guest bootstrap.
        let identityChanged = session != nil
            && (session?.userID != updated.userID || session?.isAnonymous != updated.isAnonymous)
        setSession(updated, bumpRevision: identityChanged)
        lastError = nil
        return updated
    }

    private func setSession(_ newSession: AuthSession?, bumpRevision: Bool = true) {
        session = newSession
        AuthKeychain.save(newSession)
        if let newSession {
            syncSuperwallIdentity(for: newSession)
        }
        if bumpRevision {
            sessionRevision += 1
        }
        Task { @MainActor in
            await applySessionCookie()
        }
    }

    private func syncSuperwallIdentity(for session: AuthSession) {
        guard BillingManager.shared.isSuperwallReady, !session.userID.isEmpty else { return }
        Superwall.shared.identify(userId: session.userID)
        var attributes: [String: Any?] = [
            "is_anonymous": session.isAnonymous,
            "auth_provider": session.provider ?? (session.isAnonymous ? "anonymous" : "email"),
            "email": session.email,
        ]
        if let email = session.email, !email.isEmpty {
            attributes["email"] = email
        }
        Superwall.shared.setUserAttributes(attributes)
    }

    private func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                _ = await self?.accessToken()
            }
        }
    }

    private func report(_ error: Error) {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            lastError = description
        } else {
            lastError = error.localizedDescription
        }
    }

    private func send(
        _ path: String,
        method: String,
        body: Any?,
        token: String?
    ) async throws -> [String: Any] {
        guard let base = supabaseURL,
              let url = URL(string: "auth/v1/\(path)", relativeTo: base.appendingPathComponent("/")) else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(statusCode) else {
            let message = (json["msg"] as? String)
                ?? (json["error_description"] as? String)
                ?? (json["message"] as? String)
                ?? "Sign-in failed (HTTP \(statusCode))."
            throw AuthError.server(statusCode, message)
        }
        return json
    }

    // MARK: - Crypto & JWT Helpers

    static func jwtClaims(_ jwt: String) -> [String: Any] {
        let segments = jwt.split(separator: ".")
        guard segments.count > 1 else { return [:] }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        guard let data = Data(base64Encoded: base64),
              var claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        claims["id"] = claims["sub"]
        return claims
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func pkceChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation Contexts

@MainActor
private func activePresentationAnchor() -> ASPresentationAnchor {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        ?? scenes.first?.windows.first {
        return window
    }
    if let scene = scenes.first {
        return UIWindow(windowScene: scene)
    }
    preconditionFailure("No active UIWindowScene available for authentication presentation.")
    #else
    return NSApplication.shared.windows.first(where: \.isKeyWindow) ?? NSWindow()
    #endif
}

@MainActor
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        activePresentationAnchor()
    }
}

@MainActor
private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let onSuccess: (ASAuthorizationAppleIDCredential) -> Void
    private let onFailure: (Error) -> Void

    init(
        onSuccess: @escaping (ASAuthorizationAppleIDCredential) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        activePresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            onSuccess(credential)
        } else {
            onFailure(AuthError.appleSignInUnavailable)
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        onFailure(error)
    }
}

// MARK: - Keychain Storage

private enum AuthKeychain {
    private static let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.musicscan.auth",
        kSecAttrAccount as String: "supabase.session",
    ]

    static func load() -> AuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ session: AuthSession?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}
