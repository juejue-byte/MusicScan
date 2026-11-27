import Foundation
import Observation
import StoreKit
import SuperwallKit

#if os(iOS)
import UIKit
#endif

struct VerifiedEntitlement: Equatable, Sendable {
    var active: Bool
    var productID: String?
    var periodEnd: String?
    var isTrial: Bool
}

struct PaywallPresentationRequest: Identifiable {
    let id = UUID()
    let placement: String
    let reason: String
    let jobID: String?
}

enum BillingError: LocalizedError {
    case missingAccount
    case missingServerURL
    case productUnavailable
    case unverifiedTransaction
    case serverRejected(String)
    case unlockFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return "Could not confirm your MusicScan account. Please check your connection and try again."
        case .missingServerURL:
            return "The MusicScan server address is not configured."
        case .productUnavailable:
            return "Subscription plans are not available from the App Store right now. Check your StoreKit / App Store Connect setup."
        case .unverifiedTransaction:
            return "Apple could not verify this purchase transaction on device."
        case .serverRejected(let message):
            return message
        case .unlockFailed(let message):
            return message
        }
    }
}

/// Coordinates StoreKit 2 subscriptions, Superwall paywalls, and MusicScan server verification.
///
/// Security model:
/// - Every StoreKit 2 purchase attaches `appAccountToken = UUID(AuthManager.shared.userID)`.
/// - Every verified JWS transaction is sent to `POST /api/billing/transaction` with the user's Supabase Bearer token.
/// - The MusicScan server verifies Apple's certificate chain, bundle ID, product ID, expiry, and `appAccountToken`
///   before updating Supabase entitlements (`set_entitlement`) and unlocking preview jobs (`POST /api/jobs/{id}/unlock`).
@MainActor
@Observable
final class BillingManager: PurchaseController, SuperwallDelegate {
    static let shared = BillingManager()

    private(set) var products: [StoreKit.Product] = []
    private(set) var entitlement = VerifiedEntitlement(active: false, productID: nil, periodEnd: nil, isTrial: false)
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var isSuperwallReady = false
    private(set) var superwallSubscriptionStatus: SuperwallKit.SubscriptionStatus = .unknown
    var lastError: String?
    var statusMessage: String?

    /// Non-nil when presenting the built-in Sky StoreKit 2 paywall fallback
    /// (used when no Superwall key is set or when a placement is not yet assigned to a campaign).
    var fallbackPaywallRequest: PaywallPresentationRequest?

    private var hasConfigured = false
    private var activeServerURL: URL? = AppConfig.normalizedServerURL(from: AppConfig.defaultServerAddress)
    private var transactionListenerTask: Task<Void, Never>?
    private var paywallCompletion: ((Bool) -> Void)?

    private static let bypassPaywallKey = "musicScan.debugBypassPaywall"

    /// When enabled (default `true` in `DEBUG` builds), bypasses client-side preview lock veils and paywall guards
    /// so developers and testers can freely test multi-page scanning, editing, playback, and export without paywall interruptions.
    var bypassPaywallForTesting: Bool = {
        if UserDefaults.standard.object(forKey: BillingManager.bypassPaywallKey) != nil {
            return UserDefaults.standard.bool(forKey: BillingManager.bypassPaywallKey)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }() {
        didSet {
            UserDefaults.standard.set(bypassPaywallForTesting, forKey: Self.bypassPaywallKey)
        }
    }

    var isPro: Bool {
        entitlement.active || bypassPaywallForTesting
    }

    var yearlyProduct: StoreKit.Product? {
        products.first { $0.id == AppConfig.ProductID.yearly }
    }

    var monthlyProduct: StoreKit.Product? {
        products.first { $0.id == AppConfig.ProductID.monthly }
    }

    private init() {}

    // MARK: - Startup

    func configure(serverURL: URL?) {
        if let serverURL {
            activeServerURL = serverURL
        }
        guard !hasConfigured else { return }
        hasConfigured = true

        startTransactionListener()
        configureSuperwallIfAvailable()
        Task { @MainActor in
            await loadProducts()
            await syncExistingEntitlements(notifyServer: false, surfaceErrors: false)
        }
    }

    func updateServerURL(_ url: URL?) {
        activeServerURL = url
    }

    private func configureSuperwallIfAvailable() {
        guard !isSuperwallReady, AppConfig.isSuperwallConfigured else { return }
        Superwall.configure(
            apiKey: AppConfig.superwallAPIKey,
            purchaseController: self
        )
        Superwall.shared.delegate = self
        isSuperwallReady = true
        if let session = AuthManager.shared.session, !session.userID.isEmpty {
            Superwall.shared.identify(userId: session.userID)
            Superwall.shared.setUserAttributes([
                "is_anonymous": session.isAnonymous,
                "auth_provider": session.provider ?? (session.isAnonymous ? "anonymous" : "email"),
                "email": session.email,
            ])
        }
        syncSuperwallSubscriptionStatus()
    }

    // MARK: - SuperwallDelegate

    func subscriptionStatusDidChange(
        from oldValue: SuperwallKit.SubscriptionStatus,
        to newValue: SuperwallKit.SubscriptionStatus
    ) {
        superwallSubscriptionStatus = newValue
    }

    func loadProducts() async {
        do {
            let loaded = try await StoreKit.Product.products(for: AppConfig.ProductID.all)
            products = loaded.sorted { lhs, _ in
                lhs.id == AppConfig.ProductID.yearly
            }
        } catch {
            // Products may be empty before App Store Connect / StoreKit configuration is active.
        }
    }

    // MARK: - Paywall Presentation

    /// Presents the Superwall paywall (or the built-in Sky StoreKit 2 paywall fallback when no Superwall key is configured).
    /// Resolves `true` only when a purchase or restore succeeded and the server verified an active entitlement.
    func presentPaywall(
        placement: String? = nil,
        reason: String = "See every bar, fix it on the staff, play it and export it.",
        jobID: String? = nil
    ) async -> Bool {
        let resolvedPlacement = placement ?? AppConfig.superwallUnlockPlacement
        lastError = nil
        statusMessage = nil

        if products.isEmpty {
            await loadProducts()
        }

        if isSuperwallReady {
            let outcome = await presentSuperwallPaywall(placement: resolvedPlacement, reason: reason)
            switch outcome {
            case .completed(let unlocked):
                return unlocked
            case .fallbackToNativePaywall:
                break
            }
        }

        return await withCheckedContinuation { continuation in
            paywallCompletion = { unlocked in
                continuation.resume(returning: unlocked)
            }
            fallbackPaywallRequest = PaywallPresentationRequest(
                placement: resolvedPlacement,
                reason: reason,
                jobID: jobID
            )
        }
    }

    func dismissFallbackPaywall(unlocked: Bool) {
        fallbackPaywallRequest = nil
        let completion = paywallCompletion
        paywallCompletion = nil
        completion?(unlocked)
    }

    private enum SuperwallPaywallOutcome {
        case completed(Bool)
        case fallbackToNativePaywall
    }

    private func presentSuperwallPaywall(placement: String, reason: String) async -> SuperwallPaywallOutcome {
        await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ outcome: SuperwallPaywallOutcome) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }

            let handler = PaywallPresentationHandler()
            handler.onDismiss { [weak self] _, result in
                Task { @MainActor in
                    guard let self else {
                        finish(.completed(false))
                        return
                    }
                    switch result {
                    case .purchased, .restored:
                        finish(.completed(self.isPro))
                    case .declined:
                        finish(.completed(false))
                    }
                }
            }
            handler.onSkip { [weak self] skipReason in
                Task { @MainActor in
                    guard let self else {
                        finish(.completed(false))
                        return
                    }
                    if self.isPro {
                        finish(.completed(true))
                    } else if skipReason == .placementNotFound {
                        // Placement isn't attached to a live Superwall campaign yet — show native StoreKit 2 paywall.
                        finish(.fallbackToNativePaywall)
                    } else {
                        finish(.completed(false))
                    }
                }
            }
            handler.onError { [weak self] error in
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    finish(.fallbackToNativePaywall)
                }
            }

            Superwall.shared.register(
                placement: placement,
                params: ["reason": reason],
                handler: handler
            ) { [weak self] in
                Task { @MainActor in
                    finish(.completed(self?.isPro ?? false))
                }
            }
        }
    }

    // MARK: - Superwall PurchaseController Conformance

    func purchase(product: StoreProduct) async -> PurchaseResult {
        guard let sk2Product = product.sk2Product else {
            return .failed(BillingError.productUnavailable)
        }
        return await executeStoreKitPurchase(sk2Product)
    }

    func restorePurchases() async -> RestorationResult {
        isRestoring = true
        defer { isRestoring = false }
        lastError = nil
        statusMessage = nil

        do {
            try await AppStore.sync()
            let verified = await syncExistingEntitlements(notifyServer: true)
            if verified {
                statusMessage = "MusicScan Pro restored."
            } else if lastError == nil {
                statusMessage = "No active MusicScan Pro subscription was found for this Apple Account."
            }
            return .restored
        } catch {
            lastError = error.localizedDescription
            return .failed(error)
        }
    }

    // MARK: - Direct StoreKit 2 Purchase (used by Fallback Paywall & Superwall PurchaseController)

    func purchaseProduct(id productID: String) async -> Bool {
        if products.isEmpty {
            await loadProducts()
        }
        guard let product = products.first(where: { $0.id == productID }) else {
            lastError = BillingError.productUnavailable.localizedDescription
            return false
        }
        let result = await executeStoreKitPurchase(product)
        switch result {
        case .purchased:
            return isPro
        case .cancelled:
            return false
        case .pending:
            statusMessage = "Your purchase is pending approval."
            return false
        case .failed(let error):
            lastError = error.localizedDescription
            return false
        }
    }

    private func executeStoreKitPurchase(_ product: StoreKit.Product) async -> PurchaseResult {
        isPurchasing = true
        defer { isPurchasing = false }
        lastError = nil
        statusMessage = nil

        await AuthManager.shared.start()
        guard let accountUUID = AuthManager.shared.userUUID else {
            let error = BillingError.missingAccount
            lastError = error.localizedDescription
            return .failed(error)
        }

        do {
            let result = try await product.purchase(options: [.appAccountToken(accountUUID)])
            switch result {
            case .success(let verificationResult):
                switch verificationResult {
                case .unverified:
                    let error = BillingError.unverifiedTransaction
                    lastError = error.localizedDescription
                    return .failed(error)
                case .verified(let transaction):
                    let jws = verificationResult.jwsRepresentation
                    do {
                        let verified = try await verifyTransactionWithServer(jwsRepresentation: jws)
                        await transaction.finish()
                        entitlement = verified
                        syncSuperwallSubscriptionStatus()
                        if verified.active {
                            statusMessage = "MusicScan Pro is active."
                            return .purchased
                        } else {
                            let error = BillingError.serverRejected("The subscription is not currently active.")
                            lastError = error.localizedDescription
                            return .failed(error)
                        }
                    } catch {
                        // Finish local StoreKit transaction to avoid repeated prompts if server rejected a local test cert.
                        await transaction.finish()
                        #if DEBUG
                        if transaction.environment == .xcode {
                            let localExpiryISO = transaction.expirationDate.map { ISO8601DateFormatter().string(from: $0) }
                            entitlement = VerifiedEntitlement(
                                active: true,
                                productID: transaction.productID,
                                periodEnd: localExpiryISO,
                                isTrial: false
                            )
                            syncSuperwallSubscriptionStatus(activeProductIDs: [transaction.productID])
                            statusMessage = "MusicScan Pro active (Xcode StoreKit)."
                            return .purchased
                        }
                        #endif
                        lastError = error.localizedDescription
                        return .failed(error)
                    }
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .cancelled
            }
        } catch {
            lastError = error.localizedDescription
            return .failed(error)
        }
    }

    // MARK: - Server Verification & Job Unlock

    /// Sends Apple's signed StoreKit JWS transaction to `POST /api/billing/transaction`.
    func verifyTransactionWithServer(jwsRepresentation: String) async throws -> VerifiedEntitlement {
        guard let serverURL = activeServerURL,
              let endpoint = AppConfig.endpoint(base: serverURL, path: "api/billing/transaction") else {
            throw BillingError.missingServerURL
        }
        if AuthManager.shared.session == nil {
            await AuthManager.shared.start()
        }
        guard var bearer = await AuthManager.shared.bearerHeader() else {
            throw BillingError.missingAccount
        }

        let payload = try JSONSerialization.data(withJSONObject: [
            "signedTransaction": jwsRepresentation
        ])

        func send(with authHeader: String) async throws -> (Data, Int) {
            var request = URLRequest(url: endpoint, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        var (data, statusCode) = try await send(with: bearer)
        if statusCode == 401 {
            await AuthManager.shared.start()
            if let refreshed = await AuthManager.shared.bearerHeader() {
                bearer = refreshed
                (data, statusCode) = try await send(with: bearer)
            }
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(statusCode) else {
            let detail = (json["detail"] as? String)
                ?? "Server could not verify this Apple purchase (HTTP \(statusCode))."
            throw BillingError.serverRejected(detail)
        }

        return VerifiedEntitlement(
            active: json["active"] as? Bool ?? false,
            productID: json["product_id"] as? String,
            periodEnd: json["period_end"] as? String,
            isTrial: json["is_trial"] as? Bool ?? false
        )
    }

    /// Calls `POST /api/jobs/{jobID}/unlock` after a verified subscription, then fetches the unlocked full job payload.
    func unlockJob(jobID: String) async throws -> [String: Any] {
        guard let serverURL = activeServerURL,
              let unlockURL = AppConfig.endpoint(base: serverURL, path: "api/jobs/\(jobID)/unlock"),
              let jobURL = AppConfig.endpoint(base: serverURL, path: "api/jobs/\(jobID)") else {
            throw BillingError.missingServerURL
        }
        guard let bearer = await AuthManager.shared.bearerHeader() else {
            throw BillingError.missingAccount
        }

        var unlockRequest = URLRequest(url: unlockURL, timeoutInterval: 30)
        unlockRequest.httpMethod = "POST"
        unlockRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        unlockRequest.setValue(bearer, forHTTPHeaderField: "Authorization")

        let (unlockData, unlockResponse) = try await URLSession.shared.data(for: unlockRequest)
        let unlockCode = (unlockResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(unlockCode) else {
            let body = (try? JSONSerialization.jsonObject(with: unlockData)) as? [String: Any]
            let detailObj = body?["detail"]
            let message: String
            if let dict = detailObj as? [String: Any], let msg = dict["message"] as? String {
                message = msg
            } else if let str = detailObj as? String {
                message = str
            } else {
                message = "Could not unlock this page (HTTP \(unlockCode))."
            }
            throw BillingError.unlockFailed(message)
        }

        var jobRequest = URLRequest(url: jobURL, timeoutInterval: 30)
        jobRequest.httpMethod = "GET"
        jobRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        jobRequest.setValue(bearer, forHTTPHeaderField: "Authorization")

        let (jobData, jobResponse) = try await URLSession.shared.data(for: jobRequest)
        let jobCode = (jobResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(jobCode),
              let jobJSON = (try? JSONSerialization.jsonObject(with: jobData)) as? [String: Any] else {
            throw BillingError.unlockFailed("Unlocked on server, but could not reload the full score.")
        }
        return jobJSON
    }

    // MARK: - StoreKit 2 Transaction Monitoring & Entitlement Sync

    @discardableResult
    func syncExistingEntitlements(notifyServer: Bool, surfaceErrors: Bool = true) async -> Bool {
        var foundActiveProductIDs: Set<String> = []
        var latestVerified: VerifiedEntitlement?
        var offlineFallbackEntitlement: VerifiedEntitlement?

        for await verificationResult in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verificationResult else { continue }
            guard AppConfig.ProductID.all.contains(transaction.productID),
                  transaction.revocationDate == nil else {
                continue
            }
            if let expiry = transaction.expirationDate, expiry <= Date() {
                continue
            }

            let localExpiryISO = transaction.expirationDate.map { ISO8601DateFormatter().string(from: $0) }
            if notifyServer {
                do {
                    let serverEntitlement = try await verifyTransactionWithServer(
                        jwsRepresentation: verificationResult.jwsRepresentation
                    )
                    if serverEntitlement.active {
                        foundActiveProductIDs.insert(transaction.productID)
                        latestVerified = serverEntitlement
                    }
                } catch is URLError {
                    // Offline or transient network error: honor Apple's on-device verified StoreKit 2 entitlement
                    // so paying subscribers keep editing/practising offline (server still enforces new scans).
                    foundActiveProductIDs.insert(transaction.productID)
                    offlineFallbackEntitlement = VerifiedEntitlement(
                        active: true,
                        productID: transaction.productID,
                        periodEnd: localExpiryISO,
                        isTrial: false
                    )
                    if surfaceErrors {
                        lastError = "Verified on this device; server sync will complete once you're back online."
                    }
                } catch {
                    #if DEBUG
                    if transaction.environment == .xcode {
                        foundActiveProductIDs.insert(transaction.productID)
                        offlineFallbackEntitlement = VerifiedEntitlement(
                            active: true,
                            productID: transaction.productID,
                            periodEnd: localExpiryISO,
                            isTrial: false
                        )
                        continue
                    }
                    #endif
                    // Keep checking remaining entitlements; capture error only when surfaced (e.g. Restore).
                    if surfaceErrors {
                        lastError = error.localizedDescription
                    }
                }
            } else {
                foundActiveProductIDs.insert(transaction.productID)
                offlineFallbackEntitlement = VerifiedEntitlement(
                    active: true,
                    productID: transaction.productID,
                    periodEnd: localExpiryISO,
                    isTrial: false
                )
            }
        }

        if let latestVerified {
            entitlement = latestVerified
        } else if let offlineFallbackEntitlement {
            entitlement = offlineFallbackEntitlement
        } else {
            entitlement = VerifiedEntitlement(active: false, productID: nil, periodEnd: nil, isTrial: false)
        }

        syncSuperwallSubscriptionStatus(activeProductIDs: foundActiveProductIDs)
        return entitlement.active
    }

    private func startTransactionListener() {
        guard transactionListenerTask == nil else { return }
        transactionListenerTask = Task { [weak self] in
            for await verificationResult in Transaction.updates {
                guard !Task.isCancelled else { break }
                guard case .verified(let transaction) = verificationResult else { continue }
                if AppConfig.ProductID.all.contains(transaction.productID) {
                    if let serverEntitlement = try? await self?.verifyTransactionWithServer(
                        jwsRepresentation: verificationResult.jwsRepresentation
                    ) {
                        await MainActor.run {
                            self?.entitlement = serverEntitlement
                            self?.syncSuperwallSubscriptionStatus()
                        }
                    }
                }
                await transaction.finish()
            }
        }
    }

    private func syncSuperwallSubscriptionStatus(activeProductIDs: Set<String>? = nil) {
        guard isSuperwallReady else { return }
        if entitlement.active {
            let productIDs = activeProductIDs ?? Set([entitlement.productID].compactMap { $0 })
            let deviceEntitlements = Superwall.shared.entitlements.byProductIds(productIDs)
            if deviceEntitlements.isEmpty {
                Superwall.shared.subscriptionStatus = .active([Entitlement(id: "pro")])
            } else {
                Superwall.shared.subscriptionStatus = .active(deviceEntitlements)
            }
        } else {
            Superwall.shared.subscriptionStatus = .inactive
        }
        Superwall.shared.setUserAttributes([
            "is_pro": entitlement.active,
            "plan_product_id": entitlement.productID,
        ])
    }

    // MARK: - Manage Subscription

    func openManageSubscriptions() async {
        #if os(iOS)
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }
        try? await AppStore.showManageSubscriptions(in: windowScene)
        #endif
    }
}
