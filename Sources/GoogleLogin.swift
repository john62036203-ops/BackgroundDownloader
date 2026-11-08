import SwiftUI
import WebKit

/// 管理 Google 登入 cookie：在內建網頁登入後，把 google.com 的 cookie 存進 HTTPCookieStorage，
/// 下載 Google Drive 時手動帶上 Cookie header（背景 URLSession 不一定會自動帶）
enum GoogleAuth {
    /// 用一般 iPhone Safari 的 UA，避免 Google 把內嵌網頁當成「不安全的瀏覽器」而拒絕登入
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func isGoogleHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "google.com" || host.hasSuffix(".google.com") || host.hasSuffix(".googleusercontent.com")
    }

    static var isLoggedIn: Bool {
        (HTTPCookieStorage.shared.cookies ?? []).contains { isGoogleCookie($0) && ["SID", "__Secure-1PSID", "__Secure-3PSID"].contains($0.name) }
    }

    static func isGoogleCookie(_ c: HTTPCookie) -> Bool {
        let d = c.domain.lowercased()
        return d.hasSuffix("google.com") || d.hasSuffix("googleusercontent.com")
    }

    /// 給 Google 網址的請求加上登入 cookie 與 Safari UA
    static func authorize(_ request: inout URLRequest) {
        guard let url = request.url, isGoogleHost(url) else { return }
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        if !cookies.isEmpty {
            let header = HTTPCookie.requestHeaderFields(with: cookies)
            for (k, v) in header { request.setValue(v, forHTTPHeaderField: k) }
        }
    }

    /// 從內建網頁取出 cookie 存起來
    static func importCookies(from store: WKHTTPCookieStore, completion: @escaping (Int) -> Void) {
        store.getAllCookies { cookies in
            let google = cookies.filter(isGoogleCookie)
            for c in google { HTTPCookieStorage.shared.setCookie(c) }
            completion(google.count)
        }
    }

    static func logout(completion: @escaping () -> Void) {
        for c in HTTPCookieStorage.shared.cookies ?? [] where isGoogleCookie(c) {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let google = records.filter { $0.displayName.contains("google") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: google) {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}

/// 內建 Google 登入頁
struct GoogleLoginView: View {
    @Environment(\.dismiss) private var dismiss
    var onFinish: () -> Void

    var body: some View {
        NavigationStack {
            GoogleWebView()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("登入 Google")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            GoogleAuth.importCookies(from: WKWebsiteDataStore.default().httpCookieStore) { _ in
                                DispatchQueue.main.async {
                                    onFinish()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
        }
    }
}

private struct GoogleWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = GoogleAuth.safariUserAgent
        web.allowsBackForwardNavigationGestures = true
        let url = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fdrive.google.com%2F")!
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
