import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var urlText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("新增下載") {
                    HStack {
                        TextField("貼上檔案網址（https://...）", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit(addDownload)
                        Button("下載", action: addDownload)
                            .buttonStyle(.borderedProminent)
                            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("下載清單") {
                    if manager.items.isEmpty {
                        Text("還沒有任何下載")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.items) { item in
                        DownloadRow(item: item)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            manager.remove(id: manager.items[index].id)
                        }
                    }
                }
            }
            .navigationTitle("背景下載")
        }
    }

    private func addDownload() {
        manager.add(urlString: urlText)
        urlText = ""
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                actionButton
            }

            if item.status == .completed {
                ShareLink(item: manager.fileURL(for: item)) {
                    Label("已完成 · \(format(item.totalBytes)) · 分享", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                ProgressView(value: item.progress)
                HStack {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                    Spacer()
                    if item.totalBytes > 0 {
                        Text("\(format(item.bytesWritten)) / \(format(item.totalBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.status {
        case .downloading, .queued:
            Button { manager.pause(id: item.id) } label: {
                Image(systemName: "pause.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
        case .paused, .failed:
            Button { manager.resume(id: item.id) } label: {
                Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
        case .completed:
            EmptyView()
        }
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "等待中"
        case .downloading: return "下載中 \(Int(item.progress * 100))%"
        case .paused: return "已暫停，可續傳"
        case .failed: return "失敗：\(item.errorMessage ?? "未知錯誤")（點擊重試會續傳）"
        case .completed: return "已完成"
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    ContentView().environmentObject(DownloadManager.shared)
}
