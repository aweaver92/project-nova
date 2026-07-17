import SwiftUI
import NovaDomain

/// Voice-memo tab: lists recordings saved to the iPhone with export/share and
/// swipe-to-delete. The same recorder + store back Nova's `start_voice_recording`
/// / `stop_voice_recording` tools, so memos captured by voice ("Nova, begin voice
/// recording") appear here alongside ones started from the button.
public struct RecordingsView: View {
    @Bindable var recording: RecordingViewModel

    public init(recording: RecordingViewModel) {
        self.recording = recording
    }

    public var body: some View {
        NavigationStack {
            Group {
                if recording.recordings.isEmpty {
                    ContentUnavailableView {
                        Label("No Recordings", systemImage: "waveform")
                    } description: {
                        Text("Tap the record button on the Assistant tab, or say “Nova, begin voice recording”.")
                    }
                } else {
                    List {
                        ForEach(recording.recordings) { item in
                            RecordingRow(item: item, url: recording.fileURL(for: item))
                        }
                        .onDelete { offsets in
                            Task { await recording.delete(at: offsets) }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !recording.recordings.isEmpty {
                        Button(role: .destructive) {
                            Task { await recording.clear() }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete all recordings")
                    }
                }
            }
            .task { await recording.load() }
        }
    }
}

private struct RecordingRow: View {
    let item: VoiceRecording
    let url: URL?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body)
                Text(Self.duration(item.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share or save recording")
            }
        }
        .padding(.vertical, 2)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
