import BackgroundTasks
import UIKit

@MainActor
enum BackgroundRefresh {
    static let identifier = "dev.adachi.kakeiro.refresh"

    static func register(store: AppStore) {
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                schedule()
                let work = Task { await store.refresh() }
                task.expirationHandler = { work.cancel(); Task { @MainActor in store.cancelRefresh() } }
                let succeeded = await work.value
                task.setTaskCompleted(success: succeeded)
            }
        }
    }

    static func schedule() {
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        let calendar = FinanceCalculator.calendar
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = next
        // The server triggers provider refresh at JST midnight. iOS chooses when
        // to download that result; earliestBeginDate is never an exact alarm.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        try? BGTaskScheduler.shared.submit(request)
    }
}
