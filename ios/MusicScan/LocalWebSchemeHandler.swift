import Foundation
import WebKit

/// Offline-first `WKURLSchemeHandler` that serves the bundled `web/` editor (`index.html`, `style.css`,
/// `review.css`, `js/*`, `vendor/vexflow.js`, `vendor/sounds/*`, `demo/*`, `samples/*`) instantaneously
/// from `musicscan-app://local/index.html?embed=native` with 0ms latency and $0 Modal wake-up cost,
/// while transparently serving locally cached scan images (`page.png` / `original.jpg`) from `LocalScoreStore`
/// and proxying only live OMR requests (`/api/jobs`, `/api/scan`, `/api/rescan-row`, `/api/health`, `/api/warmup`,
/// `/api/billing/*`) to the configured Modal GPU backend.
final class LocalWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "musicscan-app"
    static let localEditorURL = URL(string: "musicscan-app://MusicScan/index.html?embed=native")!

    private let rootURL: URL
    private let activeTasksLock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    init(bundleSubdir: String = "web.bundle") {
        let resourceRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bundleCandidate = resourceRoot.appendingPathComponent(bundleSubdir, isDirectory: true)
        let plainCandidate = resourceRoot.appendingPathComponent("web", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundleCandidate.appendingPathComponent("index.html").path) {
            self.rootURL = bundleCandidate
        } else if FileManager.default.fileExists(atPath: plainCandidate.appendingPathComponent("index.html").path) {
            self.rootURL = plainCandidate
        } else {
            self.rootURL = resourceRoot
        }
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let taskKey = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasksLock.lock()
        activeTasks.insert(taskKey)
        activeTasksLock.unlock()

        var relPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relPath.isEmpty { relPath = "index.html" }

        // 1. Check if this is an API or job image request
        if relPath.hasPrefix("api/") {
            handleAPIRequest(relPath: relPath, task: urlSchemeTask, taskKey: taskKey)
            return
        }

        // 2. Serve static web bundle asset from disk (`index.html`, `js/*`, `vendor/vexflow.js`, `vendor/sounds/*`, etc.)
        let fileURL = rootURL.appendingPathComponent(relPath).standardizedFileURL
        let fallbackURL = (Bundle.main.resourceURL ?? rootURL).appendingPathComponent(relPath).standardizedFileURL

        let resolvedURL: URL? = if fileURL.path.hasPrefix(rootURL.standardizedFileURL.path),
                                   FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL
        } else if FileManager.default.fileExists(atPath: fallbackURL.path) {
            fallbackURL
        } else {
            nil
        }

        guard let targetURL = resolvedURL,
              let data = try? Data(contentsOf: targetURL) else {
            finishWithError(URLError(.fileDoesNotExist), task: urlSchemeTask, taskKey: taskKey)
            return
        }

        let mime = Self.mimeType(for: targetURL.pathExtension)
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: targetURL.pathExtension.lowercased() == "html" ? "utf-8" : nil
        )
        deliver(response: response, data: data, task: urlSchemeTask, taskKey: taskKey)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskKey = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasksLock.lock()
        activeTasks.remove(taskKey)
        activeTasksLock.unlock()
    }

    // MARK: - Local Cache + Remote Modal OMR Proxy

    private func handleAPIRequest(relPath: String, task: WKURLSchemeTask, taskKey: ObjectIdentifier) {
        guard let reqURL = task.request.url else {
            finishWithError(URLError(.badURL), task: task, taskKey: taskKey)
            return
        }

        // Instant local responses for non-OMR endpoints so launching/browsing never wakes Modal!
        if relPath == "api/samples" {
            let demoIndexURL = rootURL.appendingPathComponent("demo/index.json")
            if let data = try? Data(contentsOf: demoIndexURL),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let samples = obj["samples"] as? [String: String] {
                let names = Array(samples.keys).sorted()
                if let out = try? JSONSerialization.data(withJSONObject: names) {
                    deliverJSON(out, statusCode: 200, url: reqURL, task: task, taskKey: taskKey)
                    return
                }
            }
            deliverJSON(Data("[]".utf8), statusCode: 200, url: reqURL, task: task, taskKey: taskKey)
            return
        }

        if relPath == "api/config" {
            let cfg: [String: Any] = [
                "supabaseUrl": AppConfig.supabaseURL?.absoluteString ?? AppConfig.fallbackSupabaseURL,
                "supabasePublishableKey": AppConfig.supabasePublishableKey,
                "signIn": true,
                "storeKit": true
            ]
            if let out = try? JSONSerialization.data(withJSONObject: cfg) {
                deliverJSON(out, statusCode: 200, url: reqURL, task: task, taskKey: taskKey)
                return
            }
        }

        // Check if this is `api/jobs/<jobID>/page.png` or `api/jobs/<jobID>/original.jpg` already saved in LocalScoreStore
        let parts = relPath.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "api", parts[1] == "jobs" {
            let jobID = parts[2]
            let fileName = parts[3]
            if (fileName == "page.png" || fileName == "original.jpg"),
               let cachedData = Self.findCachedJobImage(jobID: jobID, fileName: fileName) {
                let mime = fileName.hasSuffix(".png") ? "image/png" : "image/jpeg"
                let resp = HTTPURLResponse(
                    url: reqURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime,
                        "Content-Length": "\(cachedData.count)",
                        "Access-Control-Allow-Origin": "*"
                    ]
                )!
                deliver(response: resp, data: cachedData, task: task, taskKey: taskKey)
                return
            }
        }

        // Proxy OMR requests (`POST /api/jobs`, `GET /api/jobs/<id>`, `POST /api/jobs/<id>/rescan`, `POST /api/jobs/<id>/reread`, `/api/warmup`) to Modal
        let originalRequest = task.request
        let method = originalRequest.httpMethod ?? "GET"
        let headers = originalRequest.allHTTPHeaderFields ?? [:]
        let bodyData = originalRequest.httpBody ?? Self.readBodyStream(originalRequest.httpBodyStream)
        let query = reqURL.query

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let rawAddress = UserDefaults.standard.string(forKey: AppConfig.serverURLStorageKey) ?? AppConfig.defaultServerAddress
            guard let baseURL = ServerConfig.normalizedURL(from: rawAddress),
                  var remoteURL = ServerConfig.endpoint(from: baseURL, path: relPath) else {
                self.finishWithError(URLError(.badServerResponse), task: task, taskKey: taskKey)
                return
            }

            if let query, !query.isEmpty, var comps = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) {
                let existingItems = comps.queryItems ?? []
                let extraItems = (URLComponents(string: "?\(query)")?.queryItems ?? [])
                comps.queryItems = existingItems + extraItems
                if let combined = comps.url { remoteURL = combined }
            }

            var proxyReq = URLRequest(url: remoteURL)
            proxyReq.httpMethod = method
            proxyReq.timeoutInterval = 180
            for (k, v) in headers {
                let lower = k.lowercased()
                if lower == "host" || lower == "origin" || lower == "referer" { continue }
                proxyReq.setValue(v, forHTTPHeaderField: k)
            }
            if proxyReq.value(forHTTPHeaderField: "Authorization") == nil,
               let bearer = await AuthManager.shared.bearerHeader() {
                proxyReq.setValue(bearer, forHTTPHeaderField: "Authorization")
            }
            proxyReq.httpBody = bodyData

            do {
                let (data, response) = try await URLSession.shared.data(for: proxyReq)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                let mime = response.mimeType ?? "application/json"
                let httpResp = HTTPURLResponse(
                    url: reqURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime,
                        "Content-Length": "\(data.count)",
                        "Access-Control-Allow-Origin": "*"
                    ]
                ) ?? response
                self.deliver(response: httpResp, data: data, task: task, taskKey: taskKey)
            } catch {
                self.finishWithError(error, task: task, taskKey: taskKey)
            }
        }
    }

    private nonisolated static func findCachedJobImage(jobID: String, fileName: String) -> Data? {
        let root = LocalScoreStore.scoresRootDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let targetName = fileName == "page.png" ? "page_\(jobID).png" : "orig_\(jobID).jpg"
        for dir in dirs {
            let candidate = dir.appendingPathComponent(targetName)
            if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                return data
            }
            if fileName == "page.png" {
                let jpgFallback = dir.appendingPathComponent("orig_\(jobID).jpg")
                if let data = try? Data(contentsOf: jpgFallback), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    private nonisolated static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }

    private func deliverJSON(_ data: Data, statusCode: Int, url: URL, task: WKURLSchemeTask, taskKey: ObjectIdentifier) {
        let resp = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        deliver(response: resp, data: data, task: task, taskKey: taskKey)
    }

    private func deliver(response: URLResponse, data: Data, task: WKURLSchemeTask, taskKey: ObjectIdentifier) {
        activeTasksLock.lock()
        let isActive = activeTasks.remove(taskKey) != nil
        activeTasksLock.unlock()
        guard isActive else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func finishWithError(_ error: Error, task: WKURLSchemeTask, taskKey: ObjectIdentifier) {
        activeTasksLock.lock()
        let isActive = activeTasks.remove(taskKey) != nil
        activeTasksLock.unlock()
        guard isActive else { return }
        task.didFailWithError(error)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
