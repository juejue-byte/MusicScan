import Foundation

/// Where the MusicScan server (scripts/run.sh) runs. OMR stays on the server in v1; the app loads the web
/// editor from the same address, so the app and the server are always the same version.
enum ServerConfig {
    static let storageKey = "serverURL"

    /// Default from Info.plist (`MusicScanServerURL`). The simulator shares the Mac's network, so localhost works there.
    static var defaultURL: String {
        #if targetEnvironment(simulator)
        return "http://localhost:8000"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "MusicScanServerURL") as? String) ?? "http://localhost:8000"
        #endif
    }

    /// Accepts "192.168.1.20:8000", "mac.local:8000" or a full URL, including a hosted one with its access key
    /// ("https://you--musicscan.modal.run/?key=…"); returns nil if it is not a usable web address.
    /// The key stays in the query: the server answers the first page load with a cookie, so the editor's own
    /// requests carry it from then on.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var parts = URLComponents(string: s), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty else { return nil }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        return parts.url
    }

    /// `path` (such as "api/health") on this server, keeping the access key.
    static func endpoint(_ base: URL, _ path: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.path += path
        return parts.url
    }
}
