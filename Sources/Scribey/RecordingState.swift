import Combine

enum RecordingPhase {
    case idle
    case recording
    case locked
    case transcribing
    case notReady
}

final class RecordingState: ObservableObject {
    static let waveformBarCount = 9

    // Each bar reacts to the same instantaneous level but with its own fixed
    // multiplier, so the bars fan out unevenly like a real level meter
    // instead of moving in lockstep.
    private static let barMultipliers: [Float] = (0..<waveformBarCount).map { _ in Float.random(in: 0.55...1.0) }

    @Published var phase: RecordingPhase = .idle
    @Published var waveformLevels: [Float] = Array(repeating: 0, count: RecordingState.waveformBarCount)

    func pushAmplitude(_ level: Float) {
        for i in 0..<waveformLevels.count {
            waveformLevels[i] = level * Self.barMultipliers[i]
        }
    }

    func resetWaveform() {
        waveformLevels = Array(repeating: 0, count: RecordingState.waveformBarCount)
    }
}
