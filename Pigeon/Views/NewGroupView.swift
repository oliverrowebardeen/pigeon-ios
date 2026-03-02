import SwiftUI

struct NewGroupView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var groupName = ""
    @State private var selectedMembers = Set<Data>()
    @State private var isCreating = false
    @State private var errorText: String?

    private var candidates: [Peer] {
        coordinator.candidatePeersForNewGroup()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                List {
                    Section("Group") {
                        TextField("Group name", text: $groupName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .listRowBackground(PigeonTheme.surface)
                    }

                    Section("Members") {
                        if candidates.isEmpty {
                            Text("No peers available yet. Start direct chats or discover nearby peers first.")
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
                                        if selectedMembers.contains(peer.publicKey) {
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

                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(PigeonTheme.captionFont)
                                .foregroundColor(PigeonTheme.error)
                                .listRowBackground(PigeonTheme.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Group")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isCreating ? "Creating..." : "Create") {
                        createGroup()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !selectedMembers.isEmpty &&
            !isCreating
    }

    private func toggle(_ key: Data) {
        if selectedMembers.contains(key) {
            selectedMembers.remove(key)
        } else {
            selectedMembers.insert(key)
        }
    }

    private func createGroup() {
        guard canCreate else { return }
        isCreating = true
        errorText = nil

        Task {
            do {
                _ = try await coordinator.createGroup(name: groupName, memberPublicKeys: Array(selectedMembers))
                dismiss()
            } catch {
                errorText = "Could not create group. Check member count and try again."
            }
            isCreating = false
        }
    }
}
