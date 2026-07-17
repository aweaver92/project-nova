import SwiftUI

/// A single line item within a release's patch notes.
public struct PatchNoteEntry: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case feature = "New"
        case improvement = "Improved"
        case fix = "Fixed"

        var tint: Color {
            switch self {
            case .feature: return .green
            case .improvement: return .blue
            case .fix: return .orange
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    public let text: String
    /// When true, this item is something you can actively try out in this build.
    public let testable: Bool

    public init(kind: Kind, text: String, testable: Bool = false) {
        self.kind = kind
        self.text = text
        self.testable = testable
    }
}

/// One released (or in-test) version and its changes.
public struct PatchNote: Identifiable, Sendable {
    public var id: String { version }
    public let version: String
    public let date: String
    public let summary: String?
    public let entries: [PatchNoteEntry]

    public init(version: String, date: String, summary: String? = nil, entries: [PatchNoteEntry]) {
        self.version = version
        self.date = date
        self.summary = summary
        self.entries = entries
    }
}

public extension PatchNote {
    /// The changelog. Newest first — add a new entry at the top for each build.
    static let all: [PatchNote] = [
        PatchNote(
            version: "0.3.0",
            date: "Jul 17, 2026",
            summary: "Redesigned companion UI. Nova now complements Meta AI instead of replacing it.",
            entries: [
                PatchNoteEntry(
                    kind: .improvement,
                    text: "Refreshed home screen: a clear connection-status panel, a one-tap listening control, and chat-style transcripts.",
                    testable: true
                ),
                PatchNoteEntry(
                    kind: .improvement,
                    text: "Glasses controls are now contextual — you only see the actions that make sense for the current state.",
                    testable: true
                ),
                PatchNoteEntry(
                    kind: .improvement,
                    text: "Hid the in-app camera / “what am I looking at?” tools. Those are handled natively by “Hey Meta,” so Nova now focuses on being your voice companion.",
                    testable: true
                ),
            ]
        ),
        PatchNote(
            version: "0.2.0",
            date: "Jul 17, 2026",
            summary: "Voice quality overhaul and this Patch Notes tab.",
            entries: [
                PatchNoteEntry(
                    kind: .improvement,
                    text: "Echo cancellation, noise suppression, and automatic gain control are now enabled on the glasses mic for clearer, more consistent voice capture.",
                    testable: true
                ),
                PatchNoteEntry(
                    kind: .improvement,
                    text: "New anti-aliased audio resampler removes the harshness/buzz that the old converter folded into speech on the 8 kHz ↔ 24 kHz path.",
                    testable: true
                ),
                PatchNoteEntry(
                    kind: .improvement,
                    text: "Server-side input noise reduction (near-field) improves turn detection and transcription in noisy environments.",
                    testable: true
                ),
                PatchNoteEntry(
                    kind: .improvement,
                    text: "Tuned playback buffering for steadier, lower-latency audio with fewer dropouts.",
                    testable: true
                ),
                PatchNoteEntry(
                    kind: .feature,
                    text: "Added this Patch Notes tab so you can always see the latest updates and what's ready to test.",
                    testable: true
                ),
            ]
        ),
        PatchNote(
            version: "0.1.0",
            date: "Initial build",
            summary: "First end-to-end Nova assistant.",
            entries: [
                PatchNoteEntry(kind: .feature, text: "Hands-free voice conversations over Meta Ray-Ban glasses with wake-word (\"Nova\") activation."),
                PatchNoteEntry(kind: .feature, text: "Live vision: ask \"what am I looking at?\" to have Nova describe the current camera view."),
                PatchNoteEntry(kind: .feature, text: "Barge-in support to interrupt Nova mid-answer."),
                PatchNoteEntry(kind: .feature, text: "Cross-session memory so Nova remembers recent context."),
            ]
        ),
    ]
}

public struct PatchNotesView: View {
    private let notes: [PatchNote]
    private let installedVersion: String

    public init(notes: [PatchNote] = PatchNote.all,
                installedVersion: String = PatchNotesView.bundleVersion()) {
        self.notes = notes
        self.installedVersion = installedVersion
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(notes) { note in
                    Section {
                        if let summary = note.summary {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(note.entries) { entry in
                            PatchNoteRow(entry: entry)
                        }
                    } header: {
                        HStack {
                            Text("Version \(note.version)")
                            Spacer()
                            Text(note.date).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Patch Notes")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("Installed: v\(installedVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
            }
        }
    }

    /// Reads the app's version/build from the bundle for the "Installed" footer.
    public static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.3.0"
        if let build = info?["CFBundleVersion"] as? String {
            return "\(short) (\(build))"
        }
        return short
    }
}

private struct PatchNoteRow: View {
    let entry: PatchNoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.kind.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.kind.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(entry.kind.tint)
                if entry.testable {
                    Text("AVAILABLE TO TEST")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 0)
            }
            Text(entry.text)
                .font(.footnote)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
