import SwiftUI
import WebKit

/// 內建瀏覽器：在裡面打開檔案分享網站、按下載按鈕，App 會攔截真正的檔案連結交給背景下載
struct BrowserView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: BrowserModel
    @State private var address: String
    @State private var captured: String?

    init(startURL: URL) {
        _model = StateObject(wrappedValue: BrowserModel(startURL: startURL))
        _address = State(initialValue: startURL.absoluteString)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("網址", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { model.load(address) }
                        .textFieldStyle(.roundedBorder)
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                BrowserWebView(model: model)
            }
            .navigationTitle("瀏覽器下載")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canGoBack)
                    Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canGoForward)
                    Spacer()
                    Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onReceive(model.$currentURL) { url in
                if let url { address = url.absoluteString }
            }
            .onAppear {
                model.onDownload = { url, headers, name in
                    manager.add(url: url, headers: headers, suggestedName: name)
                    captured = name ?? url.lastPathComponent
                }
            }
            .alert("已加入背景下載", isPresented: Binding(get: { captured != nil }, set: { if !$0 { captured = nil } })) {
                Button("回到清單") { captured = nil; dismiss() }
                Button("繼續瀏覽", role: .cancel) { captured = nil }
            } message: {
                Text(captured ?? "")
            }
        }
    }
}

final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var currentURL: URL?
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    var onDownload: ((URL, [String: String], String?) -> Void)?
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    init(startURL: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = GoogleAuth.safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] w, _ in DispatchQueue.main.async { self?.currentURL = w.url } },
            webView.observe(\.isLoading) { [weak self] w, _ in DispatchQueue.main.async { self?.isLoading = w.isLoading } },
            webView.observe(\.canGoBack) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoForward = w.canGoForward } },
        ]
        webView.load(URLRequest(url: startURL))
    }

    func load(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        if let url = URL(string: t) { webView.load(URLRequest(url: url)) }
    }

    // MARK: 攔截下載

    /// 網頁要求「下載」（<a download> 之類）
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            capture(url: url, response: nil)
            return
        }
        decisionHandler(.allow)
    }

    /// 伺服器回的是檔案（瀏覽器顯示不了，或標成 attachment）
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        let isAttachment = disposition.contains("attachment")
        if navigationResponse.isForMainFrame || isAttachment,
           isAttachment || !navigationResponse.canShowMIMEType,
           let url = navigationResponse.response.url {
            decisionHandler(.cancel)
            capture(url: url, response: navigationResponse.response)
            return
        }
        decisionHandler(.allow)
    }

    /// target=_blank 的連結：在同一個頁面打開，才攔得到
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    private func capture(url: URL, response: URLResponse?) {
        let referer = webView.url?.absoluteString
        let name = response?.suggestedFilename
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let host = (url.host ?? "").lowercased()
            let matching = cookies.filter { c in
                var d = c.domain.lowercased()
                if d.hasPrefix(".") { d.removeFirst() }
                return host == d || host.hasSuffix("." + d)
            }
            var headers = HTTPCookie.requestHeaderFields(with: matching)
            headers["User-Agent"] = GoogleAuth.safariUserAgent
            if let referer { headers["Referer"] = referer }
            let cleanName = (name == nil || name == "Unknown") ? nil : name
            DispatchQueue.main.async { self.onDownload?(url, headers, cleanName) }
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
