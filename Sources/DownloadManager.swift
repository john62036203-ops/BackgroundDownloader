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
        self.fileName = DownloadManager.defaultFileName(for: url)
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

    // MARK: - GitHub 設定

    static let githubTokenKey = "github_token"

    /// GitHub Personal Access Token（存在 Keychain）
    /// 快取在記憶體，避免每次 SwiftUI 重繪都去讀 Keychain
    private lazy var cachedGithubToken: String = Keychain.get(Self.githubTokenKey) ?? ""

    var githubToken: String {
        get { cachedGithubToken }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cachedGithubToken = cleaned
            Keychain.set(cleaned, for: Self.githubTokenKey)
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    // MARK: - 進度節流

    private var progressPublishPending = false
    private var lastProgressPublish = Date.distantPast
    private let progressInterval: TimeInterval = 0.25

    /// 進度更新只送 UI、不寫磁碟，而且最多每 0.25 秒一次（必須在 stateQueue 上呼叫）
    private func publishProgressThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) >= progressInterval {
            lastProgressPublish = now
            let snapshot = items
            DispatchQueue.main.async { self.items = snapshot }
        } else if !progressPublishPending {
            progressPublishPending = true
            stateQueue.asyncAfter(deadline: .now() + progressInterval) {
                self.progressPublishPending = false
                self.lastProgressPublish = Date()
                let snapshot = self.items
                DispatchQueue.main.async { self.items = snapshot }
            }
        }
    }

    /// 解析 GitHub Actions artifact 網頁連結
    /// https://github.com/OWNER/REPO/actions/runs/RUN/artifacts/ID
    private static func parseGitHubArtifact(_ url: URL) -> (owner: String, repo: String, id: String)? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // [OWNER, REPO, "actions", "runs", RUN, "artifacts", ID]
        guard parts.count >= 7, parts[2] == "actions", parts[3] == "runs", parts[5] == "artifacts",
              Int(parts[6]) != nil else { return nil }
        return (parts[0], parts[1], parts[6])
    }

    /// 使用者看到的是原始網址，實際發出的請求可能被改寫（GitHub artifact 需要走 API 並帶 token）
    func makeRequest(for url: URL) -> URLRequest {
        if let artifact = Self.parseGitHubArtifact(url) {
            let token = githubToken
            if !token.isEmpty {
                var request = URLRequest(url: URL(string:
                    "https://api.github.com/repos/\(artifact.owner)/\(artifact.repo)/actions/artifacts/\(artifact.id)/zip")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("BackgroundDownloader-iOS", forHTTPHeaderField: "User-Agent")
                return request
            }
            // 沒有 token：公開 repo 可以走 nightly.link 代理（私有 repo 會失敗）
            return URLRequest(url: URL(string:
                "https://nightly.link/\(artifact.owner)/\(artifact.repo)/actions/artifacts/\(artifact.id).zip")!)
        }
        return URLRequest(url: url)
    }

    /// 判斷某個 task 是否屬於這個項目（原始網址或改寫後的網址都算）
    private func task(_ task: URLSessionTask, matches item: DownloadItem) -> Bool {
        guard let taskURL = task.originalRequest?.url ?? task.currentRequest?.url else { return false }
        if taskURL == item.url { return true }
        if taskURL == makeRequest(for: item.url).url { return true }
        return false
    }

    /// 預設檔名：GitHub artifact 連結本身沒有副檔名，先給 artifact-ID.zip，之後會被 Content-Disposition 覆蓋
    static func defaultFileName(for url: URL) -> String {
        if let artifact = parseGitHubArtifact(url) { return "artifact-\(artifact.id).zip" }
        let last = url.lastPathComponent
        return (last.isEmpty || last == "/") ? "download" : last
    }

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
                    if let index = self.items.firstIndex(where: { $0.status != .completed && self.task(task, matches: $0) }) {
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
                task = self.session.downloadTask(with: self.makeRequest(for: item.url))
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
            let task = self.session.downloadTask(with: self.makeRequest(for: item.url))
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
        return items.firstIndex(where: { $0.status != .completed && self.task(task, matches: $0) })
    }

    // MARK: - 檔名 / 類型判斷

    /// 決定最終檔名：
    /// 1. 伺服器 Content-Disposition 指定的檔名
    /// 2. 網址本身帶副檔名的檔名
    /// 3. iOS 的 suggestedFilename
    /// 最後用檔頭 magic bytes 校正副檔名（例如伺服器誤報 text/plain 導致變成 .txt）
    private func resolveFileName(urlFileName: String, response: HTTPURLResponse?, fileAt location: URL) -> String {
        var name: String?

        if let disposition = response?.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = Self.fileName(fromContentDisposition: disposition) {
            name = parsed
        }
        if name == nil, !(urlFileName as NSString).pathExtension.isEmpty {
            name = urlFileName
        }
        if name == nil, let suggested = response?.suggestedFilename, !suggested.isEmpty, suggested != "Unknown" {
            name = suggested
        }
        var fileName = name ?? (urlFileName.isEmpty ? "download" : urlFileName)

        // 用檔頭校正副檔名
        if let sniffed = Self.sniffExtension(of: location) {
            let current = (fileName as NSString).pathExtension.lowercased()
            // 這些副檔名是「伺服器亂給」或「沒有」的情況，一律以檔頭為準
            let untrusted: Set<String> = ["", "txt", "bin", "dat", "html", "htm", "php", "aspx", "asp", "jsp", "cgi", "tmp", "download"]
            if untrusted.contains(current) {
                let base = current.isEmpty ? fileName : (fileName as NSString).deletingPathExtension
                fileName = "\(base).\(sniffed)"
            }
        }
        return fileName
    }

    private static func fileName(fromContentDisposition header: String) -> String? {
        // filename*=UTF-8''%E6%AA%94.zip 優先，其次 filename="xxx.zip"
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename*=") {
                var value = String(trimmed.dropFirst("filename*=".count))
                if let range = value.range(of: "''") { value = String(value[range.upperBound...]) }
                if let decoded = value.removingPercentEncoding, !decoded.isEmpty { return sanitize(decoded) }
            }
        }
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                var value = String(trimmed.dropFirst("filename=".count))
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return sanitize(value) }
            }
        }
        return nil
    }

    private static func sanitize(_ name: String) -> String {
        // 去掉路徑分隔符，避免被寫到奇怪的地方
        (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
    }

    /// 讀檔頭前 16 bytes 判斷常見檔案類型
    private static func sniffExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 4 else { return nil }
        let b = [UInt8](data)

        func starts(_ sig: [UInt8]) -> Bool {
            b.count >= sig.count && Array(b[0..<sig.count]) == sig
        }

        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return "zip" }
        if starts([0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if starts([0x1F, 0x8B]) { return "gz" }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7z" }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return "rar" }
        if starts([0x42, 0x5A, 0x68]) { return "bz2" }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if starts([0x4D, 0x5A]) { return "exe" }
        if starts([0x7F, 0x45, 0x4C, 0x46]) { return "elf" }
        if starts([0x49, 0x44, 0x33]) { return "mp3" }
        if starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) || starts([0xFF, 0xF2]) { return "mp3" }
        if starts([0x4F, 0x67, 0x67, 0x53]) { return "ogg" }
        if starts([0x66, 0x4C, 0x61, 0x43]) { return "flac" }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "mkv" }
        if b.count >= 12, Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70] { // ....ftyp
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("M4A") { return "m4a" }
            if brand.hasPrefix("qt") { return "mov" }
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") { return "heic" }
            return "mp4"
        }
        if b.count >= 12, starts([0x52, 0x49, 0x46, 0x46]) {
            let form = Array(b[8..<12])
            if form == [0x57, 0x45, 0x42, 0x50] { return "webp" }
            if form == [0x57, 0x41, 0x56, 0x45] { return "wav" }
            if form == [0x41, 0x56, 0x49, 0x20] { return "avi" }
        }
        if starts([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]) { return "sqlite" }
        return nil
    }

    /// 重新命名已完成的檔案
    func rename(id: UUID, to newName: String) {
        let cleaned = Self.sanitize(newName.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return }
        stateQueue.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            let item = self.items[index]
            if item.status == .completed {
                let from = self.fileURL(for: item)
                let to = self.uniqueDestination(for: cleaned)
                guard (try? self.fileManager.moveItem(at: from, to: to)) != nil else { return }
                self.items[index].fileName = to.lastPathComponent
            } else {
                self.items[index].fileName = cleaned
            }
            self.publish()
        }
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
            self.publishProgressThrottled()
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

            // HTTP 4xx/5xx 代表伺服器拒絕了，存下來的只是錯誤頁，不算成功
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                var message = "HTTP \(http.statusCode)"
                switch http.statusCode {
                case 401: message += "：需要登入（GitHub artifact 請到設定填 token）"
                case 403: message += "：沒有權限（token 需要 repo / actions:read 權限）"
                case 404: message += "：找不到檔案（私有 repo 需要 token，或 artifact 已過期）"
                default: break
                }
                moveError = NSError(domain: "HTTP", code: http.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: message])
                return
            }

            let fileName = self.resolveFileName(
                urlFileName: self.items[index].fileName,
                response: downloadTask.response as? HTTPURLResponse,
                fileAt: location
            )
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
