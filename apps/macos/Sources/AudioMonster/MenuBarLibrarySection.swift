import SwiftUI

struct MenuBarLibrarySection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Library")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.libraryItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.refreshLibrary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh audio folder")
            }

            if model.libraryItems.isEmpty {
                Text("Finished audio will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(model.libraryItems.enumerated()), id: \.element.id) { index, item in
                            libraryRow(item, number: index + 1)
                        }
                    }
                }
                .scrollIndicators(model.libraryItems.count > 3 ? .visible : .hidden)
                .frame(height: min(CGFloat(model.libraryItems.count) * 43, 129))
            }

            if let item = model.activeLibraryItem {
                libraryPlayer(item)
            }

            if let message = model.libraryErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }

    private func libraryRow(_ item: AudioLibraryItem, number: Int) -> some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            Button {
                model.toggleLibraryPlayback(item)
            } label: {
                Image(
                    systemName: model.activeLibraryItemID == item.id && model.isLibraryPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help(model.activeLibraryItemID == item.id && model.isLibraryPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(model.activeLibraryItemID == item.id ? .semibold : .regular))
                    .lineLimit(1)
                Text(item.modifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.revealLibraryItem(item)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 7)
        .frame(height: 40)
        .background(
            model.activeLibraryItemID == item.id ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private func libraryPlayer(_ item: AudioLibraryItem) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 9) {
                Button(action: model.playPreviousLibraryItem) {
                    Image(systemName: "backward.fill")
                }
                .disabled(!model.hasPreviousLibraryItem)

                Button(action: model.toggleActiveLibraryPlayback) {
                    Image(systemName: model.isLibraryPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 13)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: model.playNextLibraryItem) {
                    Image(systemName: "forward.fill")
                }
                .disabled(!model.hasNextLibraryItem)

                Slider(
                    value: Binding(
                        get: { model.libraryPlaybackProgress },
                        set: { progress in model.seekLibrary(to: progress) }
                    ),
                    in: 0...1
                )

                Text("\(formatTime(model.libraryElapsedSeconds)) / \(formatTime(model.libraryDurationSeconds))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }

            PlaybackRateControl(value: $model.playbackRate, presentation: .library)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player for \(item.title)")
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
