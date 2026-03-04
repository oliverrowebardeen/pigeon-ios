import SwiftUI

struct GroupDetailsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID

    @State private var members: [GroupMember] = []
    @State private var showAddSheet = false
    @State private var showInviteQR = false
    @State private var pendingError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                List {
                    Section("Group") {
                        HStack {
                            Text("ID")
                            Spacer()
                            Text(groupID.uuidString.prefix(8))
                                .font(PigeonTheme.monoFont)
                                .foregroundColor(PigeonTheme.textSecondary)
                        }
                        .listRowBackground(PigeonTheme.surface)

                        HStack {
                            Text("Members")
                            Spacer()
                            Text("\(activeMembers.count)")
                                .foregroundColor(PigeonTheme.textSecondary)
                        }
                        .listRowBackground(PigeonTheme.surface)
                    }

                    Section("Members") {
                        ForEach(activeMembers, id: \.id) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.displayName ?? member.pigeonID)
                                        .foregroundColor(PigeonTheme.textPrimary)
                                    Text(member.pigeonID)
                                        .font(PigeonTheme.captionFont)
                                        .foregroundColor(PigeonTheme.textSecondary)
                                }
                                Spacer()
                                Text(member.role == .owner ? "Owner" : "Member")
                                    .font(PigeonTheme.captionFont)
                                    .foregroundColor(PigeonTheme.textSecondary)

                                if canRemove(member: member) {
                                    Button(role: .destructive) {
                                        remove(member)
                                    } label: {
                                        Image(systemName: "person.fill.xmark")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, 8)
                                }
                            }
                            .listRowBackground(PigeonTheme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canRemove(member: member) {
                                    Button("Remove", role: .destructive) {
                                        remove(member)
                                    }
                                }
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
            .navigationTitle("Group Details")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isOwner {
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }

                        Button {
                            showInviteQR = true
                        } label: {
                            Image(systemName: "qrcode")
                        }
                    }
                }
            }
            .task {
                reloadMembers()
            }
            .sheet(isPresented: $showAddSheet) {
                AddGroupMembersView(groupID: groupID, existingMembers: activeMembers.map(\.publicKey))
                    .environment(coordinator)
                    .onDisappear {
                        reloadMembers()
                    }
            }
            .sheet(isPresented: $showInviteQR) {
                GroupInviteQRCodeView(groupID: groupID)
                    .environment(coordinator)
            }
        }
    }

    private var activeMembers: [GroupMember] {
        members.filter(\.isActive)
    }

    private var isOwner: Bool {
        coordinator.isCurrentUserGroupOwner(groupID: groupID)
    }

    private func canRemove(member: GroupMember) -> Bool {
        isOwner && member.role != .owner
    }

    private func remove(_ member: GroupMember) {
        Task {
            do {
                try await coordinator.updateGroupMembers(groupID: groupID, add: [], remove: [member.publicKey])
                reloadMembers()
            } catch {
                pendingError = "Failed to remove member."
            }
        }
    }

    private func reloadMembers() {
        members = (try? coordinator.groupMembers(groupID: groupID)) ?? []
    }
}
