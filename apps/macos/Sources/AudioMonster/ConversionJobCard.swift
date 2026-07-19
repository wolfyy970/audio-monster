import SwiftUI

struct ConversionJobCard: View {
    @ObservedObject var model: AppModel
    let job: ConversionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.title ?? job.url.host() ?? "Web page")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(model.isRenderingWebPage ? "Opening page" : job.status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        job.status == .failed && !model.isRenderingWebPage
                            ? Color.red
                            : Color.secondary
                    )
            }

            if model.isRenderingWebPage {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Passing the website’s browser check and reading the rendered page…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !job.status.isTerminal {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                Text(job.message ?? job.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if model.isRenderingWebPage {
                    Button("Cancel", role: .destructive, action: model.cancelCurrentJob)
                        .buttonStyle(.bordered)
                } else if job.status == .completed {
                    Button(action: model.togglePlayback) {
                        Label(
                            model.isPlaying ? "Pause" : "Play",
                            systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    if model.savedFileURL != nil {
                        Button(action: model.revealSavedFile) {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    } else if model.isSavingFile {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: model.retrySavingCompletedJob) {
                            Label("Retry Save", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                } else if !job.status.isTerminal {
                    if job.segmentsReady > 0 {
                        Button(action: model.togglePlayback) {
                            Label(
                                model.isPlaying ? "Pause" : "Listen now",
                                systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Cancel", role: .destructive, action: model.cancelCurrentJob)
                        .buttonStyle(.bordered)
                }
            }

            if !model.isRenderingWebPage
                && (job.segmentsReady > 0 || job.status == .completed)
            {
                PlaybackRateControl(value: $model.playbackRate, presentation: .conversion)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
