import SwiftUI

/// Capture tab: voice memos and glasses video behind a segmented control.
public struct MediaView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case voice = "Voice"
        case video = "Video"
        var id: String { rawValue }
    }

    @Bindable var recording: RecordingViewModel
    @Bindable var video: VideoRecordingViewModel
    /// Forwards a Media video into Ivy's Garden Walk.
    var onShareVideoToIvy: ((URL) -> Void)?
    @State private var segment: Segment = .voice

    public init(
        recording: RecordingViewModel,
        video: VideoRecordingViewModel,
        onShareVideoToIvy: ((URL) -> Void)? = nil
    ) {
        self.recording = recording
        self.video = video
        self.onShareVideoToIvy = onShareVideoToIvy
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .voice:
                    RecordingsView(recording: recording, embedded: true)
                case .video:
                    VideoRecordingsView(
                        video: video,
                        embedded: true,
                        onShareToIvy: onShareVideoToIvy
                    )
                }
            }
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Media", selection: $segment) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
        }
    }
}
