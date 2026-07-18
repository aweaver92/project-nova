import SwiftUI
import AVKit
import NovaDomain

/// Video tab: lists videos captured from the glasses camera with in-app
/// playback, export/share and swipe-to-delete. The same recorder + store back
/// Nova's `start_video_recording` / `stop_video_recording` tools, so videos
/// captured by voice ("Nova, record a video") appear here alongside ones started
/// from the button.
public struct VideoRecordingsView: View {
    @Bindable var video: VideoRecordingViewModel
    var embedded: Bool
    @State private var confirmClear = false

    public init(video: VideoRecordingViewModel, embedded: Bool = false) {
        self.video = video
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Videos")
                }
            }
        }
    }

    private var content: some View {
        Group {
            if video.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Videos", systemImage: "video.slash")
                } description: {
                    Text("Tap record, or say “Nova, record a video”.")
                }
            } else {
                List {
                    ForEach(video.recordings) { item in
                        NavigationLink {
                            VideoPlayerScreen(url: video.fileURL(for: item), title: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        } label: {
                            VideoRow(item: item, url: video.fileURL(for: item))
                        }
                    }
                    .onDelete { offsets in
                        Task { await video.delete(at: offsets) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await video.toggle() }
                } label: {
                    Image(systemName: video.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(video.isRecording ? .red : .accentColor)
                .accessibilityLabel(video.isRecording ? "Stop video recording" : "Start video recording")
            }
            ToolbarItem(placement: .topBarLeading) {
                if !video.recordings.isEmpty {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete all videos")
                }
            }
        }
        .novaConfirmClear(
            isPresented: $confirmClear,
            title: "Delete all videos?",
            message: "This permanently removes every glasses video from this iPhone."
        ) {
            Task { await video.clear() }
        }
        .safeAreaInset(edge: .bottom) {
            if video.isRecording, let startedAt = video.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Label(
                        "Recording… \(Self.elapsed(from: startedAt, to: context.date))",
                        systemImage: "video.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red, in: Capsule())
                    .padding(.bottom, 8)
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = video.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .task { await video.load() }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VideoRow: View {
    let item: VideoRecording
    let url: URL?

    var body: some View {
        HStack {
            Image(systemName: "video.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
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
                .accessibilityLabel("Share or save video")
            }
        }
        .padding(.vertical, 2)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VideoPlayerScreen: View {
    let url: URL?
    let title: String

    var body: some View {
        Group {
            if let url {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Video unavailable", systemImage: "video.slash")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
