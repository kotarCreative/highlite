import Foundation

/// The annotation kinds the browser SDK offers, mirrored for native still
/// captures. The canonical compiler owns rendering; this type only describes
/// the normalized geometry that the review UI collects.
public enum NativeCaptureAnnotationKind: String, CaseIterable, Hashable, Sendable {
    case freehand
    case circle
    case arrow
    case highlight
}

/// A point in the capture image's top-left-origin, viewport-normalized space.
public struct NativeCapturePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Limits shared by the review UI and the bundle builder. The browser recorder
/// has no practical cap, but a native review window should not build an
/// unbounded manifest from a runaway gesture.
public enum NativeCaptureAnnotationLimits {
    public static let maximumAnnotations = 64
    public static let maximumPointsPerAnnotation = 4_096
    /// Matches the SDK's four CSS-pixel stroke and 14-pixel arrow head.
    public static let strokeWidth: Double = 4
    public static let arrowHeadLength: Double = 14
}

/// One normalized annotation over a still capture. Freehand keeps every sampled
/// point; circle, arrow, and highlight use the first point as the drag origin and
/// the last point as the drag end, matching the browser toolbar's geometry.
public struct NativeCaptureAnnotation: Equatable, Sendable {
    public let kind: NativeCaptureAnnotationKind
    public let points: [NativeCapturePoint]

    public init(kind: NativeCaptureAnnotationKind, points: [NativeCapturePoint]) {
        self.kind = kind
        self.points = points
    }

    /// Whether this annotation has meaningful geometry at the capture's pixel
    /// size. The review UI uses this to discard accidental clicks, and the
    /// bundle builder uses it to reject malformed manifests.
    public func isRenderable(imageWidth: Int, imageHeight: Int) -> Bool {
        guard imageWidth > 0, imageHeight > 0,
              points.count >= 2,
              points.count <= NativeCaptureAnnotationLimits.maximumPointsPerAnnotation
        else {
            return false
        }

        let epsilon = 1e-9
        for point in points {
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= 0, point.y >= 0,
                  point.x <= 1 + epsilon, point.y <= 1 + epsilon
            else {
                return false
            }
        }

        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let first = points[0]
        let last = points[points.count - 1]

        switch kind {
        case .freehand:
            var length = 0.0
            for index in 1..<points.count {
                let dx = (points[index].x - points[index - 1].x) * width
                let dy = (points[index].y - points[index - 1].y) * height
                length += (dx * dx + dy * dy).squareRoot()
            }
            return length >= 1
        case .circle, .highlight:
            return abs(last.x - first.x) * width >= 1
                && abs(last.y - first.y) * height >= 1
        case .arrow:
            let dx = (last.x - first.x) * width
            let dy = (last.y - first.y) * height
            return (dx * dx + dy * dy).squareRoot() >= 1
        }
    }

    /// Bounding box in normalized coordinates, used to label and validate a
    /// multi-annotation capture in tests and diagnostics.
    public var normalizedBounds: NativeCaptureRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return NativeCaptureRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}
