import Foundation

// MARK: - Models

enum Cadence: Int, Codable, CaseIterable, Identifiable {
    case min1 = 1
    case mins15 = 15
    case mins30 = 30
    case mins60 = 60

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .min1: return "1 min"
        case .mins15: return "15 min"
        case .mins30: return "30 min"
        case .mins60: return "60 min"
        }
    }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

enum HealthStatus: String, Codable {
    case up, down, pending, unknown

    var label: String {
        switch self {
        case .up: return "UP"
        case .down: return "DOWN"
        case .pending: return "Checking…"
        case .unknown: return "Unknown"
        }
    }
}

struct HealthRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var timestamp: Date
    var status: HealthStatus
    var statusCode: Int?
    var responseTimeMs: Double?
    var error: String?
}

enum HealthSound: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard"
    case alert = "Alert"
    case ping = "Ping"
    case critical = "Critical"

    var id: String { rawValue }
    var fileName: String? {
        switch self {
        case .standard: return nil // Default system sound
        default: return rawValue.lowercased()
        }
    }
}

struct EndpointItem: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var cadence: Cadence
    var isCritical: Bool = false
    var notificationSound: HealthSound = .standard
    var currentStatus: HealthStatus = .unknown
    var lastChecked: Date? = nil
    var history: [HealthRecord] = []

    // Trim history older than retention period
    mutating func addRecord(_ record: HealthRecord, retentionDays: Int) {
        history.append(record)
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        history = history.filter { $0.timestamp > cutoff }
    }

    var uptimePercent: Double {
        let recent = history.suffix(100)
        guard !recent.isEmpty else { return 0 }
        let ups = recent.filter { $0.status == .up }.count
        return Double(ups) / Double(recent.count) * 100
    }

    var averageResponseMs: Double? {
        let vals = history.compactMap(\.responseTimeMs)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}

struct Group: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var endpoints: [EndpointItem] = []

    var overallStatus: HealthStatus {
        if endpoints.isEmpty { return .unknown }
        if endpoints.contains(where: { $0.currentStatus == .down }) { return .down }
        if endpoints.allSatisfy({ $0.currentStatus == .up }) { return .up }
        return .unknown
    }
}
