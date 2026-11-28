import Foundation
import PencilKit
import UIKit
import Observation

/// Normalized rectangle (0...1 coordinates) for bar crops and page overlays.
struct NormalizedCropRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

typealias LocalScoreItem = LocalScoreMeta

/// Per-bar confidence and verification status persisted in `flags.json` inside each score bundle.
struct LocalBarFlag: Codable, Equatable, Sendable {
    var index: Int
    var level: String        // "ok" | "check" | "bad"
    var reviewed: Bool?
    var flag: String?
    var low_n: Int?
    var disagree: Bool?
    var filled: Bool?
    var notes: [String]?
    var fixes: [String]?
    var bbox: [Double]?      // [x0, y0, x1, y1] in page image coordinates
    var low: [[Double]]?
    var system: Int?
    var page: String?
}

/// Per-page metadata persisted inside `meta.json` so multi-page scores and offline Fix-It crops work seamlessly.
struct LocalPageDescriptor: Codable, Equatable, Sendable {
    var job: String
    var name: String
    var pageSize: [Int]?
    var originalSize: [Int]?
    var quad: [[Double]]?
    var qualityScore: Int?
    var qualityLevel: String?
    var qualityReasons: [String]?
}

/// Canonical on-device score metadata (`Application Support/MusicScan/Scores/<scoreID>/meta.json`).
struct LocalScoreMeta: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    var barCount: Int
    var flaggedCount: Int
    var redCount: Int
    var tempoBPM: Int
    var primaryJobID: String?
    var pages: [String: LocalPageDescriptor]

    var isReadyToPlay: Bool {
        flaggedCount == 0
    }

    var cleanTitle: String {
        LocalScoreStore.humanizeTitle(title)
    }

    var barsCount: Int {
        barCount
    }

    var flaggedBarsCount: Int {
        flaggedCount
    }

    var statusLabel: String {
        statusText
    }

    static func humanizeTitle(_ raw: String) -> String {
        LocalScoreStore.humanizeTitle(raw)
    }

    var statusText: String {
        if flaggedCount <= 0 {
            return "Ready to play"
        }
        return flaggedCount == 1 ? "1 bar to check" : "\(flaggedCount) bars to check"
    }
}

/// On-device score store (`Application Support/MusicScan/Scores/<scoreID>/`).
///
/// Persists:
/// - `meta.json` — `id`, `title`, `createdAt`, `updatedAt`, `pageCount`, `barCount`, `flaggedCount`, `tempoBPM`
/// - `score.musicxml` — canonical MusicXML (mutated locally on every edit/fix)
/// - `flags.json` — per-bar confidence & verified status
/// - `page_1.jpg`, `page_2.jpg`, ... (and `page_<jobID>.png` / `orig_<jobID>.jpg`) — flattened original scans for instant offline Fix-It comparison
/// - `thumb.jpg` — fast 400px thumbnail for `ScoreLibraryView`
/// - `ink.pkdrawing` — native `PencilKit` `PKDrawing.dataRepresentation()`
///
/// All Library reads, renames, deletes, exports, and editor opens read directly from `LocalScoreStore` with zero network calls.
@MainActor
@Observable
final class LocalScoreStore {
    static let shared = LocalScoreStore()

    private(set) var scores: [LocalScoreMeta] = []
    private(set) var activeScoreID: String?

    nonisolated static var scoresRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("MusicScan", isDirectory: true)
            .appendingPathComponent("Scores", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func directory(for scoreID: String) -> URL {
        let safeID = scoreID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return scoresRootDirectory.appendingPathComponent(safeID, isDirectory: true)
    }

    private init() {
        reloadAll()
    }

    func reloadAll() {
        let root = Self.scoresRootDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            scores = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [LocalScoreMeta] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(LocalScoreMeta.self, from: data) else {
                continue
            }
            loaded.append(meta)
        }
        loaded.sort { $0.updatedAt > $1.updatedAt }
        scores = loaded
        if activeScoreID == nil {
            activeScoreID = scores.first?.id
        }
    }

    func meta(for scoreID: String) -> LocalScoreMeta? {
        scores.first(where: { $0.id == scoreID })
    }

    func loadMusicXML(for scoreID: String) -> String? {
        let url = Self.directory(for: scoreID).appendingPathComponent("score.musicxml")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func loadFlagsJSON(for scoreID: String) -> String {
        let url = Self.directory(for: scoreID).appendingPathComponent("flags.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "[]"
    }

    func loadMetaJSON(for scoreID: String) -> String? {
        let url = Self.directory(for: scoreID).appendingPathComponent("flags.json")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func loadPagesJSON(for scoreID: String) -> String? {
        let url = Self.directory(for: scoreID).appendingPathComponent("pages.json")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func loadInkDrawing(for scoreID: String) -> PKDrawing {
        loadDrawing(for: scoreID)
    }

    func saveInkDrawing(_ drawing: PKDrawing, for scoreID: String) {
        saveDrawing(drawing, for: scoreID)
    }

    func loadFlags(for scoreID: String) -> [LocalBarFlag] {
        let url = Self.directory(for: scoreID).appendingPathComponent("flags.json")
        guard let data = try? Data(contentsOf: url),
              let flags = try? JSONDecoder().decode([LocalBarFlag].self, from: data) else {
            return []
        }
        return flags
    }

    func loadDrawing(for scoreID: String) -> PKDrawing {
        let url = Self.directory(for: scoreID).appendingPathComponent("ink.pkdrawing")
        guard let data = try? Data(contentsOf: url),
              let drawing = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        return drawing
    }

    func saveDrawing(_ drawing: PKDrawing, for scoreID: String) {
        let dir = Self.directory(for: scoreID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ink.pkdrawing")
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    func thumbnailImage(for scoreID: String, jobID: String? = nil) -> UIImage? {
        let dir = Self.directory(for: scoreID)
        let thumbURL = dir.appendingPathComponent("thumb.jpg")
        if let img = UIImage(contentsOfFile: thumbURL.path) {
            return img
        }
        if let jobID, !jobID.isEmpty {
            let jobPNG = dir.appendingPathComponent("page_\(jobID).png")
            if let img = UIImage(contentsOfFile: jobPNG.path) { return img }
            let jobJPG = dir.appendingPathComponent("orig_\(jobID).jpg")
            if let img = UIImage(contentsOfFile: jobJPG.path) { return img }
        }
        let page1URL = dir.appendingPathComponent("page_1.jpg")
        return UIImage(contentsOfFile: page1URL.path)
    }

    func pageImage(for scoreID: String, pageIndex: Int = 0, jobID: String? = nil) -> UIImage? {
        let dir = Self.directory(for: scoreID)
        if let jobID, !jobID.isEmpty {
            let jobPNG = dir.appendingPathComponent("page_\(jobID).png")
            if let img = UIImage(contentsOfFile: jobPNG.path) { return img }
            let jobJPG = dir.appendingPathComponent("orig_\(jobID).jpg")
            if let img = UIImage(contentsOfFile: jobJPG.path) { return img }
        }
        let idx = max(1, pageIndex + 1)
        let pageJPG = dir.appendingPathComponent("page_\(idx).jpg")
        if let img = UIImage(contentsOfFile: pageJPG.path) { return img }
        let page1JPG = dir.appendingPathComponent("page_1.jpg")
        return UIImage(contentsOfFile: page1JPG.path)
    }

    /// Crops the active bar from the stored page image using normalized `NormalizedCropRect` (0...1 coordinates).
    func croppedBarImage(
        for scoreID: String,
        pageIndex: Int = 0,
        jobID: String? = nil,
        cropRect: NormalizedCropRect?
    ) -> UIImage? {
        guard let fullImage = pageImage(for: scoreID, pageIndex: pageIndex, jobID: jobID),
              let cgImage = fullImage.cgImage,
              let cropRect,
              cropRect.width > 0.01,
              cropRect.height > 0.01 else {
            return nil
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let x0 = max(0, min(imgW - 1, CGFloat(cropRect.x) * imgW))
        let y0 = max(0, min(imgH - 1, CGFloat(cropRect.y) * imgH))
        let w = max(8, min(imgW - x0, CGFloat(cropRect.width) * imgW))
        let h = max(8, min(imgH - y0, CGFloat(cropRect.height) * imgH))

        let rect = CGRect(x: x0, y: y0, width: w, height: h).integral
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: fullImage.scale, orientation: fullImage.imageOrientation)
    }

    func upsertFromWebEditor(
        id: String,
        title: String,
        musicXML: String,
        metaJSONString: String,
        pagesJSONString: String,
        primaryJobID: String?,
        pageJobIDs: [String],
        barsCount: Int,
        partsCount: Int,
        tempoBPM: Int
    ) {
        let dir = Self.directory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !pagesJSONString.isEmpty {
            let pagesURL = dir.appendingPathComponent("pages.json")
            try? pagesJSONString.write(to: pagesURL, atomically: true, encoding: .utf8)
        }
        upsertScoreFromWeb(
            id: id,
            rawTitle: title,
            xml: musicXML,
            rawMetaJSON: metaJSONString,
            rawPagesJSON: pagesJSONString,
            primaryJobID: primaryJobID,
            barCount: barsCount,
            tempoBPM: tempoBPM
        )
    }

    func cacheRemoteJobImagesIfNeeded(
        scoreID: String,
        jobIDs: [String],
        serverBaseURL: URL?
    ) async {
        await Self.cachePageImagesIfNeeded(scoreID: scoreID, jobIDs: jobIDs)
    }

    /// Upserts a score from the WebView (`library.js` sync or scan completion) into `Application Support/MusicScan/Scores/<scoreID>/`.
    func upsertScoreFromWeb(
        id: String,
        rawTitle: String,
        xml: String,
        rawMetaJSON: String?,
        rawPagesJSON: String?,
        primaryJobID: String?,
        barCount: Int,
        tempoBPM: Int = 96
    ) {
        guard !id.isEmpty, !xml.isEmpty else { return }
        let dir = Self.directory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cleanTitle = Self.humanizeTitle(rawTitle)
        let now = Date()
        let existing = meta(for: id)

        // Write canonical MusicXML
        let xmlURL = dir.appendingPathComponent("score.musicxml")
        try? xml.write(to: xmlURL, atomically: true, encoding: .utf8)

        // Parse & write flags.json
        var flaggedCount = existing?.flaggedCount ?? 0
        var redCount = existing?.redCount ?? 0
        if let rawMetaJSON, !rawMetaJSON.isEmpty, let metaData = rawMetaJSON.data(using: .utf8) {
            let flagsURL = dir.appendingPathComponent("flags.json")
            try? metaData.write(to: flagsURL, options: .atomic)
            if let arr = (try? JSONSerialization.jsonObject(with: metaData)) as? [[String: Any]] {
                var openFlags = 0
                var openRed = 0
                for item in arr {
                    let reviewed = (item["reviewed"] as? Bool) ?? false
                    let level = (item["level"] as? String) ?? "ok"
                    if !reviewed && (level == "bad" || level == "check") {
                        openFlags += 1
                        if level == "bad" { openRed += 1 }
                    }
                }
                flaggedCount = openFlags
                redCount = openRed
            }
        }

        // Parse pages map
        var pagesMap: [String: LocalPageDescriptor] = existing?.pages ?? [:]
        if let rawPagesJSON, !rawPagesJSON.isEmpty,
           let pagesData = rawPagesJSON.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: pagesData)) as? [String: [String: Any]] {
            for (jobKey, pageObj) in dict {
                let pageName = (pageObj["name"] as? String) ?? ""
                let pageSize = pageObj["page_size"] as? [Int]
                let origSize = pageObj["original_size"] as? [Int]
                let quad = pageObj["quad"] as? [[Double]]
                let q = pageObj["quality"] as? [String: Any]
                pagesMap[jobKey] = LocalPageDescriptor(
                    job: jobKey,
                    name: pageName,
                    pageSize: pageSize,
                    originalSize: origSize,
                    quad: quad,
                    qualityScore: q?["score"] as? Int,
                    qualityLevel: q?["level"] as? String,
                    qualityReasons: q?["reasons"] as? [String]
                )
            }
        }

        let resolvedPageCount = max(1, pagesMap.count)
        let updatedMeta = LocalScoreMeta(
            id: id,
            title: cleanTitle,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            pageCount: resolvedPageCount,
            barCount: max(barCount, existing?.barCount ?? 0),
            flaggedCount: flaggedCount,
            redCount: redCount,
            tempoBPM: tempoBPM > 0 ? tempoBPM : (existing?.tempoBPM ?? 96),
            primaryJobID: primaryJobID ?? existing?.primaryJobID,
            pages: pagesMap
        )

        writeMeta(updatedMeta)
        activeScoreID = id

        // Download & cache page images for offline Fix-It comparison if not yet cached on disk
        let jobsToCache = Set(([primaryJobID].compactMap { $0 }) + Array(pagesMap.keys))
        if !jobsToCache.isEmpty {
            Task.detached(priority: .utility) {
                await Self.cachePageImagesIfNeeded(scoreID: id, jobIDs: Array(jobsToCache))
            }
        }
    }

    func saveXML(_ xml: String, for scoreID: String) {
        guard !scoreID.isEmpty, !xml.isEmpty else { return }
        let dir = Self.directory(for: scoreID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xmlURL = dir.appendingPathComponent("score.musicxml")
        try? xml.write(to: xmlURL, atomically: true, encoding: .utf8)

        if var current = meta(for: scoreID) {
            current.updatedAt = Date()
            writeMeta(current)
        }
    }

    func updateFlagsCount(for scoreID: String, remaining: Int, redRemaining: Int? = nil) {
        guard var current = meta(for: scoreID) else { return }
        current.flaggedCount = max(0, remaining)
        if let redRemaining {
            current.redCount = max(0, redRemaining)
        }
        current.updatedAt = Date()
        writeMeta(current)
    }

    func renameScore(id: String, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var current = meta(for: id) else { return }
        current.title = trimmed
        current.updatedAt = Date()
        writeMeta(current)
    }

    func deleteScore(id: String) {
        let dir = Self.directory(for: id)
        try? FileManager.default.removeItem(at: dir)
        scores.removeAll { $0.id == id }
        if activeScoreID == id {
            activeScoreID = scores.first?.id
        }
    }

    private func writeMeta(_ meta: LocalScoreMeta) {
        let dir = Self.directory(for: meta.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        if let idx = scores.firstIndex(where: { $0.id == meta.id }) {
            scores[idx] = meta
        } else {
            scores.insert(meta, at: 0)
        }
        scores.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Saves a pre-scanned local JPEG directly into the score directory and generates a 400px `thumb.jpg`.
    nonisolated static func storeLocalScanPageImage(
        jpegData: Data,
        scoreID: String,
        pageNumber: Int = 1,
        jobID: String? = nil
    ) {
        let dir = directory(for: scoreID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pageURL = dir.appendingPathComponent("page_\(max(1, pageNumber)).jpg")
        try? jpegData.write(to: pageURL, options: .atomic)
        if let jobID, !jobID.isEmpty {
            try? jpegData.write(to: dir.appendingPathComponent("orig_\(jobID).jpg"), options: .atomic)
        }
        if pageNumber == 1 {
            writeThumbnail(from: jpegData, to: dir.appendingPathComponent("thumb.jpg"))
        }
    }

    nonisolated private static func writeThumbnail(from imageData: Data, to thumbURL: URL) {
        guard let image = UIImage(data: imageData) else { return }
        let maxEdge: CGFloat = 400
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(1.0, maxEdge / max(size.width, size.height))
        let targetSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        if let jpg = rendered.jpegData(compressionQuality: 0.80) {
            try? jpg.write(to: thumbURL, options: .atomic)
        }
    }

    nonisolated private static func cachePageImagesIfNeeded(scoreID: String, jobIDs: [String]) async {
        let dir = directory(for: scoreID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rawAddress = UserDefaults.standard.string(forKey: AppConfig.serverURLStorageKey) ?? AppConfig.defaultServerAddress
        guard let baseURL = ServerConfig.normalizedURL(from: rawAddress) else { return }
        let bearer = await AuthManager.shared.bearerHeader()

        for (index, jobID) in jobIDs.enumerated() where !jobID.isEmpty {
            let pngDest = dir.appendingPathComponent("page_\(jobID).png")
            let origDest = dir.appendingPathComponent("orig_\(jobID).jpg")
            let pageNumDest = dir.appendingPathComponent("page_\(index + 1).jpg")
            let thumbDest = dir.appendingPathComponent("thumb.jpg")

            if !FileManager.default.fileExists(atPath: pngDest.path),
               let remoteURL = ServerConfig.endpoint(from: baseURL, path: "api/jobs/\(jobID)/page.png") {
                var req = URLRequest(url: remoteURL)
                req.timeoutInterval = 30
                if let bearer { req.setValue(bearer, forHTTPHeaderField: "Authorization") }
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   !data.isEmpty {
                    try? data.write(to: pngDest, options: .atomic)
                    if !FileManager.default.fileExists(atPath: pageNumDest.path) {
                        try? data.write(to: pageNumDest, options: .atomic)
                    }
                    if index == 0 && !FileManager.default.fileExists(atPath: thumbDest.path) {
                        writeThumbnail(from: data, to: thumbDest)
                    }
                }
            }

            if !FileManager.default.fileExists(atPath: origDest.path),
               let remoteOrig = ServerConfig.endpoint(from: baseURL, path: "api/jobs/\(jobID)/original.jpg") {
                var req = URLRequest(url: remoteOrig)
                req.timeoutInterval = 30
                if let bearer { req.setValue(bearer, forHTTPHeaderField: "Authorization") }
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   !data.isEmpty {
                    try? data.write(to: origDest, options: .atomic)
                    if !FileManager.default.fileExists(atPath: pageNumDest.path) {
                        try? data.write(to: pageNumDest, options: .atomic)
                    }
                    if index == 0 && !FileManager.default.fileExists(atPath: thumbDest.path) {
                        writeThumbnail(from: data, to: thumbDest)
                    }
                }
            }
        }
    }

    nonisolated static func humanizeTitle(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\\.(jpe?g|png|heic|heif|pdf|musicxml|xml|mxl|tiff?|webp)$", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "^\\d+_", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Match "Scan YYYY-MM-DDTHH-MM-SS"
        let pattern = "^Scan\\s+(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2})[-:](\\d{2})(?:[-:](\\d{2}))?$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
           let monRange = Range(match.range(at: 2), in: stripped),
           let dayRange = Range(match.range(at: 3), in: stripped),
           let mon = Int(stripped[monRange]),
           let day = Int(stripped[dayRange]) {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let mName = months[max(0, min(11, mon - 1))]
            return "Scan · \(mName) \(day)"
        }
        return stripped.isEmpty ? "Untitled Score" : stripped
    }
}
