import Foundation
import SwiftUI

/// Shared by Golem's Mac and iOS speech requests. Preferences stay local to each app/device.
enum ElevenLabsSpeechSettings {
    static let speedKey = "golemElevenLabsSpeakingSpeed"
    static let speedRange = 0.7...1.2
    static let defaultSpeed = 1.0

    static func supportedSpeed(_ value: Double) -> Double {
        value.isFinite ? min(speedRange.upperBound, max(speedRange.lowerBound, value)) : defaultSpeed
    }

    static func speed(in defaults: UserDefaults = AppPreferences.defaults) -> Double {
        supportedSpeed((defaults.object(forKey: speedKey) as? NSNumber)?.doubleValue ?? defaultSpeed)
    }

    static func payload(text: String, speed: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": ["speed": supportedSpeed(speed)]
        ])
    }
}

struct ElevenLabsSpeedControl: View {
    @AppStorage(ElevenLabsSpeechSettings.speedKey, store: AppPreferences.defaults)
    private var speed = ElevenLabsSpeechSettings.defaultSpeed

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ElevenLabs speaking speed")
                Spacer()
                Text(String(format: "%.2f×", ElevenLabsSpeechSettings.supportedSpeed(speed)))
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { ElevenLabsSpeechSettings.supportedSpeed(speed) },
                set: { speed = ElevenLabsSpeechSettings.supportedSpeed($0) }
            ), in: ElevenLabsSpeechSettings.speedRange, step: 0.05) {
                Text("ElevenLabs speaking speed")
            } minimumValueLabel: { Text("0.7×") } maximumValueLabel: { Text("1.2×") }
            .labelsHidden()
            .accessibilityLabel("ElevenLabs speaking speed")
            .accessibilityIdentifier("elevenlabs-speaking-speed")
            Text("1.0× is normal. Applies to new ElevenLabs audio; the built-in voice stays unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
