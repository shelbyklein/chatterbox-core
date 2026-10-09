import Foundation

/// Golem's conversation cues as short WAV clips, synthesized (no sound files). Foundation only, so
/// a fixture checks them on a Mac (tests/golem-ios-voice/cues).
enum GolemCueTones {
    enum Cue: CaseIterable { case listening, sent, thinking }
    static let sampleRate = 44_100

    /// (frequency in Hz, seconds) per note, played back to back.
    static func notes(_ cue: Cue) -> [(Double, Double)] {
        switch cue {
        case .listening: return [(659.25, 0.07), (880.0, 0.12)]   // rising E5 → A5: your turn
        case .sent: return [(1174.66, 0.05)]                      // one short D6 tick: sent
        case .thinking: return [(587.33, 0.08), (440.0, 0.13)]    // falling D5 → A4: he's thinking
        }
    }

    /// 16-bit mono WAV. Each note fades in over 8 ms and out over 40 ms, so there are no clicks.
    static func wav(_ cue: Cue, gain: Double = 0.35) -> Data {
        var samples: [Int16] = []
        for (hz, length) in notes(cue) {
            let count = Int(Double(sampleRate) * length)
            for i in 0 ..< count {
                let t = Double(i) / Double(sampleRate)
                let envelope = max(0, min(1, t / 0.008, (length - t) / 0.04))
                let tone = sin(2 * .pi * hz * t) * 0.85 + sin(4 * .pi * hz * t) * 0.15   // a little brightness
                samples.append(Int16((tone * envelope * gain * Double(Int16.max)).rounded()))
            }
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(sample) }
        return data
    }

    static func duration(_ cue: Cue) -> Double { notes(cue).reduce(0) { $0 + $1.1 } }
}
