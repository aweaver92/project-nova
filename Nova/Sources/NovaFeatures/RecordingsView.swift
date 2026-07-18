import SwiftUI
import AVFoundation
import NovaDomain

/// Voice-memo tab: lists recordings saved to the iPhone with in-app playback,
/// export/share and swipe-to-delete. The same recorder + store back Nova's
/// `start_voice_recording` / `stop_voice_recording` tools, so memos captured by
/// voice ("Nova, begin voice recording") appear here alongside ones started from
/// the button.
public struct RecordingsView: View {
    @Bindable var recording: RecordingViewModel
    var embedded: Bool
    @State private var player = RecordingPlayer()
    @State private var confirmClear = false

    public init(recording: RecordingViewModel, embedded: Bool = false) {
        self.recording = recording
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Recordings")
                }
            }
        }
    }

    private var content: some View {
        Group {
            if recording.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text("Record from Assistant, or say “Nova, begin voice recording”.")
                }
            } else {
                List {
                    ForEach(recording.recordings) { item in
                        RecordingRow(item: item, url: recording.fileURL(for: item), player: player)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { recording.recordings[$0].id }
                        if let playing = player.playingID, ids.contains(playing) { player.stop() }
                        Task { await recording.delete(at: offsets) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !recording.recordings.isEmpty {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete all recordings")
                }
            }
        }
        .novaConfirmClear(
            isPresented: $confirmClear,
            title: "Delete all recordings?",
            message: "This permanently removes every voice memo from this iPhone."
        ) {
            player.stop()
            Task { await recording.clear() }
        }
        .task { await recording.load() }
        .onDisappear { player.stop() }
    }
}

private struct RecordingRow: View {
    let item: VoiceRecording
    let url: URL?
    @Bindable var player: RecordingPlayer

    private var isActive: Bool { player.playingID == item.id }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if let url {
                    Button {
                        player.toggle(id: item.id, url: url)
                    } label: {
                        Image(systemName: isActive && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isActive && player.isPlaying ? "Pause recording" : "Play recording")
                }

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

            if isActive {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.01)
                    )
                    HStack {
                        Text(Self.duration(player.currentTime))
                        Spacer()
                        Text(Self.duration(player.duration))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Lightweight `AVAudioPlayer` wrapper for previewing recordings in the app.
///
/// Intentionally does **not** touch `AVAudioSession` — the app's
/// `AudioSessionCoordinator` owns the category/mode/route — so this just plays
/// through whatever route is currently active.
@MainActor
@Observable
final class RecordingPlayer: NSObject {
    private(set) var playingID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var avPlayer: AVAudioPlayer?
    private var ticker: Timer?

    /// Play the recording if it isn't the active one; otherwise pause/resume it.
    func toggle(id: UUID, url: URL) {
        if playingID == id {
            if isPlaying { pause() } else { resume() }
            return
        }
        start(id: id, url: url)
    }

    private func start(id: UUID, url: URL) {
        stop()
        do {
            let avPlayer = try AVAudioPlayer(contentsOf: url)
            avPlayer.delegate = self
            avPlayer.prepareToPlay()
            self.avPlayer = avPlayer
            playingID = id
            duration = avPlayer.duration
            currentTime = 0
            avPlayer.play()
            isPlaying = true
            startTicker()
        } catch {
            stop()
        }
    }

    private func resume() {
        guard let avPlayer else { return }
        avPlayer.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        avPlayer?.pause()
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        guard let avPlayer else { return }
        let clamped = min(max(0, time), avPlayer.duration)
        avPlayer.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        stopTicker()
        avPlayer?.stop()
        avPlayer = nil
        playingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let avPlayer = self.avPlayer else { return }
                self.currentTime = avPlayer.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
