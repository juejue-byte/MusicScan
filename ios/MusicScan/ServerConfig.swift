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

    /// Accepts "192.168.1.20:8000", "mac.local:8000" or a full URL; returns nil if it is not a usable web address.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        if !s.hasSuffix("/") { s += "/" }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
