import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var showToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if showToken {
                                TextField("ghp_… 或 github_pat_…", text: $token)
                            } else {
                                SecureField("ghp_… 或 github_pat_…", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("GitHub Personal Access Token")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("貼上 GitHub Actions 的 artifact 連結（github.com/…/actions/runs/…/artifacts/…）時，App 會自動改用 GitHub API 下載並帶上這組 token。")
                        Text("建立方式：GitHub → Settings → Developer settings → Personal access tokens → Fine-grained token → 選要下載的 repo → Repository permissions 把 Actions 設為 Read-only。Classic token 則勾選 repo。")
                        Text("沒填 token 時，公開 repo 會改走 nightly.link 代理下載；私有 repo 一定要 token。")
                        Text("Token 存在 iOS Keychain，不會離開這支手機。")
                    }
                }

                Section {
                    Link(destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!) {
                        Label("前往 GitHub 建立 Fine-grained token", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=BackgroundDownloader")!) {
                        Label("前往 GitHub 建立 Classic token（勾好 repo）", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        manager.githubToken = token
                        dismiss()
                    }
                }
            }
            .onAppear { token = manager.githubToken }
        }
    }
}
