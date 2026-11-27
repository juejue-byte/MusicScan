#if os(iOS)
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import SwiftUI
import UIKit
import Vision

/// Best-of-both-worlds sheet-music scanner:
/// - Smooth 60 fps `AVCaptureSession` viewfinder with live Vision (`VNDetectDocumentSegmentationRequest`)
///   blue page-edge overlay.
/// - **100% manual shutter** — never auto-snaps.
/// - Automatic `CIPerspectiveCorrection` crop & flattening on capture, with a 1-tap Original/Cropped toggle,
///   90° rotate, and delete in the multi-page thumbnail tray.
final class ManualDocumentScannerViewController: UIViewController {
    var onFinish: (([UIImage]) -> Void)?
    var onCancel: (() -> Void)?
    var onChoosePhotosFallback: (() -> Void)?

    private let model = ManualScannerModel()
    private var hostingController: UIHostingController<ManualScannerRootView>?

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let rootView = ManualScannerRootView(
            model: model,
            onCancel: { [weak self] in
                self?.model.stop()
                self?.dismiss(animated: true) {
                    self?.onCancel?()
                }
            },
            onDone: { [weak self] images in
                self?.model.stop()
                self?.dismiss(animated: true) {
                    self?.onFinish?(images)
                }
            },
            onChoosePhotos: { [weak self] in
                self?.model.stop()
                self?.dismiss(animated: true) {
                    self?.onChoosePhotosFallback?()
                }
            }
        )

        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .black
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.startIfAuthorized()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.stop()
    }
}

// MARK: - Normalized Quad & Vision Processor

private struct DetectedQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Points in clockwise order around the quadrilateral.
    var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// Approximate area via shoelace formula (in normalized or view space).
    var area: CGFloat {
        let pts = points
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = pts[i]
            let b = pts[(i + 1) % 4]
            sum += (a.x * b.y - b.x * a.y)
        }
        return abs(sum) * 0.5
    }

    /// Interpolates smoothly toward `target` for jitter-free live overlay tracking.
    func blended(toward target: DetectedQuad, alpha: CGFloat) -> DetectedQuad {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
        }
        // Snap immediately on large jumps (e.g. turning the page or rotating iPad)
        let maxJump = zip(points, target.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        if maxJump > 180 { return target }
        return DetectedQuad(
            topLeft: lerp(topLeft, target.topLeft),
            topRight: lerp(topRight, target.topRight),
            bottomRight: lerp(bottomRight, target.bottomRight),
            bottomLeft: lerp(bottomLeft, target.bottomLeft)
        )
    }

    /// Reorders the 4 corners into canonical visual `[topLeft, topRight, bottomRight, bottomLeft]` order
    /// in Vision's bottom-left-origin coordinate space (`x` left→right, `y` bottom→top).
    /// Prevents `VNDetectDocumentSegmentationRequest` from permuting corners and rotating portrait pages 90° sideways.
    func orderedVisuallyInVisionSpace() -> DetectedQuad {
        let pts = points
        guard pts.count == 4 else { return self }
        // In bottom-left-origin space:
        // - topLeft: small x, large y  => min(x - y)
        // - bottomRight: large x, small y => max(x - y)
        // - topRight: large x, large y => max(x + y)
        // - bottomLeft: small x, small y => min(x + y)
        let tl = pts.min(by: { ($0.x - $0.y) < ($1.x - $1.y) }) ?? topLeft
        let br = pts.max(by: { ($0.x - $0.y) < ($1.x - $1.y) }) ?? bottomRight
        let tr = pts.max(by: { ($0.x + $0.y) < ($1.x + $1.y) }) ?? topRight
        let bl = pts.min(by: { ($0.x + $0.y) < ($1.x + $1.y) }) ?? bottomLeft
        return DetectedQuad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }
}

/// Performs live document edge detection on throttled video frames and full-res perspective flattening on stills.
private final class VisionDocumentProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let stateLock = NSLock()
    private var isProcessingFrame = false
    private var lastFrameTimestamp: CFTimeInterval = 0
    private let minFrameInterval: CFTimeInterval = 0.09 // ~11 Hz Vision tracking while camera stays 60 fps

    /// Delivers detected quad in **AVCaptureDevice normalized coordinates** (top-left origin, `[0, 1]`).
    var onLiveQuadDetected: (@Sendable (DetectedQuad?) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        if isProcessingFrame || (now - lastFrameTimestamp) < minFrameInterval {
            stateLock.unlock()
            return
        }
        isProcessingFrame = true
        lastFrameTimestamp = now
        stateLock.unlock()

        defer {
            stateLock.lock()
            isProcessingFrame = false
            stateLock.unlock()
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            if let obs = request.results?.first, obs.confidence >= 0.45 {
                let deviceQuad = Self.visionToCaptureDeviceQuad(obs)
                if deviceQuad.area >= 0.08 {
                    onLiveQuadDetected?(deviceQuad)
                    return
                }
            }
            onLiveQuadDetected?(nil)
        } catch {
            onLiveQuadDetected?(nil)
        }
    }

    /// Runs high-accuracy document segmentation + `CIPerspectiveCorrection` on an upright `UIImage`.
    /// Returns `nil` when no confident document boundary is found (or when the page already fills the entire frame).
    func autoCropAndFlatten(_ uprightImage: UIImage) -> UIImage? {
        guard let cgImage = uprightImage.cgImage else { return nil }

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let obs = request.results?.first, obs.confidence >= 0.45 else { return nil }
        let visionQuad = DetectedQuad(
            topLeft: obs.topLeft,
            topRight: obs.topRight,
            bottomRight: obs.bottomRight,
            bottomLeft: obs.bottomLeft
        ).orderedVisuallyInVisionSpace()
        let area = visionQuad.area
        guard area >= 0.12 && area <= 0.975 else { return nil }

        // Expand slightly (~1.2%) so outer barlines and margin clefs are never clipped.
        let padded = Self.padQuad(visionQuad, fraction: 0.012)

        let ciInput = CIImage(cgImage: cgImage)
        let extent = ciInput.extent
        func toCIPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: extent.origin.x + p.x * extent.width,
                y: extent.origin.y + p.y * extent.height
            )
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciInput
        filter.topLeft = toCIPoint(padded.topLeft)
        filter.topRight = toCIPoint(padded.topRight)
        filter.bottomRight = toCIPoint(padded.bottomRight)
        filter.bottomLeft = toCIPoint(padded.bottomLeft)

        guard let output = filter.outputImage,
              output.extent.width >= 200,
              output.extent.height >= 200,
              let outCG = ciContext.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: outCG, scale: 1, orientation: .up)
    }

    /// Vision uses bottom-left `(0,0)`; `AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)`
    /// uses top-left `(0,0)` in raw sensor space. Flipping `y -> 1 - y` maps Vision directly to captureDevice space.
    private static func visionToCaptureDeviceQuad(_ obs: VNRectangleObservation) -> DetectedQuad {
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1.0 - p.y) }
        return DetectedQuad(
            topLeft: flip(obs.topLeft),
            topRight: flip(obs.topRight),
            bottomRight: flip(obs.bottomRight),
            bottomLeft: flip(obs.bottomLeft)
        )
    }

    private static func padQuad(_ quad: DetectedQuad, fraction: CGFloat) -> DetectedQuad {
        let cx = (quad.topLeft.x + quad.topRight.x + quad.bottomRight.x + quad.bottomLeft.x) / 4
        let cy = (quad.topLeft.y + quad.topRight.y + quad.bottomRight.y + quad.bottomLeft.y) / 4
        func push(_ p: CGPoint) -> CGPoint {
            let nx = cx + (p.x - cx) * (1 + fraction)
            let ny = cy + (p.y - cy) * (1 + fraction)
            return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
        }
        return DetectedQuad(
            topLeft: push(quad.topLeft),
            topRight: push(quad.topRight),
            bottomRight: push(quad.bottomRight),
            bottomLeft: push(quad.bottomLeft)
        )
    }
}

// MARK: - Camera Engine

@MainActor
@Observable
private final class ManualScannerModel: NSObject {
    enum AuthState: Equatable {
        case checking
        case authorized
        case denied
        case unavailable
    }

    struct CapturedPage: Identifiable {
        let id = UUID()
        var originalImage: UIImage
        var croppedImage: UIImage?
        var useCropped: Bool

        var activeImage: UIImage {
            if useCropped, let croppedImage { return croppedImage }
            return originalImage
        }

        var hasCropOption: Bool { croppedImage != nil }
    }

    var authState: AuthState = .checking
    var pages: [CapturedPage] = []
    var flashMode: AVCaptureDevice.FlashMode = .off
    var hasFlash: Bool = false
    var autoCropEnabled: Bool = true
    var saveToPhotos: Bool = {
        let key = "musicscan.scanner.saveToPhotos"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }()
    var isCapturing: Bool = false
    var showShutterFlash: Bool = false
    var focusIndicatorPoint: CGPoint?
    var statusToast: String?
    var inspectingPageID: UUID?
    /// Smoothed quadrilateral in preview-view coordinates for the live blue page-edge overlay.
    var liveOverlayQuad: DetectedQuad?

    fileprivate let session = AVCaptureSession()
    fileprivate weak var previewLayer: AVCaptureVideoPreviewLayer?
    fileprivate weak var previewHostView: UIView?

    private let sessionQueue = DispatchQueue(label: "com.allenjue.musicscan.camera.session", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.allenjue.musicscan.camera.vision", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let visionProcessor = VisionDocumentProcessor()

    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false
    private var isRunning = false
    private var rotationCoordinator: AnyObject?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?
    private var currentCaptureRotationAngle: CGFloat = 90
    private var activePhotoDelegate: PhotoCaptureDelegateProxy?
    private var lastQuadSeenAt: CFTimeInterval = 0

    override init() {
        super.init()
        visionProcessor.onLiveQuadDetected = { [weak self] deviceQuad in
            Task { @MainActor [weak self] in
                self?.handleLiveDeviceQuad(deviceQuad)
            }
        }
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer, hostView: UIView? = nil) {
        previewLayer = layer
        if let hostView { previewHostView = hostView }
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        updateRotationCoordinator()
    }

    func startIfAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .authorized
            configureAndStart()
        case .notDetermined:
            authState = .checking
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.authState = .authorized
                        self.configureAndStart()
                    } else {
                        self.authState = .denied
                    }
                }
            }
        case .denied, .restricted:
            authState = .denied
        @unknown default:
            authState = .denied
        }
    }

    func stop() {
        previewAngleObservation?.invalidate()
        previewAngleObservation = nil
        captureAngleObservation?.invalidate()
        captureAngleObservation = nil
        liveOverlayQuad = nil
        guard isRunning else { return }
        isRunning = false
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func cycleFlashMode() {
        guard hasFlash else { return }
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        case .on: flashMode = .off
        @unknown default: flashMode = .off
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleAutoCrop() {
        autoCropEnabled.toggle()
        if !autoCropEnabled {
            liveOverlayQuad = nil
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleSaveToPhotos() {
        saveToPhotos.toggle()
        UserDefaults.standard.set(saveToPhotos, forKey: "musicscan.scanner.saveToPhotos")
        showBriefToast(saveToPhotos ? "Scanned pages will save to Photos" : "Save to Photos turned off")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func savePageToPhotos(id: UUID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        let image = page.activeImage
        Task { @MainActor in
            let ok = await Self.saveImagesToPhotoLibrary([image])
            self.showBriefToast(ok ? "Saved page to Photos" : "Allow Photos access in Settings to save")
        }
    }

    func savePagesToPhotosIfEnabled() {
        guard saveToPhotos, !pages.isEmpty else { return }
        let images = pages.map(\.activeImage)
        Task.detached(priority: .utility) {
            _ = await Self.saveImagesToPhotoLibrary(images)
        }
    }

    private nonisolated static func saveImagesToPhotoLibrary(_ images: [UIImage]) async -> Bool {
        guard !images.isEmpty else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let jpegs = images.compactMap { $0.jpegData(compressionQuality: 0.92) }
        guard !jpegs.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                for data in jpegs {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: data, options: nil)
                }
            }) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    func focus(at devicePoint: CGPoint, viewPoint: CGPoint) {
        focusIndicatorPoint = viewPoint
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            if self?.focusIndicatorPoint == viewPoint {
                self?.focusIndicatorPoint = nil
            }
        }
        guard let device = videoDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func capturePhoto() {
        guard !isCapturing, authState == .authorized else { return }
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.easeOut(duration: 0.08)) {
            showShutterFlash = true
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.18)) {
                self?.showShutterFlash = false
            }
        }

        let desiredFlash = hasFlash ? flashMode : .off
        // Compute capture rotation live from the hosting UIWindowScene interface orientation so iPhone
        // and iPad (including Split View / Stage Manager) scans never inherit a stale 0° angle or
        // downward-tilt gravity glitch.
        let captureAngle = interfaceRotationAngle()
        currentCaptureRotationAngle = captureAngle
        let output = photoOutput
        let shouldAutoCrop = autoCropEnabled
        let processor = visionProcessor

        let proxy = PhotoCaptureDelegateProxy { [weak self] rawImage in
            Task.detached(priority: .userInitiated) {
                let processed: (UIImage, UIImage?)? = rawImage.map { image in
                    let base = image.normalizedUpOrientation()
                    let upright = SheetMusicOrientationNormalizer.normalize(base, maxLongSide: 2600)
                    let cropped = shouldAutoCrop
                        ? processor.autoCropAndFlatten(upright).map {
                            SheetMusicOrientationNormalizer.normalize($0, maxLongSide: 2200)
                        }
                        : nil
                    return (upright, cropped)
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isCapturing = false
                    self.activePhotoDelegate = nil
                    guard let (upright, cropped) = processed else {
                        self.showBriefToast("Couldn't capture photo — please try again.")
                        return
                    }
                    let page = CapturedPage(
                        originalImage: upright,
                        croppedImage: cropped,
                        useCropped: cropped != nil
                    )
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        self.pages.append(page)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
        activePhotoDelegate = proxy

        sessionQueue.async {
            if let connection = output.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(captureAngle) {
                        connection.videoRotationAngle = captureAngle
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = Self.legacyOrientation(forAngle: captureAngle)
                }
            }
            let settings = AVCapturePhotoSettings()
            if output.supportedFlashModes.contains(desiredFlash) {
                settings.flashMode = desiredFlash
            }
            output.capturePhoto(with: settings, delegate: proxy)
        }
    }

    func rotatePage(id: UUID) {
        guard let idx = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[idx].originalImage = pages[idx].originalImage.rotatedClockwise90()
        if let cropped = pages[idx].croppedImage {
            pages[idx].croppedImage = cropped.rotatedClockwise90()
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func togglePageCrop(id: UUID) {
        guard let idx = pages.firstIndex(where: { $0.id == id }),
              pages[idx].hasCropOption else { return }
        pages[idx].useCropped.toggle()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func deletePage(id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            pages.removeAll { $0.id == id }
            if inspectingPageID == id {
                inspectingPageID = nil
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func handleLiveDeviceQuad(_ deviceQuad: DetectedQuad?) {
        guard autoCropEnabled, inspectingPageID == nil, let previewLayer else {
            if liveOverlayQuad != nil { liveOverlayQuad = nil }
            return
        }
        let now = CACurrentMediaTime()
        guard let deviceQuad else {
            // Brief grace window so the blue outline doesn't flicker between frames
            if liveOverlayQuad != nil && (now - lastQuadSeenAt) > 0.35 {
                withAnimation(.easeOut(duration: 0.18)) {
                    liveOverlayQuad = nil
                }
            }
            return
        }

        lastQuadSeenAt = now
        let layerQuad = DetectedQuad(
            topLeft: previewLayer.layerPointConverted(fromCaptureDevicePoint: deviceQuad.topLeft),
            topRight: previewLayer.layerPointConverted(fromCaptureDevicePoint: deviceQuad.topRight),
            bottomRight: previewLayer.layerPointConverted(fromCaptureDevicePoint: deviceQuad.bottomRight),
            bottomLeft: previewLayer.layerPointConverted(fromCaptureDevicePoint: deviceQuad.bottomLeft)
        )

        if let existing = liveOverlayQuad {
            liveOverlayQuad = existing.blended(toward: layerQuad, alpha: 0.36)
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                liveOverlayQuad = layerQuad
            }
        }
    }

    private func showBriefToast(_ message: String) {
        statusToast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.statusToast == message {
                self?.statusToast = nil
            }
        }
    }

    private func configureAndStart() {
        let captureSession = session
        let photoOut = photoOutput
        let videoOut = videoDataOutput
        let processor = visionProcessor
        let vQueue = visionQueue
        let alreadyConfigured = isConfigured

        sessionQueue.async { [weak self] in
            if !alreadyConfigured {
                captureSession.beginConfiguration()
                captureSession.sessionPreset = .photo

                guard let camera = Self.bestBackCamera(),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      captureSession.canAddInput(input),
                      captureSession.canAddOutput(photoOut) else {
                    captureSession.commitConfiguration()
                    Task { @MainActor [weak self] in
                        self?.authState = .unavailable
                    }
                    return
                }

                do {
                    try camera.lockForConfiguration()
                    if camera.isFocusModeSupported(.continuousAutoFocus) {
                        camera.focusMode = .continuousAutoFocus
                    }
                    if camera.isExposureModeSupported(.continuousAutoExposure) {
                        camera.exposureMode = .continuousAutoExposure
                    }
                    camera.unlockForConfiguration()
                } catch {}

                captureSession.addInput(input)
                captureSession.addOutput(photoOut)
                photoOut.maxPhotoQualityPrioritization = .balanced

                // Lightweight video feed for live Vision blue page-outline overlay (never blocks preview)
                videoOut.alwaysDiscardsLateVideoFrames = true
                videoOut.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOut.setSampleBufferDelegate(processor, queue: vQueue)
                if captureSession.canAddOutput(videoOut) {
                    captureSession.addOutput(videoOut)
                }

                captureSession.commitConfiguration()

                let flashSupported = camera.hasFlash
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.videoDevice = camera
                    self.hasFlash = flashSupported
                    self.isConfigured = true
                    self.updateRotationCoordinator()
                }
            }

            if !captureSession.isRunning {
                captureSession.startRunning()
            }
            Task { @MainActor [weak self] in
                self?.isRunning = true
                self?.updateRotationCoordinator()
            }
        }
    }

    func rebindRotationIfAttached() {
        updateRotationCoordinator()
    }

    private func updateRotationCoordinator() {
        guard let device = videoDevice, let previewLayer else { return }
        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator

            let applyPreviewAngle: (CGFloat) -> Void = { [weak previewLayer] angle in
                if let conn = previewLayer?.connection, conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
            }
            applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)

            previewAngleObservation?.invalidate()
            previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor in
                    applyPreviewAngle(angle)
                }
            }

            captureAngleObservation?.invalidate()
            captureAngleObservation = nil
            currentCaptureRotationAngle = interfaceRotationAngle()
        } else {
            syncLegacyInterfaceOrientation()
        }
    }

    func interfaceRotationAngle() -> CGFloat {
        let sceneOrientation = previewHostView?.window?.windowScene?.interfaceOrientation
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .interfaceOrientation
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?
                .interfaceOrientation
            ?? .portrait

        switch sceneOrientation {
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    func syncLegacyInterfaceOrientation() {
        guard #unavailable(iOS 17.0) else { return }
        let angle = interfaceRotationAngle()
        currentCaptureRotationAngle = angle
        if let conn = previewLayer?.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = Self.legacyOrientation(forAngle: angle)
        }
    }

    private nonisolated static func legacyOrientation(forAngle angle: CGFloat) -> AVCaptureVideoOrientation {
        switch Int(angle.rounded()) % 360 {
        case 0: return .landscapeRight
        case 180: return .landscapeLeft
        case 270: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private nonisolated static func bestBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

private final class PhotoCaptureDelegateProxy: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }
}

// MARK: - SwiftUI Camera Interface

private struct ManualScannerRootView: View {
    let model: ManualScannerModel
    let onCancel: () -> Void
    let onDone: ([UIImage]) -> Void
    let onChoosePhotos: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.authState {
            case .authorized, .checking:
                CameraPreviewRepresentable(model: model)
                    .ignoresSafeArea()

                // Live Vision blue page-outline overlay (smoothly tracks detected sheet music)
                if let quad = model.liveOverlayQuad {
                    LiveDocumentQuadOverlay(quad: quad)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                } else {
                    PageFramingGuidesOverlay()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if let pt = model.focusIndicatorPoint {
                    FocusReticleView()
                        .position(pt)
                        .allowsHitTesting(false)
                }

                if model.showShutterFlash {
                    Color.white.opacity(0.65)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if let toast = model.statusToast {
                        Text(toast)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(.bottom, 12)
                    }
                    bottomControls
                }

                if let inspectingID = model.inspectingPageID,
                   let idx = model.pages.firstIndex(where: { $0.id == inspectingID }) {
                    let page = model.pages[idx]
                    PagePreviewOverlay(
                        pageNumber: idx + 1,
                        totalPages: model.pages.count,
                        image: page.activeImage,
                        hasCropOption: page.hasCropOption,
                        isCropped: page.useCropped,
                        onToggleCrop: { model.togglePageCrop(id: inspectingID) },
                        onRotate: { model.rotatePage(id: inspectingID) },
                        onSaveToPhotos: { model.savePageToPhotos(id: inspectingID) },
                        onDelete: { model.deletePage(id: inspectingID) },
                        onClose: { model.inspectingPageID = nil }
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }

            case .denied:
                permissionDeniedView

            case .unavailable:
                cameraUnavailableView
            }
        }
        .statusBarHidden(true)
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button(action: { model.toggleSaveToPhotos() }) {
                        HStack(spacing: 4) {
                            Image(systemName: model.saveToPhotos ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                            Text(model.saveToPhotos ? "Save" : "Off")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(model.saveToPhotos ? SkyTheme.sky400 : .white.opacity(0.75))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.55), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.saveToPhotos ? "Save scanned pages to Photos: On" : "Save scanned pages to Photos: Off")

                    Button(action: { model.toggleAutoCrop() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "crop")
                                .font(.system(size: 13, weight: .semibold))
                            Text(model.autoCropEnabled ? "Crop" : "Full")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(model.autoCropEnabled ? SkyTheme.sky400 : .white.opacity(0.8))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.55), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.autoCropEnabled ? "Auto-crop on" : "Auto-crop off")

                    if model.hasFlash {
                        Button(action: { model.cycleFlashMode() }) {
                            Image(systemName: flashIconName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(model.flashMode == .on ? Color.yellow : .white)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Flash: \(flashLabel)")
                    }
                }
            }

            // Manual status badge cleanly centered below controls so it never crowds narrow iPhones
            HStack(spacing: 6) {
                Circle()
                    .fill(model.liveOverlayQuad != nil ? Color.green : SkyTheme.sky400)
                    .frame(width: 7, height: 7)
                Text(model.liveOverlayQuad != nil ? "Page Locked · Manual" : "Manual")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.58), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var flashIconName: String {
        switch model.flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        default: return "bolt.slash.fill"
        }
    }

    private var flashLabel: String {
        switch model.flashMode {
        case .on: return "On"
        case .auto: return "Auto"
        default: return "Off"
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if !model.pages.isEmpty {
                VStack(spacing: 6) {
                    Text(
                        model.pages.count == 1
                            ? "1 page scanned — snap another or tap Read Page"
                            : "\(model.pages.count) pages scanned — tap a thumbnail to review or rotate"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.54), in: Capsule())

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                                Button {
                                    model.inspectingPageID = page.id
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: page.activeImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 52, height: 68)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(Color.white.opacity(0.88), lineWidth: 1.5)
                                            )

                                        Text("\(index + 1)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(SkyTheme.blue600, in: Circle())
                                            .offset(x: 5, y: -5)
                                    }
                                    .padding(.top, 6)
                                    .padding(.trailing, 6)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Page \(index + 1). Tap to review, crop, or rotate.")
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .frame(height: 78)
                }
            } else {
                Text(
                    model.liveOverlayQuad != nil
                        ? "Page detected — tap shutter when ready"
                        : "Point at sheet music and tap shutter"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(0.56), in: Capsule())
            }

            HStack {
                // Left slot: Photos shortcut
                Button(action: onChoosePhotos) {
                    VStack(spacing: 3) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20, weight: .medium))
                        Text("Photos")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 86, height: 52)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()

                // Center slot: Manual shutter button
                Button(action: { model.capturePhoto() }) {
                    ZStack {
                        Circle()
                            .stroke(model.liveOverlayQuad != nil ? SkyTheme.sky400 : Color.white, lineWidth: 4)
                            .frame(width: 74, height: 74)
                        Circle()
                            .fill(model.isCapturing ? Color.white.opacity(0.55) : Color.white)
                            .frame(width: 60, height: 60)
                            .scaleEffect(model.isCapturing ? 0.90 : 1.0)
                        if model.isCapturing {
                            ProgressView()
                                .tint(SkyTheme.blue600)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isCapturing)
                .accessibilityLabel("Capture page")

                Spacer()

                // Right slot: Done / Read Pages button
                Button {
                    model.savePagesToPhotosIfEnabled()
                    onDone(model.pages.map(\.activeImage))
                } label: {
                    Text(
                        model.pages.count <= 1
                            ? "Read Page"
                            : "Read \(model.pages.count) Pages"
                    )
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 86, minHeight: 52)
                    .padding(.horizontal, 12)
                    .background(
                        model.pages.isEmpty
                            ? Color.white.opacity(0.14)
                            : SkyTheme.blue600,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.pages.isEmpty || model.isCapturing)
                .opacity(model.pages.isEmpty ? 0.45 : 1.0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .padding(.top, 14)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(SkyTheme.sky400)
            Text("Camera Access Needed")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Allow camera access in Settings so you can scan printed sheet music directly, or pick photos from your library.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 12) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SkyTheme.blue600)

                Button("Choose Photos", action: onChoosePhotos)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 6)
        }
        .padding(28)
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 40))
                .foregroundStyle(SkyTheme.sky400)
            Text("Camera Unavailable")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("You can still pick sheet music from your photo library.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Choose Photos", action: onChoosePhotos)
                    .buttonStyle(.borderedProminent)
                    .tint(SkyTheme.blue600)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding(28)
    }
}

// MARK: - Live Blue Vision Page Overlay

private struct LiveDocumentQuadOverlay: View {
    let quad: DetectedQuad

    var body: some View {
        ZStack {
            quadPath
                .fill(SkyTheme.blue600.opacity(0.18))

            quadPath
                .stroke(
                    SkyTheme.sky400,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

            ForEach(0..<4, id: \.self) { idx in
                let pt = quad.points[idx]
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(SkyTheme.blue600, lineWidth: 2.5))
                    .position(pt)
            }
        }
    }

    private var quadPath: Path {
        Path { p in
            p.move(to: quad.topLeft)
            p.addLine(to: quad.topRight)
            p.addLine(to: quad.bottomRight)
            p.addLine(to: quad.bottomLeft)
            p.closeSubpath()
        }
    }
}

// MARK: - Preview Layer Bridge

private struct CameraPreviewRepresentable: UIViewRepresentable {
    let model: ManualScannerModel

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.onTapToFocus = { devicePoint, viewPoint in
            model.focus(at: devicePoint, viewPoint: viewPoint)
        }
        view.onWindowAttached = { [weak model] in
            model?.rebindRotationIfAttached()
        }
        model.attachPreviewLayer(view.previewLayer, hostView: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        model.syncLegacyInterfaceOrientation()
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    var onWindowAttached: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onWindowAttached?()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: pt)
        onTapToFocus?(devicePoint, pt)
    }
}

// MARK: - Lightweight Framing & Review Overlays

private struct PageFramingGuidesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let insetX = max(24, geo.size.width * 0.08)
            let insetYTop = max(72, geo.size.height * 0.11)
            let insetYBottom = max(185, geo.size.height * 0.24)
            let rect = CGRect(
                x: insetX,
                y: insetYTop,
                width: max(80, geo.size.width - insetX * 2),
                height: max(120, geo.size.height - insetYTop - insetYBottom)
            )
            let cornerLen: CGFloat = 24

            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerLen))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + cornerLen, y: rect.minY))

                p.move(to: CGPoint(x: rect.maxX - cornerLen, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLen))

                p.move(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLen))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX + cornerLen, y: rect.maxY))

                p.move(to: CGPoint(x: rect.maxX - cornerLen, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLen))
            }
            .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct FocusReticleView: View {
    @State private var scale: CGFloat = 1.25

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.yellow, lineWidth: 2)
            .frame(width: 68, height: 68)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                    scale = 1.0
                }
            }
    }
}

private struct PagePreviewOverlay: View {
    let pageNumber: Int
    let totalPages: Int
    let image: UIImage
    let hasCropOption: Bool
    let isCropped: Bool
    let onToggleCrop: () -> Void
    let onRotate: () -> Void
    let onSaveToPhotos: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page \(pageNumber) of \(totalPages)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                        if hasCropOption {
                            Text(isCropped ? "Perspective-cropped" : "Original photo")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SkyTheme.sky400)
                        }
                    }
                    Spacer()
                    Button("Done", action: onClose)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SkyTheme.sky400)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 20)

                Spacer()

                HStack(spacing: 10) {
                    if hasCropOption {
                        previewActionButton(
                            title: isCropped ? "Original" : "Crop",
                            systemImage: "crop",
                            tint: .white.opacity(0.16),
                            action: onToggleCrop
                        )
                    }

                    previewActionButton(
                        title: "Rotate",
                        systemImage: "rotate.right",
                        tint: .white.opacity(0.16),
                        action: onRotate
                    )

                    previewActionButton(
                        title: "Save",
                        systemImage: "square.and.arrow.down",
                        tint: .white.opacity(0.16),
                        action: onSaveToPhotos
                    )

                    previewActionButton(
                        title: "Remove",
                        systemImage: "trash",
                        tint: Color.red.opacity(0.82),
                        role: .destructive,
                        action: onDelete
                    )
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func previewActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 6)
            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Orientation Helpers

private extension UIImage {
    /// Renders pixels into `.up` orientation so downstream Vision cropping and JPEG encoding match what the user saw.
    nonisolated func normalizedUpOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated func rotatedClockwise90() -> UIImage {
        let up = normalizedUpOrientation()
        let newSize = CGSize(width: up.size.height, height: up.size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: .pi / 2)
            up.draw(in: CGRect(x: -up.size.width / 2, y: -up.size.height / 2, width: up.size.width, height: up.size.height))
        }
    }
}
#endif
