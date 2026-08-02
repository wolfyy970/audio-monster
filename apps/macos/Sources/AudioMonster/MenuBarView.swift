import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var model: AppModel
    @FocusState private var isURLFieldFocused: Bool
    @State private var isShowingPasteEditor = false
    @State private var pastedTitle = ""
    @State private var pastedText = ""

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
        .sheet(isPresented: $isShowingPasteEditor) {
            pasteEditor
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

            Button(action: openPasteEditor) {
                Label("Paste text", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)

            Button(action: model.openDocument) {
                Label("Open file", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
        }
    }

    private var pasteEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste text")
                .font(.headline)

            TextField("Optional title", text: $pastedTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $pastedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 240)

            HStack {
                Button("Cancel") {
                    isShowingPasteEditor = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create audio") {
                    model.submitPastedText(title: pastedTitle, text: pastedText)
                    if model.errorMessage == nil {
                        isShowingPasteEditor = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
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

    private func openPasteEditor() {
        pastedTitle = ""
        pastedText = NSPasteboard.general.string(forType: .string) ?? ""
        isShowingPasteEditor = true
    }
}
