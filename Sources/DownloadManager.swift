import Foundation
import Combine

/// 單一下載項目的狀態
struct DownloadItem: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case queued, downloading, paused, completed, failed
    }

    let id: UUID
    let url: URL
    var fileName: String
    var status: Status = .queued
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    var errorMessage: String?
    /// 目前對應的 URLSessionTask id（重啟後會重新對應）
    var taskIdentifier: Int?

    var progress: Double {
        totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.fileName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
    }
}

/// 背景下載管理器：
/// - 使用 background URLSession，App 進背景或被系統終止後仍會繼續下載
/// - 中斷（取消、斷網、系統錯誤）時儲存 resumeData，之後可續傳
/// - 下載清單與 resumeData 都會持久化到磁碟，重啟後恢復
final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()
    static let sessionIdentifier = "com.john62036203.backgrounddownloader.session"

    @Published private(set) var items: [DownloadItem] = []

    /// 由 AppDelegate 在 handleEventsForBackgroundURLSession 傳入
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false          // 不要等系統「方便」時才下載
        config.sessionSendsLaunchEvents = true   // App 被殺後，下載完成仍會喚醒 App
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 24 // 最多嘗試一天
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let fileManager = FileManager.default
    private let stateQueue = DispatchQueue(label: "DownloadManager.state")

    // MARK: - 路徑

    private var supportDirectory: URL {
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var stateFileURL: URL { supportDirectory.appendingPathComponent("state.json") }

    private func resumeDataURL(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent("\(id.uuidString).resume")
    }

    /// 下載完成的檔案存放在 Documents，使用者可透過「檔案」App 看到
    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func fileURL(for item: DownloadItem) -> URL {
        documentsDirectory.appendingPathComponent(item.fileName)
    }

    // MARK: - 初始化 / 恢復

    private override init() {
        super.init()
        loadState()
        // 觸發 lazy session 建立，並把仍在系統中跑的 task 重新對應回來
        reattachRunningTasks()
    }

    private func reattachRunningTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.stateQueue.async {
                var running = Set<Int>()
                for task in tasks {
                    guard let url = task.originalRequest?.url ?? task.currentRequest?.url else { continue }
                    if let index = self.items.firstIndex(where: { $0.url == url && $0.status != .completed }) {
                        self.items[index].taskIdentifier = task.taskIdentifier
                        self.items[index].status = .downloading
                        running.insert(task.taskIdentifier)
                        if task.state == .suspended { task.resume() }
                    }
                }
                // 曾經標記為 downloading 但系統裡已經沒有對應 task 的項目 → 嘗試用 resumeData 續傳
                for index in self.items.indices where self.items[index].status == .downloading {
                    if let tid = self.items[index].taskIdentifier, running.contains(tid) { continue }
                    self.items[index].taskIdentifier = nil
                    self.items[index].status = .paused
                    let id = self.items[index].id
                    DispatchQueue.main.async { self.resume(id: id) }
                }
                self.publish()
            }
        }
    }

    // MARK: - 公開操作

    func add(urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let item = DownloadItem(url: url)
        stateQueue.async {
            self.items.append(item)
            self.publish()
        }
        start(item: item)
    }

    func pause(id: UUID) {
        stateQueue.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }),
                  let tid = self.items[index].taskIdentifier else { return }
            self.session.getAllTasks { tasks in
                guard let task = tasks.first(where: { $0.taskIdentifier == tid }) as? URLSessionDownloadTask else { return }
                // cancel(byProducingResumeData:) 會在 didCompleteWithError 給我們 resumeData
                task.cancel { _ in }
            }
            self.items[index].status = .paused
            self.publish()
        }
    }

    func resume(id: UUID) {
        stateQueue.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            let item = self.items[index]
            guard item.status == .paused || item.status == .failed else { return }

            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: self.resumeDataURL(for: id)), !data.isEmpty {
                task = self.session.downloadTask(withResumeData: data)
            } else {
                task = self.session.downloadTask(with: item.url)
            }
            task.taskDescription = id.uuidString
            task.resume()

            self.items[index].taskIdentifier = task.taskIdentifier
            self.items[index].status = .downloading
            self.items[index].errorMessage = nil
            self.publish()
        }
    }

    func remove(id: UUID) {
        stateQueue.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            let item = self.items[index]
            if let tid = item.taskIdentifier {
                self.session.getAllTasks { tasks in
                    tasks.first(where: { $0.taskIdentifier == tid })?.cancel()
                }
            }
            try? self.fileManager.removeItem(at: self.resumeDataURL(for: id))
            if item.status == .completed {
                try? self.fileManager.removeItem(at: self.fileURL(for: item))
            }
            self.items.remove(at: index)
            self.publish()
        }
    }

    // MARK: - 內部

    private func start(item: DownloadItem) {
        stateQueue.async {
            let task = self.session.downloadTask(with: item.url)
            task.taskDescription = item.id.uuidString
            task.resume()
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[index].taskIdentifier = task.taskIdentifier
                self.items[index].status = .downloading
            }
            self.publish()
        }
    }

    private func itemIndex(for task: URLSessionTask) -> Int? {
        if let desc = task.taskDescription, let id = UUID(uuidString: desc),
           let index = items.firstIndex(where: { $0.id == id }) {
            return index
        }
        if let index = items.firstIndex(where: { $0.taskIdentifier == task.taskIdentifier }) {
            return index
        }
        // App 被重啟後 taskDescription 可能遺失，用 URL 比對
        if let url = task.originalRequest?.url ?? task.currentRequest?.url {
            return items.firstIndex(where: { $0.url == url && $0.status != .completed })
        }
        return nil
    }

    private func uniqueDestination(for fileName: String) -> URL {
        var candidate = documentsDirectory.appendingPathComponent(fileName)
        var counter = 1
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = documentsDirectory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: - 持久化

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = saved
    }

    /// 寫入磁碟並通知 UI（必須在 stateQueue 上呼叫）
    private func publish() {
        let snapshot = items
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
        DispatchQueue.main.async { self.items = snapshot }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        stateQueue.async {
            guard let index = self.itemIndex(for: downloadTask) else { return }
            self.items[index].bytesWritten = totalBytesWritten
            self.items[index].totalBytes = totalBytesExpectedToWrite
            self.items[index].status = .downloading
            self.items[index].taskIdentifier = downloadTask.taskIdentifier
            // 進度更新很頻繁，只更新 UI、不每次寫磁碟
            let snapshot = self.items
            DispatchQueue.main.async { self.items = snapshot }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        stateQueue.async {
            guard let index = self.itemIndex(for: downloadTask) else { return }
            self.items[index].bytesWritten = fileOffset
            self.items[index].totalBytes = expectedTotalBytes
            self.publish()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 注意：location 的暫存檔在這個方法 return 後就會被刪除，必須同步搬走
        var destination: URL?
        var moveError: Error?
        var itemID: UUID?

        stateQueue.sync {
            guard let index = self.itemIndex(for: downloadTask) else { return }
            itemID = self.items[index].id

            // 優先用伺服器建議的檔名
            var fileName = self.items[index].fileName
            if let suggested = downloadTask.response?.suggestedFilename, !suggested.isEmpty {
                fileName = suggested
            }
            let dest = self.uniqueDestination(for: fileName)
            do {
                try self.fileManager.moveItem(at: location, to: dest)
                destination = dest
            } catch {
                moveError = error
            }
        }

        guard let itemID else { return }
        stateQueue.async {
            guard let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
            if let destination {
                self.items[index].fileName = destination.lastPathComponent
                self.items[index].status = .completed
                self.items[index].bytesWritten = self.items[index].totalBytes
                self.items[index].taskIdentifier = nil
                try? self.fileManager.removeItem(at: self.resumeDataURL(for: itemID))
            } else {
                self.items[index].status = .failed
                self.items[index].errorMessage = moveError?.localizedDescription ?? "搬移檔案失敗"
            }
            self.publish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // 成功的情況已在 didFinishDownloadingTo 處理
        stateQueue.async {
            guard let index = self.itemIndex(for: task) else { return }
            let id = self.items[index].id
            let nsError = error as NSError

            // 不論是使用者暫停、斷網還是系統錯誤，有 resumeData 就存起來
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: self.resumeDataURL(for: id), options: .atomic)
            }

            self.items[index].taskIdentifier = nil
            if nsError.code == NSURLErrorCancelled {
                self.items[index].status = .paused
            } else {
                self.items[index].status = .failed
                self.items[index].errorMessage = nsError.localizedDescription
            }
            self.publish()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // 所有背景事件都處理完了，通知系統可以把 App 再掛起 / 截圖
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
