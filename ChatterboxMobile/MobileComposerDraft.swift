import Foundation
import Observation

/// A chat owns its draft, rather than each presentation of that chat owning a copy.
/// Consume it synchronously when submitting; an acknowledgment only finishes that
/// submission, and never clears whatever the reader has typed since.
@MainActor @Observable
final class MobileComposerDraft<Image> {
    struct Submission {
        let id: UUID
        let text: String
        let images: [Image]
    }

    var text: String { didSet { persistText(text) } }
    var images: [Image] { didSet { persistImages(images) } }
    private(set) var inFlight: UUID?
    private(set) var inputGeneration = UUID()
    var sending: Bool { inFlight != nil }
    @ObservationIgnored private let persistText: (String) -> Void
    @ObservationIgnored private let persistImages: ([Image]) -> Void

    init(text: String = "", images: [Image] = [],
         persistText: @escaping (String) -> Void = { _ in },
         persistImages: @escaping ([Image]) -> Void = { _ in }) {
        self.text = text
        self.images = images
        self.persistText = persistText
        self.persistImages = persistImages
    }

    func beginSend() -> Submission? {
        guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        let submission = Submission(id: UUID(), text: text, images: images)
        inFlight = submission.id
        inputGeneration = UUID()
        text = ""
        images = []
        return submission
    }

    /// Speech recognition can deliver its final callback after Stop/Send. Reject
    /// transcriptions belonging to the draft that has already been submitted.
    func applyTranscription(_ spoken: String, prefix: String, generation: UUID) {
        guard inputGeneration == generation else { return }
        text = prefix.isEmpty ? spoken : prefix + " " + spoken
    }

    func finish(_ submission: Submission, failed: Bool = false) {
        guard inFlight == submission.id else { return }
        if failed {
            // Keep both unsent drafts if the reader continued typing during the request.
            if text.isEmpty { text = submission.text }
            else if !submission.text.isEmpty { text = submission.text + "\n\n" + text }
            images = submission.images + images
        }
        inFlight = nil
    }
}
