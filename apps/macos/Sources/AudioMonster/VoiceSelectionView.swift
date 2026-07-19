import SwiftUI

struct VoiceSelectionControl: View {
    let voices: [Voice]
    @Binding var selectedVoiceID: String
    @ObservedObject var model: AppModel
    @State private var isPresentingBrowser = false

    private var selectedVoice: Voice? {
        voices.first { $0.id == selectedVoiceID }
    }

    var body: some View {
        HStack {
            Text("Voice")

            Button {
                isPresentingBrowser.toggle()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedVoice?.name ?? "Choose a voice")
                            .foregroundStyle(.primary)
                        if let selectedVoice {
                            Text(
                                "\(selectedVoice.language.displayName) · \(selectedVoice.gender.displayName)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .popover(isPresented: $isPresentingBrowser, arrowEdge: .bottom) {
                VoiceBrowserView(
                    voices: voices,
                    selectedVoiceID: $selectedVoiceID,
                    model: model
                )
            }

            if let selectedVoice {
                VoicePreviewButton(voice: selectedVoice, model: model, includesText: true)
            }
        }
    }
}

private struct VoiceBrowserView: View {
    let voices: [Voice]
    @Binding var selectedVoiceID: String
    @ObservedObject var model: AppModel

    private var sections: [VoiceGenderSection] {
        VoiceCatalogOrdering.sections(for: voices)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a voice")
                        .font(.headline)
                    Text("Selecting a voice plays its 10-second sample.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                previewReadiness
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        genderHeader(section)
                        ForEach(section.languages) { language in
                            languageHeader(language)
                            ForEach(language.voices) { voice in
                                voiceRow(voice)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 470, height: 500)
    }

    @ViewBuilder
    private var previewReadiness: some View {
        if model.voicePreviewsTotal > 0 {
            VStack(alignment: .trailing, spacing: 4) {
                Text(
                    model.voicePreviewsReady == model.voicePreviewsTotal
                        ? "Samples ready"
                        : "\(model.voicePreviewsReady) of \(model.voicePreviewsTotal) samples"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                if model.voicePreviewsReady < model.voicePreviewsTotal {
                    ProgressView(
                        value: Double(model.voicePreviewsReady),
                        total: Double(model.voicePreviewsTotal)
                    )
                    .frame(width: 90)
                }
            }
        }
    }

    private func genderHeader(_ section: VoiceGenderSection) -> some View {
        HStack(spacing: 8) {
            Text(section.gender.title)
                .font(.headline)
            Text("\(section.voiceCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .padding(.top, 14)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func languageHeader(_ section: VoiceLanguageSection) -> some View {
        HStack {
            Text(section.language)
            Spacer()
            Text(section.languageCode)
                .monospaced()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func voiceRow(_ voice: Voice) -> some View {
        let isSelected = voice.id == selectedVoiceID
        return HStack(spacing: 8) {
            Button {
                guard selectedVoiceID != voice.id else { return }
                selectedVoiceID = voice.id
                model.startVoicePreview(voiceID: voice.id)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(voice.name)
                        .foregroundStyle(.primary)
                    if voice.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Select \(voice.name), \(voice.language.displayName), \(voice.gender.displayName)"
            )

            VoicePreviewButton(voice: voice, model: model, includesText: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }
}

private struct VoicePreviewButton: View {
    let voice: Voice
    @ObservedObject var model: AppModel
    let includesText: Bool

    private var previewStatus: VoicePreviewStatus? {
        model.voicePreviews[voice.id]?.status
    }

    private var isPlaying: Bool {
        model.playingPreviewVoiceID == voice.id
    }

    var body: some View {
        if previewStatus == .pending || previewStatus == .generating {
            ProgressView()
                .controlSize(.small)
                .frame(width: includesText ? 108 : 28)
                .help("Preparing \(voice.name)'s sample")
        } else if includesText {
            Button {
                model.toggleVoicePreview(voiceID: voice.id)
            } label: {
                Label(
                    isPlaying ? "Pause sample" : "Play sample",
                    systemImage: isPlaying ? "pause.fill" : previewIcon
                )
            }
            .buttonStyle(.bordered)
            .help(previewHelp)
            .accessibilityLabel(previewHelp)
        } else {
            Button {
                model.toggleVoicePreview(voiceID: voice.id)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : previewIcon)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(previewHelp)
            .accessibilityLabel(previewHelp)
        }
    }

    private var previewIcon: String {
        previewStatus == .failed ? "arrow.clockwise" : "play.fill"
    }

    private var previewHelp: String {
        if isPlaying { return "Pause \(voice.name)'s sample" }
        if previewStatus == .failed { return "Retry \(voice.name)'s sample" }
        return "Play \(voice.name)'s 10-second sample"
    }
}
