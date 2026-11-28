import Foundation

/// Configuration and health-check helpers for the MusicScan OMR reading server.
enum ServerConfig {
    static let storageKey = AppConfig.serverURLStorageKey

    /// Default hosted Modal GPU server configured via `AppConfig`.
    static var hostedDefaultAddress: String {
        AppConfig.defaultServerAddress
    }

    /// Local development server preset for running `HOST=0.0.0.0 scripts/run.sh` on a Mac.
    static let localPresetAddress = "http://localhost:8000/"

    static func normalizedURL(from address: String) -> URL? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            let looksLocal = value.hasPrefix("localhost")
                || value.hasPrefix("127.")
                || value.hasPrefix("192.168.")
                || value.hasPrefix("10.")
                || value.contains(".local")
            value = (looksLocal ? "http://" : "https://") + value
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

    static func endpoint(from baseURL: URL, path: String) -> URL? {
        AppConfig.endpoint(base: baseURL, path: path)
    }

    static func displayHost(for address: String) -> String {
        guard let url = normalizedURL(from: address), let host = url.host else {
            return "Not configured"
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

struct ServerHealth: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case connected
        case unauthorized
        case unreachable
    }

    let state: State
    let message: String
    let deviceLabel: String?
    let latencyMs: Int?
    let signedIn: Bool

    static func check(address: String) async -> ServerHealth {
        guard let baseURL = ServerConfig.normalizedURL(from: address),
              let healthURL = ServerConfig.endpoint(from: baseURL, path: "api/health") else {
            return ServerHealth(
                state: .unreachable,
                message: "Enter a valid http:// or https:// server address.",
                deviceLabel: nil,
                latencyMs: nil,
                signedIn: false
            )
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 60
        if let bearer = await AuthManager.shared.bearerHeader() {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }

        let startedAt = ContinuousClock.now

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = startedAt.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            guard code == 200, json?["app"] as? String == "musicscan" else {
                return ServerHealth(
                    state: .unreachable,
                    message: code == 404
                        ? "Server answered, but isn't running an up-to-date MusicScan API (HTTP 404)."
                        : "Unexpected server response (HTTP \(code)).",
                    deviceLabel: nil,
                    latencyMs: ms,
                    signedIn: false
                )
            }

            let authorized = json?["authorized"] as? Bool ?? true
            let signedIn = json?["user"] is String
            let rawDevice = (json?["device"] as? String)?.lowercased()
            let deviceLabel: String? = switch rawDevice {
            case "modal-t4": "Modal T4 GPU"
            case "modal-l4": "Modal L4 GPU"
            case "cuda": "CUDA GPU"
            case "mps": "Apple Silicon GPU"
            case "cpu": "CPU"
            default: rawDevice?.uppercased()
            }

            if authorized {
                let message = signedIn
                    ? "Connected, signed in, and ready to read sheet music."
                    : "Connected and ready to read sheet music."
                return ServerHealth(
                    state: .connected,
                    message: message,
                    deviceLabel: deviceLabel,
                    latencyMs: ms,
                    signedIn: signedIn
                )
            } else {
                return ServerHealth(
                    state: .unauthorized,
                    message: "Server reachable, but sign-in or access key was not accepted.",
                    deviceLabel: deviceLabel,
                    latencyMs: ms,
                    signedIn: signedIn
                )
            }
        } catch {
            return ServerHealth(
                state: .unreachable,
                message: error.localizedDescription,
                deviceLabel: nil,
                latencyMs: nil,
                signedIn: false
            )
        }
    }
}
