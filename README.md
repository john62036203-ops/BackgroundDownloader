# BackgroundDownloader

支援背景下載與斷點續傳的 iOS App（SwiftUI，iOS 16+）。

## 建立專案

1. Xcode → File → New → Project → iOS **App**，Interface 選 **SwiftUI**，Product Name 填 `BackgroundDownloader`。
2. 刪掉 Xcode 自動產生的 `BackgroundDownloaderApp.swift` 和 `ContentView.swift`，把這個資料夾裡的三個 `.swift` 檔拖進專案。
3. 在 Target → **Info** 新增兩個 key，讓使用者能在「檔案」App 看到下載好的檔案：
   - `UIFileSharingEnabled` (Application supports iTunes file sharing) = `YES`
   - `LSSupportsOpeningDocumentsInPlace` (Supports opening documents in place) = `YES`
4. 把 `DownloadManager.sessionIdentifier` 改成你自己的 bundle id 前綴（例如 `com.yourname.backgrounddownloader.session`）。
5. 用實機測試。模擬器對背景 session 的行為不完整。

> 不需要在 Signing & Capabilities 開啟 Background Modes，背景 `URLSession` 是系統代為傳輸，不走那套機制。

## 運作方式

| 情境 | 處理 |
|---|---|
| App 切到背景或被系統終止 | `URLSessionConfiguration.background` 的下載由系統 daemon 繼續跑。 |
| 下載完成時 App 不在前景 | 系統以 `handleEventsForBackgroundURLSession` 喚醒 App，`AppDelegate` 把 completionHandler 交給 `DownloadManager`，搬完檔案後在 `urlSessionDidFinishEvents` 回呼。 |
| 使用者按暫停 | `task.cancel(byProducingResumeData:)`，`didCompleteWithError` 收到 `NSURLSessionDownloadTaskResumeData` 後寫入磁碟。 |
| 斷網 / 逾時 / 伺服器錯誤 | 同上，只要錯誤裡附 resumeData 就存起來；按重試會用 `downloadTask(withResumeData:)` 從中斷處續傳。 |
| App 重新啟動 | 載入 `state.json`，呼叫 `getAllTasks` 把仍在系統中的 task 重新對應；找不到對應 task 的項目自動用 resumeData 續傳。 |

## 續傳的前提

伺服器必須支援 HTTP Range 請求（回應帶 `Accept-Ranges: bytes`，且對 Range 請求回 `206 Partial Content`）。
不支援的話 resumeData 會失效，iOS 會從頭重新下載。另外 resumeData 內含 ETag/Last-Modified，若檔案在伺服器上被更新，續傳也會被拒絕而重頭開始。

## 測試斷線續傳

1. 貼上一個大檔案網址（例如 Ubuntu ISO 鏡像）開始下載。
2. 開飛航模式數秒再關掉：背景 session 預設會等網路恢復後自動接續，通常不會進 failed。
3. 按暫停 → 殺掉 App → 重開 → 按重試，進度條會從原本的百分比繼續。
