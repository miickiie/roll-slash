import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    @State private var showingResetSuccess = false

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
                    Label("Roll Slash stores decisions and cached place names on this iPhone.", systemImage: "iphone")
                    Label("Original photos and videos are never copied into app storage.", systemImage: "photo.on.rectangle")
                    Label("Only Apple Photos, iCloud, and MapKit may use the network.", systemImage: "network")
                }
                Section("Cleanup History") {
                    Button("Reset Cleanup History", role: .destructive) {
                        showingResetSuccess = false
                        confirmingReset = true
                    }
        .disabled(appModel.activeSession?.status == .deleting)
        .popover(isPresented: $confirmingReset) {
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
                    }
                }
                .padding()
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reset cleanup history?")
                        .font(.headline)
                    Text("Your Photos library will not change.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Keep History") { confirmingReset = false }
                            .buttonStyle(.bordered)
                        Button("Reset History", role: .destructive) {
                            if appModel.resetHistory() {
                                showingResetSuccess = true
                            } else {
                                confirmingReset = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RollSlashTheme.coral)
                    }
                }
                .padding()
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
            }
        }
        Text("This forgets kept decisions and cleaned badges. It never deletes media from Photos.")
                        .font(.caption)
                }
                Section("About") {
                    LabeledContent("Roll Slash", value: "1.0")
                    Text("Built for iOS 26 and later.")
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
