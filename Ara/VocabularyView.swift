import SwiftUI

struct VocabularyView: View {
    @Bindable var store: VocabularyStore
    @State private var confirmsDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Words Yet",
                    systemImage: "character.book.closed",
                    description: Text("Correct a dictated word and confirm the suggestion, or add one yourself.")
                )
            } else {
                List {
                    ForEach($store.entries) { $entry in
                        VocabularyRow(entry: $entry) {
                            store.delete(entry)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Add Word", systemImage: "plus") {
                    store.addManualEntry()
                }
                Button("Delete All", systemImage: "trash", role: .destructive) {
                    confirmsDeleteAll = true
                }
                .disabled(store.entries.isEmpty)
                Spacer()
                Text("\(store.entries.filter(\.isActive).count) active, \(store.entries.count) total")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 360)
        .onDisappear { store.removeEmptyEntries() }
        .confirmationDialog(
            "Delete all \(store.entries.count) words?",
            isPresented: $confirmsDeleteAll
        ) {
            Button("Delete All", role: .destructive) {
                store.deleteAll()
            }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

private struct VocabularyRow: View {
    @Binding var entry: VocabularyEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Enabled", isOn: $entry.isEnabled)
                .labelsHidden()

            TextField("Heard", text: $entry.heard)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("Written as", text: $entry.replacement)

            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
        }
        .textFieldStyle(.roundedBorder)
    }
}

/// The small window that announces a vocabulary change and applies it when
/// the countdown ends, unless the user cancels. Styled like the recording
/// pill: dark, with white text.
struct VocabularyProposalView: View {
    let proposals: [VocabularyProposal]
    let onCancel: (VocabularyProposal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(proposals) { proposal in
                if proposal.id != proposals.first?.id {
                    Divider()
                        .overlay(.white.opacity(0.15))
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Runs from the deadline, so the countdown stays right when
                    // another proposal arrives and the window is rebuilt.
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        let remaining = max(0, proposal.deadline.timeIntervalSince(timeline.date))
                        let total = Double(VocabularyProposal.countdown.components.seconds)
                        let action = proposal.kind == .add ? "Adding to vocabulary" : "Removing from vocabulary"

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(action) in \(Int(remaining.rounded(.up))) s")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .monospacedDigit()

                            Text("\(proposal.heard) → \(proposal.replacement)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)

                            Capsule()
                                .fill(.white.opacity(0.14))
                                .frame(height: 3)
                                .overlay(alignment: .leading) {
                                    GeometryReader { geometry in
                                        Capsule()
                                            .fill(.white)
                                            .frame(width: geometry.size.width * min(1, remaining / total))
                                    }
                                }
                                .padding(.top, 4)
                        }
                    }

                    Button("Cancel") { onCancel(proposal) }
                        .buttonStyle(CancelButtonStyle())
                        .padding(.top, 8)
                }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 18))
    }
}

/// Drawn by hand because the panel never becomes the key window, and system
/// buttons look disabled in a window that is not key.
private struct CancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.white.opacity(0.14), in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.capsule)
    }
}
