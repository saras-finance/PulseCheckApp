import Foundation
import Combine
import UserNotifications

@MainActor
class HealthCheckEngine: ObservableObject {
    var store: GroupStore?
    private var timers: [UUID: Timer] = [:]

    // MARK: - Start/Stop
    func startAll() {
        guard let store = store else { return }
        for group in store.groups {
            for endpoint in group.endpoints {
                schedule(endpoint: endpoint, groupId: group.id)
            }
        }
    }

    func schedule(endpoint: EndpointItem, groupId: UUID) {
        stopTimer(for: endpoint.id)
        let timer = Timer.scheduledTimer(withTimeInterval: endpoint.cadence.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.check(endpointId: endpoint.id, groupId: groupId)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[endpoint.id] = timer

        // Also fire immediately
        Task { await check(endpointId: endpoint.id, groupId: groupId) }
    }

    func stopTimer(for endpointId: UUID) {
        timers[endpointId]?.invalidate()
        timers.removeValue(forKey: endpointId)
    }

    func runAllChecksOnce() async {
        guard let store = store else { return }
        for group in store.groups {
            for endpoint in group.endpoints {
                await check(endpointId: endpoint.id, groupId: group.id)
            }
        }
    }

    // MARK: - Core check
    func check(endpointId: UUID, groupId: UUID) async {
        guard let store = store,
              let group = store.group(for: groupId),
              let endpoint = group.endpoints.first(where: { $0.id == endpointId }),
              let url = URL(string: endpoint.url) else { return }

        let start = Date()
        var record = HealthRecord(timestamp: start, status: .pending)

        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let isUp = (200...299).contains(code)
            record.status = isUp ? .up : .down
            record.statusCode = code
            record.responseTimeMs = elapsed

            if !isUp {
                sendNotification(endpoint: endpoint, group: group, code: code, error: nil)
            }
        } catch {
            record.status = .down
            record.error = error.localizedDescription
            sendNotification(endpoint: endpoint, group: group, code: nil, error: error.localizedDescription)
        }

        store.recordHealth(groupId: groupId, endpointId: endpointId, record: record)
        updateBadge()
    }

    private func updateBadge() {
        guard let store = store else { return }
        let downCount = store.groups.flatMap(\.endpoints).filter { $0.currentStatus == .down }.count
        UNUserNotificationCenter.current().setBadgeCount(downCount)
    }

    // MARK: - Notifications
    private func sendNotification(endpoint: EndpointItem, group: Group, code: Int?, error: String?) {
        let content = UNMutableNotificationContent()
        content.title = "🔴 \(group.name) - \(endpoint.name) is DOWN"
        content.body = code != nil ? "HTTP Status: \(code!)" : (error ?? "Connection failed")
        
        // Critical / Persistent settings
        if endpoint.isCritical {
            content.interruptionLevel = .critical
            content.relevanceScore = 1.0
            if let soundFile = endpoint.notificationSound.fileName {
                content.sound = UNNotificationSound.criticalSoundNamed(UNNotificationSoundName(soundFile))
            } else {
                content.sound = .defaultCritical
            }
        } else {
            content.interruptionLevel = .timeSensitive
            if let soundFile = endpoint.notificationSound.fileName {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(soundFile))
            } else {
                content.sound = .default
            }
        }

        // Interactive actions
        let retryAction = UNNotificationAction(identifier: "RETRY", title: "Retry Now", options: [])
        let viewAction = UNNotificationAction(identifier: "VIEW", title: "View Details", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "HEALTH_ALERT",
            actions: [retryAction, viewAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        content.categoryIdentifier = "HEALTH_ALERT"
        content.userInfo = ["groupId": group.id.uuidString, "endpointId": endpoint.id.uuidString]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        // Stable identifier: This REPLACES the notification if it already exists, 
        // effectively making it "sticky" or "re-posting" it if cleared.
        let request = UNNotificationRequest(
            identifier: "health-\(endpoint.id)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("🚨 Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }
}
