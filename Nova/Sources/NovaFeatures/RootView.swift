import SwiftUI
import NovaDomain

public struct RootView: View {
    @Bindable var session: SessionViewModel
    @Bindable var conversation: ConversationViewModel
    @Bindable var vision: VisionViewModel
    @Bindable var notes: NotesViewModel

    public init(
        session: SessionViewModel,
        conversation: ConversationViewModel,
        vision: VisionViewModel,
        notes: NotesViewModel
    ) {
        self.session = session
        self.conversation = conversation
        self.vision = vision
        self.notes = notes
    }

    public var body: some View {
        TabView {
            assistantTab
                .tabItem { Label("Assistant", systemImage: "waveform") }

            PatchNotesView()
                .tabItem { Label("Patch Notes", systemImage: "sparkles") }
        }
    }

    private var assistantTab: some View {
        NavigationStack {
            List {
                Section {
                    // Logo asset ships in the app bundle (App/Assets.xcassets),
                    // so it resolves against Bundle.main from this package view.
                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 160)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Nova — AI Assistant for Meta Glasses")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section("Glasses session") {
                    LabeledContent("Registration", value: session.registrationState.rawValue)
                    LabeledContent("Session", value: session.sessionState.rawValue)
                    Button("Register with Meta AI") { Task { await session.register() } }
                    Button("Start session") { Task { await session.startSession() } }
                    Button("Pause") { Task { await session.pause() } }
                    Button("Resume") { Task { await session.resume() } }
                    Button("End session") { Task { await session.endSession() } }
                    if let error = session.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Conversation") {
                    Button(conversation.isRunning ? "Stop voice" : "Start voice") {
                        Task {
                            if conversation.isRunning { await conversation.stop() }
                            else { await conversation.start() }
                        }
                    }
                    Button("Barge-in") { Task { await conversation.bargeIn() } }
                        .disabled(!conversation.isRunning)
                    Text(conversation.latencyHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(Array(conversation.transcriptLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote)
                    }
                    if let error = conversation.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Vision") {
                    Button("Capture still") { Task { await vision.captureStill() } }
                    Button("What am I looking at?") {
                        Task { await vision.askAboutView(prompt: "What am I looking at? Be concise.") }
                    }
                    if !vision.lastAnswer.isEmpty {
                        Text(vision.lastAnswer)
                    }
                    if let error = vision.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Notes") {
                    Button("Refresh notes") { Task { await notes.load() } }
                    if !notes.notes.isEmpty {
                        ShareLink(item: notes.exportText) {
                            Label("Export notes", systemImage: "square.and.arrow.up")
                        }
                        Button("Clear notes", role: .destructive) { Task { await notes.clear() } }
                    }
                    ForEach(notes.notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text).font(.footnote)
                            Text(note.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if notes.notes.isEmpty {
                        Text("Say “Nova, take a note …” to capture one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Nova")
            .navigationBarTitleDisplayMode(.inline)
            // Auto-start listening when Nova opens so you can pocket the phone
            // and use the wake word hands-free (the `audio` background mode keeps
            // the glasses mic session alive while the screen is locked).
            .task {
                await notes.load()
                if !conversation.isRunning {
                    await conversation.start()
                }
            }
        }
    }
}
