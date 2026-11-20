import CoreGraphics
import Foundation

/// Where ScreenCaptureKit is capturing from, in screen points. The still-image
/// and recording review UIs use the same normalized annotation model; the live
/// recorder uses this rectangle to place its floating toolbar and drawing
/// overlay exactly over the selected window or display.
public struct NativeRecordingCaptureArea: Sendable, Equatable {
    public let contentRect: CGRect
    public let pointPixelScale: CGFloat

    public init(contentRect: CGRect, pointPixelScale: CGFloat) {
        self.contentRect = contentRect
        self.pointPixelScale = pointPixelScale
    }
}

/// One annotation drawn on the live screen while a recording is running.
/// Coordinates are normalized to the captured content rectangle, so the same
/// geometry can be burned into a keyframe after the movie is finalized.
public struct NativeLiveAnnotationStroke: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Milliseconds since capture started.
    public let atMilliseconds: Int
    public let annotation: NativeCaptureAnnotation

    public init(
        id: UUID = UUID(),
        atMilliseconds: Int,
        annotation: NativeCaptureAnnotation
    ) {
        self.id = id
        self.atMilliseconds = atMilliseconds
        self.annotation = annotation
    }
}

/// A keyframe planned from live drawing, before its PNG is extracted from the
/// finalized movie.
public struct NativeLiveAnnotationMoment: Sendable, Equatable {
    public let atMilliseconds: Int
    public let annotations: [NativeCaptureAnnotation]

    public init(atMilliseconds: Int, annotations: [NativeCaptureAnnotation]) {
        self.atMilliseconds = atMilliseconds
        self.annotations = annotations
    }
}

/// Turns a stream of live strokes into the small number of keyframes the
/// canonical compiler accepts. Strokes that land inside the compiler's
/// duplicate-frame window share a keyframe, and excess strokes attach to the
/// last planned keyframe instead of failing the save.
public enum NativeLiveAnnotationPlanner {
    public static func moments(
        from strokes: [NativeLiveAnnotationStroke],
        durationMilliseconds: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> [NativeLiveAnnotationMoment] {
        guard durationMilliseconds >= NativeRecordingBundleBuilder.minimumMomentGapMilliseconds,
              imageWidth > 0,
              imageHeight > 0
        else {
            return []
        }

        let minimumGap = NativeRecordingBundleBuilder.minimumMomentGapMilliseconds
        let maximumMoments = NativeRecordingBundleBuilder.maximumMoments(
            forDurationMilliseconds: durationMilliseconds
        )
        guard maximumMoments > 0 else { return [] }

        let maximumAnnotations = NativeCaptureAnnotationLimits.maximumAnnotations
        let sortedStrokes = strokes
            .filter { $0.atMilliseconds >= 0 }
            .filter {
                $0.annotation.isRenderable(
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
            }
            .sorted { left, right in
                if left.atMilliseconds == right.atMilliseconds {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.atMilliseconds < right.atMilliseconds
            }

        var groups: [(atMilliseconds: Int, annotations: [NativeCaptureAnnotation])] = []

        for stroke in sortedStrokes {
            let candidateAt = min(
                durationMilliseconds,
                max(minimumGap, stroke.atMilliseconds)
            )

            guard let lastIndex = groups.indices.last else {
                groups.append(
                    (atMilliseconds: candidateAt, annotations: [stroke.annotation])
                )
                continue
            }

            let last = groups[lastIndex]
            if candidateAt - last.atMilliseconds < minimumGap
                || groups.count >= maximumMoments {
                // Merge into the current keyframe so every stroke survives
                // without creating an invalid sub-500 ms keyframe.
                if last.annotations.count < maximumAnnotations {
                    var merged = last.annotations
                    merged.append(stroke.annotation)
                    groups[lastIndex] = (
                        atMilliseconds: last.atMilliseconds,
                        annotations: merged
                    )
                }
            } else {
                groups.append(
                    (atMilliseconds: candidateAt, annotations: [stroke.annotation])
                )
            }
        }

        return groups.map {
            NativeLiveAnnotationMoment(
                atMilliseconds: $0.atMilliseconds,
                annotations: $0.annotations
            )
        }
    }
}
