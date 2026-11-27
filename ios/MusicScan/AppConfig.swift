import Foundation
import Observation
import SwiftUI

/// Records per-page and per-scan latency metrics (SLI) so we can track and improve end-to-end scan performance.
struct ScanSLIEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let title: String
    let jobID: String
    let pageNumber: Int
    let totalPages: Int
    /// On-device orientation normalization + downscale + JPEG encoding duration (milliseconds) for the batch.
    let onDevicePrepMs: Int
    /// End-to-end network + queue + Modal GPU transcription wall-clock time for this page (seconds).
    let pageWallSeconds: Double
    /// Server-reported `copisteria` OMR inference time (`result.seconds`) if available.
    let serverOmrSeconds: Double?
    /// Network + queue + preprocessing overhead (`pageWallSeconds - serverOmrSeconds`).
    var overheadSeconds: Double {
        guard let omr = serverOmrSeconds else { return 0 }
        return max(0, pageWallSeconds - omr)
    }
    let measuresCount: Int
    let fastMode: Bool
    let accessMode: String
}

/// Persistent SLI latency recorder stored in `UserDefaults` (`musicScan.sliEntries`).
@MainActor
@Observable
final class ScanSLIRecorder {
    static let shared = ScanSLIRecorder()

    private static let storageKey = "musicScan.sliEntries.v1"
    private static let maxEntries = 50

    private(set) var entries: [ScanSLIEntry] = []
    /// Most recent batch on-device prep duration (milliseconds), attached to the next completed scan jobs.
    var lastOnDevicePrepMs: Int = 0
    var lastBatchPageCount: Int = 1

    private init() {
        load()
    }

    var latest: ScanSLIEntry? {
        entries.first
    }

    /// Median (p50) single-page wall-clock duration in seconds across recorded scans.
    var p50WallSeconds: Double? {
        percentile(0.50, of: entries.map(\.pageWallSeconds))
    }

    /// 95th percentile (p95) single-page wall-clock duration in seconds across recorded scans.
    var p95WallSeconds: Double? {
        percentile(0.95, of: entries.map(\.pageWallSeconds))
    }

    /// Median (p50) server OMR inference time (`result.seconds`).
    var p50ServerOmrSeconds: Double? {
        percentile(0.50, of: entries.compactMap(\.serverOmrSeconds))
    }

    func recordOnDevicePrep(durationMs: Int, pageCount: Int) {
        lastOnDevicePrepMs = max(0, durationMs)
        lastBatchPageCount = max(1, pageCount)
    }

    func recordPageCompletion(
        title: String,
        jobID: String,
        pageNumber: Int,
        totalPages: Int,
        pageWallSeconds: Double,
        serverOmrSeconds: Double?,
        measuresCount: Int,
        fastMode: Bool,
        accessMode: String
    ) {
        // Avoid duplicate entries for the same job ID
        if entries.contains(where: { $0.jobID == jobID && !jobID.isEmpty }) {
            return
        }
        let entry = ScanSLIEntry(
            id: UUID(),
            timestamp: Date(),
            title: title.isEmpty ? "Scan" : title,
            jobID: jobID,
            pageNumber: max(1, pageNumber),
            totalPages: max(1, totalPages, lastBatchPageCount),
            onDevicePrepMs: lastOnDevicePrepMs,
            pageWallSeconds: max(0.05, pageWallSeconds),
            serverOmrSeconds: serverOmrSeconds,
            measuresCount: max(0, measuresCount),
            fastMode: fastMode,
            accessMode: accessMode
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func percentile(_ p: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(round(Double(sorted.count - 1) * p))))
        return sorted[index]
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ScanSLIEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Central configuration for MusicScan services, subscriptions, and Sky design tokens.
///
/// Security notes:
/// - Only public/publishable client values belong in Info.plist or app code.
/// - Never embed Supabase secret keys, Modal access keys for production launch, or Superwall secret keys.
/// - Server entitlements and monthly page limits (1 free page, then 30 pages/month on Pro) are enforced server-side.
enum AppConfig {
    static let serverURLStorageKey = "musicScan.serverAddress"

    /// Default hosted Modal endpoint (no shared access key required when Supabase sign-in is active).
    static let fallbackServerURL = "https://juejue-byte--musicscan.us-east.modal.run"

    /// Public Supabase project URL and publishable key (also discoverable via `/api/config`).
    static let fallbackSupabaseURL = "https://fliegieshsoywgrjyltw.supabase.co"
    static let fallbackSupabasePublishableKey = "sb_publishable_NSgNUem98tSERXluFmypuQ_kQr81wXB"

    /// Custom URL scheme for Supabase email magic links and OAuth callbacks (`musicscan://auth-callback`).
    static let authCallbackScheme = "musicscan"
    static let authCallbackHost = "auth-callback"
    static let authCallbackURLString = "\(authCallbackScheme)://\(authCallbackHost)"

    /// Auto-renewable StoreKit 2 subscription IDs registered in App Store Connect & Superwall.
    enum ProductID {
        static let yearly = "com.allenjue.musicscan.pro.yearly"
        static let monthly = "com.allenjue.musicscan.pro.monthly"
        static let all: [String] = [yearly, monthly]
    }

    static let proPagesPerMonth = 30
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://juejue-byte.github.io/MusicScan/privacy.html")!

    /// Change this asset name (or choose in Settings -> Testing & Scan SLI) to switch the app logo across
    /// all headers, the Welcome flow, and the initial server-connecting launch splash screen:
    /// - `"BrandLogo"` (`icon-512.png`, 512x512 — default crisp 3x Retina square logo)
    /// - `"HeroScan"` (`hero-scan.png`, 1600x900 — wide scanner hero illustration)
    /// - `"FeatureFixIt"` (`feature-fixit.png`, 800x600 — side-by-side Fix It artwork)
    /// - `"EmptyDropzone"` (`empty-dropzone.png`, 800x600 — sheet music dropzone illustration)
    /// - `"vector"` (procedural Sky viewfinder + music note vector badge)
    static let logoAssetStorageKey = "musicScan.logoAssetName"
    static let defaultLogoAssetName = "BrandLogo"

    /// Server address read from Info.plist (`MusicScanServerURL`), optionally carrying a dev `MusicScanAccessKey`.
    static var defaultServerAddress: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let rawURL = (info["MusicScanServerURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let devKey = (info["MusicScanAccessKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = rawURL.isEmpty ? fallbackServerURL : rawURL
        guard !devKey.isEmpty else { return resolvedURL }
        let base = resolvedURL.hasSuffix("/") ? resolvedURL : resolvedURL + "/"
        return base + "?key=" + devKey
    }

    static var supabaseURL: URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        let raw = (info["SupabaseURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.isEmpty ? fallbackSupabaseURL : raw
        guard candidate.hasPrefix("https://") else { return nil }
        return URL(string: candidate)
    }

    static var supabasePublishableKey: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let raw = (info["SupabasePublishableKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallbackSupabasePublishableKey : raw
    }

    /// Public Superwall SDK key (`pk_...`) from Info.plist (`SuperwallAPIKey`).
    /// Leave empty until the app is registered in App Store Connect and Superwall Dashboard;
    /// when empty, the app automatically falls back to the built-in Sky StoreKit 2 paywall.
    static var superwallAPIKey: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["SuperwallAPIKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isSuperwallConfigured: Bool {
        !superwallAPIKey.isEmpty
    }

    static var superwallUnlockPlacement: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let value = (info["SuperwallUnlockPlacement"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unlock_page" : value
    }

    /// Normalizes user-entered or stored server URLs into a valid HTTP(S) base URL with a trailing slash.
    /// Rejects non-HTTP(S) schemes and strips legacy shared query keys unless explicitly entered by a developer.
    static func normalizedServerURL(from raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }

    /// Builds an API endpoint URL (e.g., `api/health`, `api/billing/transaction`) on `base`, preserving query items if any.
    static func endpoint(base: URL, path: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.path += cleanPath
        return components.url
    }
}

/// MusicScan "Sky" design tokens (`design/sky/tokens.json`).
enum SkyTheme {
    static let sky25 = Color(red: 0.961, green: 0.980, blue: 1.0)       // #F5FAFF
    static let sky50 = Color(red: 0.918, green: 0.957, blue: 0.996)     // #EAF4FE
    static let sky100 = Color(red: 0.847, green: 0.918, blue: 0.988)    // #D8EAFC
    static let sky200 = Color(red: 0.725, green: 0.851, blue: 0.969)    // #B9D9F7
    static let blue600 = Color(red: 0.090, green: 0.412, blue: 0.761)   // #1769C2
    static let blue700 = Color(red: 0.059, green: 0.337, blue: 0.639)   // #0F56A3
    static let navy900 = Color(red: 0.055, green: 0.133, blue: 0.220)   // #0E2238
    static let slate600 = Color(red: 0.306, green: 0.392, blue: 0.486)  // #4E647C
    static let line = Color(red: 0.839, green: 0.894, blue: 0.949)      // #D6E4F2
    static let marigold = Color(red: 0.965, green: 0.725, blue: 0.231)  // #F6B93B
    static let sureInk = Color(red: 0.114, green: 0.478, blue: 0.306)   // #1D7A4E
    static let sureFill = Color(red: 0.886, green: 0.961, blue: 0.918)  // #E2F5EA
}
