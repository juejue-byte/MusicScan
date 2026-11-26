import Foundation

/// Where the MusicScan server (scripts/run.sh) runs. OMR stays on the server in v1; the app loads the web
/// editor from the same address, so the app and the server are always the same version.
enum ServerConfig {
    static let storageKey = "serverURL"

    /// Default from Info.plist (`MusicScanServerURL` + `MusicScanAccessKey`, filled from ios/Secrets.xcconfig by
    /// scripts/use_server.sh). With a key set (a hosted server) the simulator uses it too; without one the simulator
    /// uses the Mac's own server at localhost, since it shares the Mac's network.
    /// The key is built into the app: fine for your own test builds, never for an App Store build (sign-in replaces it).
    static var defaultURL: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let url = (info["MusicScanServerURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["MusicScanAccessKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        #if targetEnvironment(simulator)
        if key.isEmpty { return "http://localhost:8000" }
        #endif
        if url.isEmpty { return "http://localhost:8000" }
        if key.isEmpty { return url }
        let base = url.hasSuffix("/") ? url : url + "/"
        return base + "?key=" + key
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
