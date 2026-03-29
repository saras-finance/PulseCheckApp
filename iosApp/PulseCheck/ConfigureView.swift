import SwiftUI

struct ConfigureView: View {
    @EnvironmentObject var store: GroupStore
    @EnvironmentObject var healthEngine: HealthCheckEngine
    @State private var showAddGroup = false
    @State private var editingGroup: Group? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: $store.retentionDays, in: 1...30) {
                        HStack {
                            Text("History Retention")
                            Spacer()
                            Text("\(store.retentionDays) days").foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: store.retentionDays) { _ in store.save() }

                    Button {
                        Task { await healthEngine.runAllChecksOnce() }
                    } label: {
                        HStack {
                            Label("Refresh All Statuses", systemImage: "arrow.clockwise")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Global Settings")
                } footer: {
                    Text("How many days of health history to keep on your device.")
                }

                ForEach($store.groups) { $group in
                    Section {
                        // Endpoints
                        ForEach($group.endpoints) { $endpoint in
                            EndpointConfigRow(endpoint: $endpoint, group: group)
                        }
                        .onDelete { offsets in
                            store.deleteEndpoint(groupId: group.id, at: offsets)
                        }

                        // Add endpoint button
                        NavigationLink(destination: EndpointFormView(mode: .add, groupId: group.id)) {
                            Label("Add Endpoint", systemImage: "plus.circle.fill")
                                .foregroundStyle(.tint)
                                .font(.subheadline)
                        }
                    } header: {
                        GroupSectionHeader(group: group, onEdit: { editingGroup = group }, onDelete: {
                            if let idx = store.groups.firstIndex(where: { $0.id == group.id }) {
                                store.deleteGroup(at: IndexSet(integer: idx))
                            }
                        })
                    }
                }

                Section {
                    Button(action: { showAddGroup = true }) {
                        Label("Add Group", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.medium))
                    }
                }

                Section {
                    BrandingFooter()
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Configure")
            .sheet(isPresented: $showAddGroup) {
                AddGroupSheet { name in store.addGroup(name: name) }
            }
            .sheet(item: $editingGroup) { group in
                RenameGroupSheet(group: group) { newName in
                    var updated = group
                    updated.name = newName
                    store.updateGroup(updated)
                }
            }
        }
    }
}

// MARK: - Group Section Header
struct GroupSectionHeader: View {
    let group: Group
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            StatusDot(status: group.overallStatus, size: 8)
            Text(group.name).font(.headline).foregroundStyle(.primary)
            Spacer()
            Menu {
                Button("Rename", systemImage: "pencil", action: onEdit)
                Button("Delete Group", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Endpoint Config Row
struct EndpointConfigRow: View {
    @Binding var endpoint: EndpointItem
    let group: Group
    @EnvironmentObject var store: GroupStore
    @EnvironmentObject var healthEngine: HealthCheckEngine

    var body: some View {
        NavigationLink(destination: EndpointFormView(mode: .edit(endpoint), groupId: group.id)) {
            HStack(spacing: 10) {
                StatusDot(status: endpoint.currentStatus, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.name).font(.subheadline.weight(.medium))
                    Text(endpoint.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(endpoint.cadence.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }
}

// MARK: - Add Group Sheet
struct AddGroupSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    let onAdd: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("e.g. Production APIs", text: $name)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            onAdd(name.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Rename Group Sheet
struct RenameGroupSheet: View {
    @Environment(\.dismiss) var dismiss
    let group: Group
    let onRename: (String) -> Void
    @State private var name: String

    init(group: Group, onRename: @escaping (String) -> Void) {
        self.group = group
        self.onRename = onRename
        _name = State(initialValue: group.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("Group name", text: $name)
                }
            }
            .navigationTitle("Rename Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onRename(name); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Endpoint Form
enum EndpointFormMode {
    case add
    case edit(EndpointItem)
}

struct EndpointFormView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: GroupStore
    @EnvironmentObject var healthEngine: HealthCheckEngine

    let mode: EndpointFormMode
    let groupId: UUID

    @State private var name = ""
    @State private var url = ""
    @State private var cadence: Cadence = .min1
    @State private var isCritical = false
    @State private var notificationSound: HealthSound = .standard
    @State private var urlError: String? = nil

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Endpoint Details") {
                LabeledContent("Name") {
                    TextField("My API", text: $name)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                LabeledContent("URL") {
                    TextField("https://api.example.com/health", text: $url)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                if let err = urlError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Check Cadence") {
                Picker("Interval", selection: $cadence) {
                    ForEach(Cadence.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Notification Settings") {
                Toggle(isOn: $isCritical) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Persistent Alert")
                        Text("Stay on lock screen & bypass mute switch")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                
                Picker("Alert Tone", selection: $notificationSound) {
                    ForEach(HealthSound.allCases) { sound in
                        Text(sound.rawValue).tag(sound)
                    }
                }
            }

            Section {
                Button(isEditing ? "Save Changes" : "Add Endpoint") {
                    guard validate() else { return }
                    if isEditing, case .edit(let existing) = mode {
                        var updated = existing
                        updated.name = name.trimmingCharacters(in: .whitespaces)
                        updated.url = url.trimmingCharacters(in: .whitespaces)
                        updated.cadence = cadence
                        updated.isCritical = isCritical
                        updated.notificationSound = notificationSound
                        store.updateEndpoint(updated, in: groupId)
                        // Reschedule
                        healthEngine.stopTimer(for: existing.id)
                        healthEngine.schedule(endpoint: updated, groupId: groupId)
                    } else {
                        let endpoint = EndpointItem(
                            name: name.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces),
                            cadence: cadence,
                            isCritical: isCritical,
                            notificationSound: notificationSound
                        )
                        store.addEndpoint(endpoint, to: groupId)
                        healthEngine.schedule(endpoint: endpoint, groupId: groupId)
                    }
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
            }
        }
        .navigationTitle(isEditing ? "Edit Endpoint" : "New Endpoint")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if case .edit(let ep) = mode {
                name = ep.name; url = ep.url; cadence = ep.cadence
                isCritical = ep.isCritical; notificationSound = ep.notificationSound
            }
        }
    }

    func validate() -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: trimmed), parsed.scheme != nil else {
            urlError = "Please enter a valid URL (including https://)."
            return false
        }
        urlError = nil
        return true
    }
}
