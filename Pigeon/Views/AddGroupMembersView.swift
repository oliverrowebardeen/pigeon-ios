import SwiftUI

struct AddGroupMembersView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID
    let existingMembers: [Data]

    @State private var selected = Set<Data>()
    @State private var pendingError: String?
    @State private var isSubmitting = false

    private var candidates: [Peer] {
        let existingSet = Set(existingMembers)
        return coordinator.candidatePeersForNewGroup()
            .filter { !existingSet.contains($0.publicKey) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                List {
                    Section("Add Members") {
                        if candidates.isEmpty {
                            Text("No available peers to add.")
                                .font(PigeonTheme.captionFont)
                                .foregroundColor(PigeonTheme.textSecondary)
                                .listRowBackground(PigeonTheme.surface)
                        } else {
                            ForEach(candidates) { peer in
                                Button {
                                    toggle(peer.publicKey)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(peer.displayName ?? peer.pigeonID)
                                                .foregroundColor(PigeonTheme.textPrimary)
                                            Text(peer.pigeonID)
                                                .font(PigeonTheme.captionFont)
                                                .foregroundColor(PigeonTheme.textSecondary)
                                        }
                                        Spacer()
                                        if selected.contains(peer.publicKey) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(PigeonTheme.accent)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(PigeonTheme.surface)
                            }
                        }
                    }

                    if let pendingError {
                        Section {
                            Text(pendingError)
                                .font(PigeonTheme.captionFont)
                                .foregroundColor(PigeonTheme.error)
                                .listRowBackground(PigeonTheme.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Members")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "Adding..." : "Add") {
                        addMembers()
                    }
                    .disabled(selected.isEmpty || isSubmitting)
                }
            }
        }
    }

    private func toggle(_ key: Data) {
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }

    private func addMembers() {
        guard !selected.isEmpty else { return }
        isSubmitting = true
        pendingError = nil

        Task {
            do {
                try await coordinator.updateGroupMembers(groupID: groupID, add: Array(selected), remove: [])
                dismiss()
            } catch {
                pendingError = "Could not add selected members."
            }
            isSubmitting = false
        }
    }
}
