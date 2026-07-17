import SwiftUI
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

public struct CodingView: View {
    @Bindable var coding: CodingViewModel
    @State private var showSessions = false

    public init(coding: CodingViewModel) {
        self.coding = coding
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                composer
            }
            .navigationTitle("Coding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSessions = true
                    } label: {
                        Label("Sessions", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New session") {
                            Task { await coding.startNewSession() }
                        }
                        Button("Refresh") {
                            Task { await coding.refreshSessions() }
                        }
                        if coding.isRunning {
                            Button("Cancel run", role: .destructive) {
                                Task { await coding.cancel() }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSessions) {
                sessionPicker
            }
            .task { await coding.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coding.shortSessionId)
                    .font(.headline.monospaced())
                Text(coding.runStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Spacer()
            if coding.isRunning {
                ProgressView()
            }
            if let full = coding.pinnedSessionId {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = full
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy session id")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !coding.statusMessage.isEmpty && coding.items.isEmpty {
                        Text(coding.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    ForEach(coding.items) { item in
                        transcriptRow(item)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: coding.items.count) { _, _ in
                if let last = coding.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: CodingTranscriptItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
        case .assistant:
            Text(item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        case .thinking:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    coding.toggleExpand(item)
                } label: {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver")
                        Text(item.text)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if item.diff != nil {
                            Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.isExpanded, let diff = item.diff, !diff.isEmpty {
                    ScrollView(.horizontal) {
                        Text(diff)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        case .status:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        case .error:
            Text(item.text)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Prompt Cursor…", text: $coding.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(coding.isRunning)
            Button {
                Task { await coding.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(coding.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coding.isRunning)
        }
        .padding()
    }

    private var sessionPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button("New session") {
                        Task {
                            await coding.startNewSession()
                            showSessions = false
                        }
                    }
                }
                Section("Local Cursor agents") {
                    if coding.isLoading {
                        ProgressView()
                    } else if coding.sessions.isEmpty {
                        Text("No sessions. Send a prompt to create one.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coding.sessions) { session in
                            Button {
                                Task {
                                    await coding.attach(sessionId: session.id)
                                    showSessions = false
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(session.title)
                                            .foregroundStyle(.primary)
                                        if session.id == coding.pinnedSessionId {
                                            Image(systemName: "pin.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(session.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let status = session.status {
                                        Text(status)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSessions = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await coding.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await coding.refreshSessions() }
        }
    }
}
