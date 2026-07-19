import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var model: AppModel
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            submitField

            if let job = model.currentJob {
                ConversionJobCard(model: model, job: job)
            } else {
                emptyState
            }

            MenuBarLibrarySection(model: model)

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 600)
        .task {
            await model.startIfNeeded()
            isURLFieldFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Audio Monster")
                .font(.headline)
            Spacer()
        }
    }

    private var submitField: some View {
        HStack(spacing: 8) {
            TextField("Paste an article URL…", text: $model.inputURL)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFieldFocused)
                .onSubmit(model.submit)

            Button(action: model.submit) {
                Image(systemName: "arrow.right")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            .help("Create audio")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Turn reading into listening")
                .font(.subheadline.weight(.medium))
            Text(
                "Paste a public web page. The readable article will be extracted, narrated, and saved to your audio library."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button(action: showSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func showSettings() {
        openSettings()
        SettingsWindowPresenter.shared.bringToFront()
        DispatchQueue.main.async {
            SettingsWindowPresenter.shared.bringToFront()
        }
    }
}
