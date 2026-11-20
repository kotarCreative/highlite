import AppKit
import Combine
import Foundation
import HighliteMenuBarCore

/// Editable state for one still capture. The PNG stays untouched; annotations
/// are stored as normalized geometry and burned into bundle frames by the
/// canonical compiler, exactly like browser annotations.
@MainActor
final class NativeCaptureDraft: ObservableObject {
    let pngData: Data
    let image: NSImage
    let imageWidth: Int
    let imageHeight: Int
    let createdAt: Date

    @Published var note = ""
    @Published var selectedTool: NativeCaptureAnnotationKind = .highlight
    @Published var annotations: [NativeCaptureAnnotation] = []

    init(pngData: Data, createdAt: Date = Date()) throws {
        let (width, height) = try NativeCaptureBundleBuilder.imageDimensions(in: pngData)
        guard let image = NSImage(data: pngData) else {
            throw NativeCaptureBundleError.invalidImage
        }
        self.pngData = pngData
        self.image = image
        self.imageWidth = width
        self.imageHeight = height
        self.createdAt = createdAt
    }

    var canSave: Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return !annotations.isEmpty
            && !trimmed.isEmpty
            && trimmed.count <= NativeCaptureBundleBuilder.maximumNoteLength
    }

    @discardableResult
    func addAnnotation(_ annotation: NativeCaptureAnnotation) -> Bool {
        guard annotations.count < NativeCaptureBundleBuilder.maximumAnnotationCount,
              annotation.isRenderable(imageWidth: imageWidth, imageHeight: imageHeight)
        else {
            return false
        }
        annotations.append(annotation)
        return true
    }

    func undoLastAnnotation() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    func clearAnnotations() {
        annotations.removeAll()
    }

    func makeBundle() throws -> NativeCaptureBundle {
        return try NativeCaptureBundleBuilder.build(
            pngData: pngData,
            note: note,
            annotations: annotations,
            createdAt: createdAt
        )
    }
}
