import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    @State private var showingResetSuccess = false
    @State private var mascotPeekID = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo Access") {
                    LabeledContent("Status", value: permissionLabel)
                    if appModel.permission == .limited {
                        Button("Choose More Photos") { appModel.presentLimitedLibraryPicker() }
                    }
                    Button("Open iOS Settings") { appModel.openSystemSettings() }
                }
                Section("Privacy") {
                    Label("Roll Slash stores decisions, cleanup totals, cached place names, and photo analysis results on this iPhone.", systemImage: "iphone")
                    Label("Type detection runs on this iPhone without iCloud downloads or text recognition. Images are not stored.", systemImage: "sparkles")
                    Label("Photos are not kept in app storage. Sharing a video creates a temporary copy that is removed after sharing.", systemImage: "photo.on.rectangle")
                    Label("Only Photos, iCloud, and Maps use the network.", systemImage: "network")
                }
                Section("Cleanup History") {
                    Button("Reset Cleanup History", role: .destructive) {
                        showingResetSuccess = false
                        confirmingReset = true
                    }
                    .disabled(appModel.activeSession?.status == .deleting)
                    .fullScreenCover(isPresented: $confirmingReset, onDismiss: { showingResetSuccess = false }) {
                        PopupModal {
                            if showingResetSuccess {
                                VStack(alignment: .leading, spacing: 14) {
                                    Label("Cleanup history reset", systemImage: "checkmark.circle.fill")
                                        .font(.headline)
                                        .foregroundStyle(RollSlashTheme.keep)
                                    Text("Your Photos library was not changed.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Spacer()
                                        Button("Done") {
                                            showingResetSuccess = false
                                            confirmingReset = false
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .foregroundStyle(.white)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("Reset cleanup history?")
                                        .font(.headline)
                                    Text("Your Photos library will not change.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    PopupActionRow {
                                        Button("Keep History") { confirmingReset = false }
                                            .buttonStyle(.bordered)
                                    } confirm: {
                                        Button("Reset History", role: .destructive) {
                                            Task {
                                                if await appModel.resetHistory() {
                                                    showingResetSuccess = true
                                                } else {
                                                    confirmingReset = false
                                                }
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(RollSlashTheme.coral)
                                    }
                                }
                            }
                        }
                    }
                    Text("This forgets kept decisions, cleaned badges, and cleanup totals. It never deletes media from Photos.")
                        .font(.caption)
                }
                Section("Lifetime Cleanup") {
                    LabeledContent("Items removed", value: "\(appModel.lifetimeCleanupSummary.itemCount)")
                    LabeledContent(
                        "Estimated storage (pending recovery)",
                        value: appModel.lifetimeCleanupSummary.formattedEstimatedStorage
                    )
                    if appModel.lifetimeCleanupSummary.unavailableEstimateCount > 0 {
                        Text("Storage estimate unavailable for \(appModel.lifetimeCleanupSummary.unavailableEstimateCount) items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Estimate only. Some sizes aren't available, and deleted items may stay in Recently Deleted. Totals start with this version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, 32)

                        ZStack(alignment: .topTrailing) {
                            AboutMascotPeek(actionID: mascotPeekID)
                                .offset(x: -8, y: -38)
                                .zIndex(0)

                            VStack(spacing: 0) {
                                Button {
                                    mascotPeekID &+= 1
                                } label: {
                                    LabeledContent("Roll Slash", value: "1.4")
                                        .padding(.horizontal, 32)
                                        .frame(minHeight: 56)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityElement(children: .combine)
                                .buttonStyle(.plain)

                                Divider()
                                    .padding(.horizontal, 32)

                                Link("Built with 💜 by Miickiie", destination: URL(string: "https://www.instagram.com/miiickiie")!)
                                    .padding(.horizontal, 32)
                                    .frame(minHeight: 56)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .zIndex(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Roll Slash", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { appModel.errorMessage = nil }
            } message: {
                Text(appModel.errorMessage ?? "")
            }
        }
    }

    private var permissionLabel: String {
        switch appModel.permission {
        case .notDetermined: String(localized: "Not requested")
        case .denied: String(localized: "Denied")
        case .restricted: String(localized: "Restricted")
        case .limited: String(localized: "Selected photos")
        case .full: String(localized: "Full access")
        }
    }
}

private struct AboutMascotPeek: View {
    let actionID: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        RollSlashMascotFace()
            .offset(y: isVisible ? 0 : 60)
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onChange(of: actionID) { _, _ in
                reveal()
            }
            .onDisappear {
                hideTask?.cancel()
                isVisible = false
            }
    }

    private func reveal() {
        hideTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)) {
            isVisible = true
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
                isVisible = false
            }
        }
    }
}
