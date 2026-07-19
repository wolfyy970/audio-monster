import SwiftUI

struct PlaybackRateControl: View {
    enum Presentation {
        case settings
        case library
        case conversion
    }

    @Binding var value: Double
    let presentation: Presentation

    var body: some View {
        HStack(spacing: spacing) {
            Text(label)
                .font(labelFont)
            if presentation == .settings { Spacer() }
            endpoint("0.2×")
            Slider(
                value: $value,
                in: AppSettings.playbackRateRange,
                step: 0.1
            )
            .frame(width: presentation == .settings ? 230 : nil)
            endpoint("3×")
            Text("\(value, format: .number.precision(.fractionLength(1)))×")
                .font(valueFont)
                .monospacedDigit()
                .frame(width: valueWidth, alignment: .trailing)
        }
        .help(helpText)
    }

    private func endpoint(_ text: String) -> some View {
        Text(text)
            .font(presentation == .settings ? .caption.monospacedDigit() : .caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var label: String {
        presentation == .settings ? "Playback speed" : "Speed"
    }

    private var labelFont: Font? {
        presentation == .settings ? nil : .caption.weight(.medium)
    }

    private var valueFont: Font? {
        switch presentation {
        case .settings: nil
        case .library: .caption
        case .conversion: .caption.weight(.semibold)
        }
    }

    private var valueWidth: CGFloat {
        switch presentation {
        case .settings: 42
        case .library: 35
        case .conversion: 36
        }
    }

    private var spacing: CGFloat? {
        switch presentation {
        case .settings: nil
        case .library: 9
        case .conversion: 8
        }
    }

    private var helpText: String {
        presentation == .settings
            ? "Default playback speed for generated and saved audio"
            : "Playback speed — pitch is preserved"
    }
}
