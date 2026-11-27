import CoreGraphics
import Foundation
import UIKit
import Vision

/// Automatically detects and corrects 90° clockwise, 90° counter-clockwise, and 180° upside-down
/// sheet music photos on-device before upload.
///
/// Phone photos of flat pages on a desk or music stand frequently carry a sideways EXIF orientation,
/// causing optical music recognition to miss horizontal staves while consuming server GPU time.
enum SheetMusicOrientationNormalizer {
    enum QuarterTurn: Int, Sendable {
        case none = 0
        case clockwise90 = 90
        case upsideDown180 = 180
        case counterClockwise90 = 270
    }

    /// Bakes `.up` orientation, caps the long edge to `maxLongSide`, and rotates sideways or
    /// upside-down sheet music pages so staves run horizontally with titles and clefs upright.
    nonisolated static func normalize(_ image: UIImage, maxLongSide: CGFloat = 2200) -> UIImage {
        let upright = bakeUpAndLimit(image, maxLongSide: maxLongSide)
        guard let cgImage = upright.cgImage else { return upright }

        let turn = detectQuarterTurn(cgImage: cgImage)
        guard turn != .none,
              let rotated = rotateCGImage(cgImage, turn: turn, maxSide: nil) else {
            return upright
        }
        return UIImage(cgImage: rotated, scale: 1.0, orientation: .up)
    }

    /// Detects the quarter-turn needed to make a sheet music `CGImage` upright.
    nonisolated static func detectQuarterTurn(cgImage: CGImage) -> QuarterTurn {
        let (horizontalEnergy, verticalEnergy) = staffLineEnergies(cgImage: cgImage)

        if verticalEnergy > horizontalEnergy * 1.25 {
            // Staves run vertically (90° sideways photo). Rotate 90° CW once and check polarity.
            guard let cwThumb = rotateCGImage(cgImage, turn: .clockwise90, maxSide: 1280) else {
                return .clockwise90
            }
            let (uprightScore, invertedScore) = horizontalPagePolarity(cgImage: cwThumb)
            return invertedScore > uprightScore ? .counterClockwise90 : .clockwise90
        } else if horizontalEnergy > verticalEnergy * 1.25 {
            // Staves already run horizontally (0° or 180°).
            guard let thumb = rotateCGImage(cgImage, turn: .none, maxSide: 1280) else {
                return .none
            }
            let (uprightScore, invertedScore) = horizontalPagePolarity(cgImage: thumb)
            return (invertedScore > uprightScore + 6.0) ? .upsideDown180 : .none
        } else {
            // Ambiguous staff axis: compare 0°/180° against 90°/270°.
            let p0 = rotateCGImage(cgImage, turn: .none, maxSide: 1280)
                .map(horizontalPagePolarity) ?? (upright: 0, inverted: 0)
            let p90 = rotateCGImage(cgImage, turn: .clockwise90, maxSide: 1280)
                .map(horizontalPagePolarity) ?? (upright: 0, inverted: 0)
            let candidates: [(QuarterTurn, Double)] = [
                (.none, p0.0),
                (.upsideDown180, p0.1),
                (.clockwise90, p90.0),
                (.counterClockwise90, p90.1),
            ]
            return candidates.max(by: { $0.1 < $1.1 })?.0 ?? .none
        }
    }

    // MARK: - Private Helpers

    nonisolated private static func bakeUpAndLimit(_ image: UIImage, maxLongSide: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height) * image.scale
        if longSide <= maxLongSide && image.imageOrientation == .up {
            return image
        }
        let ratio = min(1.0, maxLongSide / max(longSide, 1.0))
        let targetSize = CGSize(
            width: max(1, (image.size.width * image.scale * ratio).rounded()),
            height: max(1, (image.size.height * image.scale * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated private static func rotateCGImage(
        _ cgImage: CGImage,
        turn: QuarterTurn,
        maxSide: Int?
    ) -> CGImage? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        let scale: Double = {
            guard let maxSide else { return 1.0 }
            return min(1.0, Double(maxSide) / Double(max(srcW, srcH, 1)))
        }()
        let scaledW = max(1, Int((Double(srcW) * scale).rounded()))
        let scaledH = max(1, Int((Double(srcH) * scale).rounded()))
        if turn == .none && scaledW == srcW && scaledH == srcH {
            return cgImage
        }

        let swapsAxes = (turn == .clockwise90 || turn == .counterClockwise90)
        let dstW = swapsAxes ? scaledH : scaledW
        let dstH = swapsAxes ? scaledW : scaledH
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        switch turn {
        case .none:
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        case .clockwise90:
            ctx.translateBy(x: 0, y: CGFloat(dstH))
            ctx.rotate(by: -.pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledW, height: scaledH))
        case .counterClockwise90:
            ctx.translateBy(x: CGFloat(dstW), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledW, height: scaledH))
        case .upsideDown180:
            ctx.translateBy(x: CGFloat(dstW), y: CGFloat(dstH))
            ctx.rotate(by: .pi)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        }
        return ctx.makeImage()
    }

    /// Compares high-pass row-projection energy vs. column-projection energy in the central 80% of the page.
    /// Horizontal 5-line staves create strong high-frequency energy across rows; sideways staves create it across columns.
    nonisolated private static func staffLineEnergies(cgImage: CGImage) -> (horizontal: Double, vertical: Double) {
        let maxDim = 512.0
        let scale = min(1.0, maxDim / Double(max(cgImage.width, cgImage.height, 1)))
        let w = max(32, Int((Double(cgImage.width) * scale).rounded()))
        let h = max(32, Int((Double(cgImage.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return (0, 0)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let x0 = w / 10, x1 = w - w / 10
        let y0 = h / 10, y1 = h - h / 10
        let cw = max(1, x1 - x0)
        let ch = max(1, y1 - y0)
        var rowMeans = [Double](repeating: 0, count: ch)
        var colMeans = [Double](repeating: 0, count: cw)

        for y in y0..<y1 {
            var sum = 0
            let rowOffset = y * w
            for x in x0..<x1 {
                let value = Int(pixels[rowOffset + x])
                sum += value
                colMeans[x - x0] += Double(value)
            }
            rowMeans[y - y0] = Double(sum) / Double(cw)
        }
        for i in 0..<cw {
            colMeans[i] /= Double(ch)
        }

        func highPassEnergy(_ signal: [Double]) -> Double {
            let radius = 4
            guard signal.count > radius * 2 + 2 else { return 0 }
            var energy = 0.0
            for i in radius..<(signal.count - radius) {
                var localSum = 0.0
                for k in (i - radius)...(i + radius) {
                    localSum += signal[k]
                }
                let diff = signal[i] - localSum / Double(radius * 2 + 1)
                energy += diff * diff
            }
            return energy / Double(signal.count - 2 * radius)
        }

        return (highPassEnergy(rowMeans), highPassEnergy(colMeans))
    }

    /// Combines left-vs-right system clef/brace ink asymmetry with Vision upright text directionality
    /// to distinguish upright (`0°`) from upside-down (`180°`) horizontal staves in a single pass.
    nonisolated private static func horizontalPagePolarity(cgImage: CGImage) -> (upright: Double, inverted: Double) {
        let clefWeight = clefLeftRightLogRatio(cgImage: cgImage) * 45.0
        let (textUpright, textInverted) = directionalTextPolarity(cgImage: cgImage)
        let upright = textUpright + max(0, clefWeight)
        let inverted = textInverted + max(0, -clefWeight)
        return (upright, inverted)
    }

    /// Measures ink concentration at the left end vs. right end of full-width staff rows.
    /// Western systems begin on the left with braces, clefs, and key/time signatures.
    nonisolated private static func clefLeftRightLogRatio(cgImage: CGImage) -> Double {
        let w = 400
        let h = max(32, Int((Double(cgImage.height) / Double(max(cgImage.width, 1)) * 400.0).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var leftEnergy = 0.0
        var rightEnergy = 0.0
        let yStart = h / 12
        let yEnd = max(yStart + 1, h - h / 12)
        let margin = w / 22

        for y in yStart..<yEnd {
            let row = y * w
            var rowSum = 0
            for x in (w / 8)..<(w - w / 8) {
                rowSum += Int(pixels[row + x])
            }
            let background = Double(rowSum) / Double(max(1, w - 2 * (w / 8)))
            let threshold = background - 22.0
            var firstX = -1
            var lastX = -1
            for x in margin..<(w - margin) {
                if Double(pixels[row + x]) < threshold {
                    if firstX == -1 { firstX = x }
                    lastX = x
                }
            }
            let span = lastX - firstX
            guard firstX >= 0, span > w / 2 else { continue }
            let band = max(8, span / 8)
            for x in firstX..<(firstX + band) {
                leftEnergy += max(0.0, background - Double(pixels[row + x]) - 12.0)
            }
            for x in (lastX - band + 1)...lastX {
                rightEnergy += max(0.0, background - Double(pixels[row + x]) - 12.0)
            }
        }

        guard leftEnergy > 500 || rightEnergy > 500 else { return 0 }
        return log(max(leftEnergy, 1.0) / max(rightEnergy, 1.0))
    }

    nonisolated private static func directionalTextPolarity(cgImage: CGImage) -> (upright: Double, inverted: Double) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let results = request.results else { return (0, 0) }

        var upright = 0.0
        var inverted = 0.0
        for observation in results {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.50 else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let latinLetters = text.unicodeScalars.filter {
                ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
            }.count
            guard latinLetters >= 3 else { continue }

            let weight = Double(candidate.confidence) * Double(min(latinLetters, 12)) * 1.5
            let dx = observation.topRight.x - observation.topLeft.x
            let dy = observation.topLeft.y - observation.bottomLeft.y
            if dx > 0.005 && dy > 0 {
                let headerBoost = observation.boundingBox.midY > 0.72 ? 1.4 : 1.0
                upright += weight * headerBoost
            } else if dx < -0.005 && dy < 0 {
                let headerBoost = observation.boundingBox.midY < 0.28 ? 1.4 : 1.0
                inverted += weight * headerBoost
            }
        }
        return (upright, inverted)
    }
}
