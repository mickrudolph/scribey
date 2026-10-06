import SwiftUI

struct WaveformView: View {
    let levels: [Float]

    private let minBarHeight: CGFloat = 3
    private let maxBarHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(for: level))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(maxHeight: maxBarHeight)
    }

    private func barHeight(for level: Float) -> CGFloat {
        minBarHeight + CGFloat(level) * (maxBarHeight - minBarHeight)
    }
}
