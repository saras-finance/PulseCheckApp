import SwiftUI
import UserNotifications
import BackgroundTasks

@main
struct PulseCheckApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: GroupStore
    @StateObject private var healthEngine: HealthCheckEngine
    private let notificationDelegate = NotificationDelegate()

    init() {
        let sharedStore = GroupStore()
        let sharedEngine = HealthCheckEngine()
        sharedEngine.store = sharedStore
        
        _store = StateObject(wrappedValue: sharedStore)
        _healthEngine = StateObject(wrappedValue: sharedEngine)
        
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        
        // Define Categories
        let retryAction = UNNotificationAction(identifier: "RETRY", title: "Retry Now", options: [])
        let viewAction = UNNotificationAction(identifier: "VIEW", title: "View Details", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "HEALTH_ALERT",
            actions: [retryAction, viewAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { granted, error in
            if let error = error {
                print("Auth error: \(error.localizedDescription)")
            }
        }
        registerBackgroundTasks()
        scheduleBackgroundRefresh()
        scheduleBackgroundProcessing()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(healthEngine)
                .onAppear {
                    healthEngine.startAll()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                scheduleBackgroundRefresh()
            }
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.pulsecheck.refresh", using: nil) { task in
            handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.pulsecheck.processing", using: nil) { task in
            handleBackgroundProcessing(task: task as! BGProcessingTask)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task {
            await healthEngine.runAllChecksOnce()
            task.setTaskCompleted(success: true)
        }
    }

    private func handleBackgroundProcessing(task: BGProcessingTask) {
        scheduleBackgroundProcessing()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task {
            await healthEngine.runAllChecksOnce()
            task.setTaskCompleted(success: true)
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.pulsecheck.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("🚨 Refresh Task Error: \(error)")
        }
    }

    private func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: "com.pulsecheck.processing")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("🚨 Processing Task Error: \(error)")
        }
    }
}

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner and play sound even when app is in foreground
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Handle notification tap
        completionHandler()
    }
}
