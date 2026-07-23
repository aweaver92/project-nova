import SwiftUI
import NovaDomain

/// Scholar-exclusive study space. "Library desk" identity: indigo ink, serif
/// headings, index-card review with a flip animation, and a deck grid that
/// reads like a card catalog — distinct from the other specialist screens.
public struct StudyView: View {
    @Bindable var study: StudyViewModel
    @Bindable var conversation: ConversationViewModel
    var embedded: Bool
    @State private var editingCard: StudyCard?
    @State private var showNewCard = false

    static let ink = Color(red: 0.30, green: 0.30, blue: 0.65)
    private static let inkSoft = Color(red: 0.30, green: 0.30, blue: 0.65).opacity(0.10)

    public init(study: StudyViewModel, conversation: ConversationViewModel, embedded: Bool = false) {
        self.study = study
        self.conversation = conversation
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
            VStack(spacing: 16) {
                NovaUI.AgentVoiceChatBar(conversation: conversation)
                dueHero
                deckGrid
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Self.inkSoft.ignoresSafeArea())
        .navigationTitle("Study")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Self.ink)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewCard = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add card")
            }
        }
        .task {
            await study.load()
            await study.consumeDeepLink()
        }
        .onAppear { study.setScreenVisible(true) }
        .onDisappear { study.setScreenVisible(false) }
        .onChange(of: study.shouldPresentStudy) { _, present in
            if present {
                Task { await study.consumeDeepLink() }
            }
        }
        .sheet(item: $editingCard) { card in
            StudyCardEditorSheet(card: card) { updated in
                Task { await study.upsertCard(updated) }
            }
        }
        .sheet(isPresented: $showNewCard) {
            StudyCardEditorSheet(
                card: StudyCard(deck: study.selectedDeckName ?? "General", front: "", back: "")
            ) { created in
                Task { await study.upsertCard(created) }
            }
        }
        .sheet(isPresented: Binding(
            get: { study.isReviewing },
            set: { if !$0 { study.endReview() } }
        )) {
            NavigationStack {
                StudyReviewSessionView(study: study)
            }
            .presentationDetents([.large])
        }
    }

    // MARK: - Due hero

    private var dueHero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Self.ink.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: dueFraction)
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(study.dueTotal)")
                        .font(.system(.title2, design: .serif).weight(.bold))
                        .monospacedDigit()
                    Text("due")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: 6) {
                Text(study.dueTotal > 0 ? "Ready when you are." : "All caught up.")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                Text(study.hasDecks
                     ? "\(study.deckSummaries.count) decks · \(totalCards) cards"
                     : "Ask Scholar to make flashcards, or add one with +.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if study.dueTotal > 0 {
                    Button {
                        Task { await study.startReview() }
                    } label: {
                        Label("Start review", systemImage: "rectangle.on.rectangle.angled")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var totalCards: Int {
        study.deckSummaries.reduce(0) { $0 + $1.totalCount }
    }

    private var dueFraction: CGFloat {
        guard totalCards > 0 else { return 0 }
        return CGFloat(totalCards - study.dueTotal) / CGFloat(totalCards)
    }

    // MARK: - Deck grid

    @ViewBuilder
    private var deckGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Card catalog")
                .font(.system(.headline, design: .serif))
            if study.deckSummaries.isEmpty {
                Text("No study decks yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(study.deckSummaries) { deck in
                        NavigationLink {
                            StudyDeckDetailView(study: study, deckName: deck.name)
                        } label: {
                            deckCard(deck)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deckCard(_ deck: StudyDeckSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Self.ink)
                Spacer()
                if deck.dueCount > 0 {
                    Text("\(deck.dueCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Self.ink, in: Capsule())
                }
            }
            Spacer(minLength: 8)
            Text(deck.name)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(deck.totalCount) cards")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(height: 110, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Self.ink.opacity(deck.dueCount > 0 ? 0.35 : 0.1), lineWidth: 1)
        )
    }
}

// MARK: - Review (index-card flip)

private struct StudyReviewSessionView: View {
    @Bindable var study: StudyViewModel

    var body: some View {
        VStack(spacing: 20) {
            if let card = study.currentReviewCard {
                Text(study.reviewProgressLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                indexCard(card)
                    .onTapGesture {
                        if !study.isRevealed {
                            withAnimation(.spring(duration: 0.4)) { study.revealCurrent() }
                        }
                    }

                if study.isRevealed {
                    HStack(spacing: 8) {
                        gradeButton("Again", grade: .again, tint: .red)
                        gradeButton("Hard", grade: .hard, tint: .orange)
                        gradeButton("Good", grade: .good, tint: .green)
                        gradeButton("Easy", grade: .easy, tint: .blue)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.4)) { study.revealCurrent() }
                    } label: {
                        Label("Flip card", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                Spacer()
            } else {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(StudyView.ink)
                Text("Review complete.")
                    .font(.system(.title3, design: .serif))
                Button("Done") { study.endReview() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding(.top, 20)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .tint(StudyView.ink)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("End") { study.endReview() }
            }
        }
    }

    /// Ruled index card; back side revealed with a horizontal flip.
    private func indexCard(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.deck)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyView.ink)
                Spacer()
                Text(study.isRevealed ? "ANSWER" : "QUESTION")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            Divider()
                .overlay(StudyView.ink.opacity(0.4))
            Text(study.isRevealed ? card.back : card.front)
                .font(.system(.title3, design: .serif))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scaleEffect(x: study.isRevealed ? -1 : 1, y: 1)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(StudyView.ink.opacity(0.25), lineWidth: 1)
        )
        .rotation3DEffect(
            .degrees(study.isRevealed ? 180 : 0),
            axis: (x: 0, y: 1, z: 0)
        )
        .scaleEffect(x: study.isRevealed ? -1 : 1, y: 1)
        .padding(.horizontal)
    }

    private func gradeButton(_ title: String, grade: StudyGrade, tint: Color) -> some View {
        Button(title) {
            Task { await study.gradeCurrent(grade) }
        }
        .tint(tint)
        .frame(maxWidth: .infinity)
    }
}

private struct StudyDeckDetailView: View {
    @Bindable var study: StudyViewModel
    let deckName: String
    @State private var editingCard: StudyCard?

    var body: some View {
        List {
            Section {
                let due = study.deckSummaries.first { $0.name == deckName }?.dueCount ?? 0
                if due > 0 {
                    Button {
                        Task { await study.startReview(deck: deckName) }
                    } label: {
                        Label("Review \(due) due", systemImage: "rectangle.on.rectangle.angled")
                            .font(.subheadline.weight(.semibold))
                    }
                } else {
                    Text("Nothing due in this deck.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cards") {
                if study.selectedDeckCards.isEmpty {
                    Text("No cards.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(study.selectedDeckCards) { card in
                        Button {
                            editingCard = card
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.front)
                                    .font(.system(.body, design: .serif))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(card.back)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let ids = indexSet.compactMap { study.selectedDeckCards[safe: $0]?.id }
                        Task {
                            for id in ids {
                                await study.deleteCard(id: id)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(deckName)
        .navigationBarTitleDisplayMode(.inline)
        .tint(StudyView.ink)
        .task {
            await study.selectDeck(deckName)
        }
        .sheet(item: $editingCard) { card in
            StudyCardEditorSheet(card: card) { updated in
                Task { await study.upsertCard(updated) }
            }
        }
        .sheet(isPresented: Binding(
            get: { study.isReviewing },
            set: { if !$0 { study.endReview() } }
        )) {
            NavigationStack {
                StudyReviewSessionView(study: study)
            }
            .presentationDetents([.large])
        }
    }
}

private struct StudyCardEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deck: String
    @State private var front: String
    @State private var back: String
    private let original: StudyCard
    var onSave: (StudyCard) -> Void

    init(card: StudyCard, onSave: @escaping (StudyCard) -> Void) {
        self.original = card
        self.onSave = onSave
        _deck = State(initialValue: card.deck)
        _front = State(initialValue: card.front)
        _back = State(initialValue: card.back)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Deck", text: $deck)
                TextField("Front / question", text: $front, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Back / answer", text: $back, axis: .vertical)
                    .lineLimit(2...8)
            }
            .navigationTitle(original.front.isEmpty ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var card = original
                        card.deck = deck.trimmingCharacters(in: .whitespacesAndNewlines)
                        card.front = front.trimmingCharacters(in: .whitespacesAndNewlines)
                        card.back = back.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !card.deck.isEmpty, !card.front.isEmpty, !card.back.isEmpty else { return }
                        onSave(card)
                        dismiss()
                    }
                    .disabled(
                        deck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
