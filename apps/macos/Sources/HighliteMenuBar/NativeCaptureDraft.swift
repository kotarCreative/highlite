import AppKit
import Combine
import Foundation
import HighliteMenuBarCore

/// Editable state for one still capture. The PNG stays untouched; the highlight
/// is stored as a normalized rectangle and burned into bundle frames by the
/// canonical compiler, exactly like browser annotations.
@MainActor
final class NativeCaptureDraft: ObservableObject {
    let pngData: Data
    let image: NSImage
    let imageWidth: Int
    let imageHeight: Int
    let createdAt: Date

    @Published var note = ""
    @Published var highlight: NativeCaptureRect?

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
        return highlight != nil
            && !trimmed.isEmpty
            && trimmed.count <= NativeCaptureBundleBuilder.maximumNoteLength
    }

    func makeBundle() throws -> NativeCaptureBundle {
        guard let highlight else {
            throw NativeCaptureBundleError.invalidHighlight
        }
        return try NativeCaptureBundleBuilder.build(
            pngData: pngData,
            note: note,
            highlight: highlight,
            createdAt: createdAt
        )
    }
}
