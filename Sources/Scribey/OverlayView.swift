import SwiftUI

struct OverlayView: View {
    @ObservedObject var state: RecordingState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            if showsWaveform {
                WaveformView(levels: state.waveformLevels)
                    .frame(width: 45, height: 28)
            }
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.8))
        )
    }

    private var showsWaveform: Bool {
        switch state.phase {
        case .recording, .locked: return true
        default: return false
        }
    }

    private var label: String {
        switch state.phase {
        case .idle: return ""
        case .recording, .locked: return ""
        case .transcribing: return "Transcribing…"
        case .notReady: return "Starting up…"
        }
    }

    private var dotColor: Color {
        switch state.phase {
        case .recording, .locked: return .red
        case .transcribing: return .yellow
        case .notReady: return .gray
        case .idle: return .clear
        }
    }
}
