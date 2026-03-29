import Foundation
import Combine
import SwiftUI

class GroupStore: ObservableObject {
    @Published var groups: [Group] = []
    @Published var retentionDays: Int = 2

    private let saveKey = "pulse_groups_v3"

    init() { load() }

    struct StoreDTO: Codable {
        var groups: [Group]
        var retentionDays: Int
    }

    // MARK: - Persistence
    func save() {
        let dto = StoreDTO(groups: groups, retentionDays: retentionDays)
        if let data = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode(StoreDTO.self, from: data) {
            groups = decoded.groups
            retentionDays = decoded.retentionDays
            return
        }
        
        // Migration from v2
        if let data = UserDefaults.standard.data(forKey: "pulse_groups_v2"),
           let decoded = try? JSONDecoder().decode([Group].self, from: data) {
            groups = decoded
            retentionDays = 2
        }
    }

    // MARK: - Group CRUD
    func addGroup(name: String) {
        groups.append(Group(name: name))
        save()
    }

    func deleteGroup(at offsets: IndexSet) {
        groups.remove(atOffsets: offsets)
        save()
    }

    func updateGroup(_ group: Group) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
            save()
        }
    }

    // MARK: - Endpoint CRUD
    func addEndpoint(_ endpoint: EndpointItem, to groupId: UUID) {
        if let idx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[idx].endpoints.append(endpoint)
            save()
        }
    }

    func deleteEndpoint(groupId: UUID, at offsets: IndexSet) {
        if let idx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[idx].endpoints.remove(atOffsets: offsets)
            save()
        }
    }

    func updateEndpoint(_ endpoint: EndpointItem, in groupId: UUID) {
        if let gIdx = groups.firstIndex(where: { $0.id == groupId }),
           let eIdx = groups[gIdx].endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            groups[gIdx].endpoints[eIdx] = endpoint
            save()
        }
    }

    // MARK: - Health record update
    func recordHealth(groupId: UUID, endpointId: UUID, record: HealthRecord) {
        guard let gIdx = groups.firstIndex(where: { $0.id == groupId }),
              let eIdx = groups[gIdx].endpoints.firstIndex(where: { $0.id == endpointId }) else { return }
        groups[gIdx].endpoints[eIdx].addRecord(record, retentionDays: retentionDays)
        groups[gIdx].endpoints[eIdx].currentStatus = record.status
        groups[gIdx].endpoints[eIdx].lastChecked = record.timestamp
        save()
    }

    func group(for id: UUID) -> Group? {
        groups.first(where: { $0.id == id })
    }
}
