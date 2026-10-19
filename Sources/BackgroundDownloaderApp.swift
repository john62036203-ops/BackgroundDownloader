import SwiftUI
import UIKit

/// 負責接住系統在 App 被終止後、背景下載完成時的喚醒事件
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 盡早建立 DownloadManager，讓 background session 在啟動時就重新連上系統中的 task
        _ = DownloadManager.shared
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        // 把 completionHandler 交給 manager，等 urlSessionDidFinishEvents 時再呼叫
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct BackgroundDownloaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(DownloadManager.shared)
        }
    }
}
