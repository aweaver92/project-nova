import SwiftUI
import NovaDomain

/// Sage-exclusive wellness space. Deliberately calm: soft sage-green wash,
/// rounded serif accents, mood faces, and an animated breathing circle —
/// the visual opposite of Max's high-energy HUD.
public struct SageWellnessView: View {
    @Bindable var wellness: SageWellnessViewModel
    var embedded: Bool = false

    @State private var breathePhase = false

    private static let sage = Color(red: 0.35, green: 0.55, blue: 0.45)
    private static let sageSoft = Color(red: 0.35, green: 0.55, blue: 0.45).opacity(0.12)

    private static let moodFaces = ["😔", "😕", "😐", "🙂", "😊"]
    private static let moodWords = ["Low", "Meh", "Okay", "Good", "Great"]

    public init(wellness: SageWellnessViewModel, embedded: Bool = false) {
        self.wellness = wellness
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 20) {
                greetingHeader
                moodCard
                breatheCard
                journalStrip
                if !wellness.statusMessage.isEmpty {
                    Text(wellness.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(Self.sage)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Self.sageSoft.ignoresSafeArea())
        .navigationTitle("Wellness")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Self.sage)
        .task { await wellness.load() }
    }

    private var greetingHeader: some View {
        VStack(spacing: 6) {
            Text(greeting)
                .font(.system(.title2, design: .serif).weight(.medium))
            Text(wellness.averageMoodLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default: return "Winding down."
        }
    }

    // MARK: - Mood

    private var moodCard: some View {
        VStack(spacing: 14) {
            Text("How are you feeling right now?")
                .font(.system(.headline, design: .serif))
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { mood in
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            wellness.draftMood = mood
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(Self.moodFaces[mood - 1])
                                .font(.system(size: wellness.draftMood == mood ? 34 : 26))
                            Text(Self.moodWords[mood - 1])
                                .font(.caption2)
                                .foregroundStyle(wellness.draftMood == mood ? Self.sage : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            wellness.draftMood == mood ? Self.sage.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Anything on your mind? (optional)", text: $wellness.draftNote, axis: .vertical)
                .lineLimit(2...4)
                .padding(10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
            Button {
                Task { await wellness.logCheckin() }
            } label: {
                Text("Check in")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Breathing

    private var breatheCard: some View {
        VStack(spacing: 14) {
            Text("Take a moment")
                .font(.system(.headline, design: .serif))
            ZStack {
                Circle()
                    .fill(Self.sage.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .scaleEffect(breathePhase ? 1.25 : 0.85)
                    .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: breathePhase)
                Circle()
                    .fill(Self.sage.opacity(0.3))
                    .frame(width: 70, height: 70)
                    .scaleEffect(breathePhase ? 1.15 : 0.9)
                    .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: breathePhase)
                Image(systemName: "leaf.fill")
                    .font(.title2)
                    .foregroundStyle(Self.sage)
            }
            .frame(height: 150)
            .onAppear { breathePhase = true }
            HStack(spacing: 12) {
                breatheButton("1 min breath", icon: "wind", seconds: 60)
                breatheButton("3 min scan", icon: "figure.mind.and.body", seconds: 180)
            }
            Text("Timers chime gently when done — the same path Sage uses by voice.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func breatheButton(_ title: String, icon: String, seconds: Int) -> some View {
        Button {
            Task { await wellness.startBreathingTimer(seconds: seconds) }
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Journal

    @ViewBuilder
    private var journalStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your journey")
                .font(.system(.headline, design: .serif))
            if wellness.recent.isEmpty {
                Text("No check-ins yet. This space fills in as you go — no pressure.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                moodSparkline
                ForEach(wellness.recent.prefix(6)) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(Self.moodFaces[max(0, min(4, entry.mood - 1))])
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.dateLabel(entry.at))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let note = entry.note, !note.isEmpty {
                                Text(note)
                                    .font(.subheadline)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    /// Tiny 14-day mood trend drawn from recent check-ins (newest on the right).
    private var moodSparkline: some View {
        let points = Array(wellness.recent.prefix(14)).reversed().map { CGFloat($0.mood) }
        return GeometryReader { geo in
            Path { path in
                guard points.count > 1 else { return }
                let stepX = geo.size.width / CGFloat(points.count - 1)
                for (idx, mood) in points.enumerated() {
                    let x = CGFloat(idx) * stepX
                    let y = geo.size.height * (1 - (mood - 1) / 4)
                    if idx == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Self.sage, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 36)
        .opacity(points.count > 1 ? 1 : 0)
    }

    private static func dateLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}
