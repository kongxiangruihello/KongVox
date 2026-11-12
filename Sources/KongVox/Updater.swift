import SwiftUI
import AppKit
import CryptoKit

/// A published version of the app, as listed by the repository's "latest release".
struct AppRelease: Equatable {
    var version: String
    var notes: String
    var page: URL
    var archive: URL
    var sha256: String?
    var size: Int?
}

/// The parts of updating that need no window: comparing versions, reading the release list,
/// checking a download, and swapping the app on disk.
enum UpdateLogic {
    static let repository = "kongxiangruihello/KongVox"
    static let latest = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// "v0.13.1" or "0.13.1" → [0, 13, 1]. Nil for anything that is not dotted numbers, e.g. "开发版".
    static func parts(_ version: String) -> [Int]? {
        let text = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return numbers.map { $0! }
    }
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = parts(candidate), var b = parts(current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        return a.lexicographicallyPrecedes(b) ? false : a != b
    }
    /// Reads GitHub's release description. Only an archive hosted under this repository's releases is accepted.
    static func parse(_ data: Data) throws -> AppRelease {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let numbers = parts(tag),
              let pageText = json["html_url"] as? String, let page = URL(string: pageText), page.scheme == "https", page.host == "github.com",
              let assets = json["assets"] as? [[String: Any]] else { throw VoxError(message: "更新信息格式无效。") }
        for asset in assets {
            guard let name = asset["name"] as? String, name.hasSuffix("-Mac.zip"),
                  let address = asset["browser_download_url"] as? String, let url = URL(string: address),
                  url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/\(repository)/releases/download/") else { continue }
            var digest: String?
            if let value = asset["digest"] as? String, value.hasPrefix("sha256:") {
                let hex = String(value.dropFirst(7)).lowercased()
                if hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) { digest = hex }
            }
            return AppRelease(version: numbers.map(String.init).joined(separator: "."), notes: json["body"] as? String ?? "", page: page, archive: url, sha256: digest, size: asset["size"] as? Int)
        }
        throw VoxError(message: "最新版本没有可用的 Mac 安装包。")
    }
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Why the running copy cannot be replaced in place, or nil when it can.
    static func replaceBlocker(_ app: URL) -> String? {
        guard app.pathExtension == "app" else { return "当前不是从应用包运行，无法自动更新。" }
        if app.path.contains("/AppTranslocation/") { return "请先把 KongVox 拖到「应用程序」文件夹再更新。" }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path), FileManager.default.isWritableFile(atPath: app.path) else {
            return "没有权限替换当前位置的 KongVox，请从发布页手动下载。"
        }
        return nil
    }
    /// Runs after the app quits: puts the new copy in place and reopens it. The old copy is kept as
    /// "<name>.previous" until the new one is in place, and restored if the move fails.
    /// Arguments: process id to wait for, new app, installed app, and "no-open" to skip relaunching (tests).
    static let swapScript = """
    pid="$1"; new="$2"; dest="$3"; old="$dest.previous"
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then exit 1; fi
    rm -rf "$old"
    if mv "$dest" "$old"; then
      if mv "$new" "$dest"; then rm -rf "$old"; else mv "$old" "$dest"; fi
    fi
    [ "$4" = "no-open" ] || open "$dest"
    """
    static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
    /// Downloads, checks and unpacks a release. Returns the unpacked app, on the same volume as `destination`.
    static func fetch(_ release: AppRelease, replacing destination: URL, session: URLSession = .shared) async throws -> URL {
        let (downloaded, response) = try await session.download(from: release.archive)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoxError(message: "下载更新失败，请稍后重试。") }
        if let expected = release.sha256, try sha256(of: downloaded) != expected { throw VoxError(message: "下载的更新与发布记录不一致，已放弃。") }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        do {
            guard try await run("/usr/bin/ditto", ["-x", "-k", downloaded.path, staging.path]) == 0 else { throw VoxError(message: "无法解开更新包。") }
            let app = staging.appendingPathComponent("KongVox.app")
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == (Bundle.main.bundleIdentifier ?? "com.kongvox.studio"),
                  info["CFBundleShortVersionString"] as? String == release.version else { throw VoxError(message: "更新包内容与发布的版本不符，已放弃。") }
            guard try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw VoxError(message: "更新包签名校验未通过，已放弃。") }
            return app
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
}

@MainActor final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, installing
        case available(AppRelease)
        case failed(String)
    }
    @Published var phase = Phase.idle
    @Published var showPanel = false
    @Published var autoCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") }
    }
    var current: String { AppInfo.version }
    var availableRelease: AppRelease? { if case .available(let release) = phase { return release }; return nil }

    /// Quiet check at launch, at most once a day. Problems are not shown; a found update appears in the sidebar.
    func checkOnLaunch() {
        guard autoCheck, UpdateLogic.parts(current) != nil else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        check(manual: false)
    }
    func check(manual: Bool) {
        if manual { showPanel = true }
        guard phase != .checking, phase != .installing else { return }
        guard UpdateLogic.parts(current) != nil else { if manual { phase = .failed("开发版不支持在线更新。") }; return }
        let previous = phase
        phase = .checking
        Task {
            do {
                var request = URLRequest(url: UpdateLogic.latest); request.timeoutInterval = 20
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("KongVox/\(current)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 { throw VoxError(message: "仓库还没有发布正式版本。") }
                if status == 403 || status == 429 { throw VoxError(message: "GitHub 暂时限制了查询次数，请稍后再试。") }
                guard status == 200 else { throw VoxError(message: "无法获取更新信息（HTTP \(status)）。") }
                let release = try UpdateLogic.parse(data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                phase = UpdateLogic.isNewer(release.version, than: current) ? .available(release) : .upToDate
            } catch {
                // A quiet check leaves no trace of a failure; a manual one explains it.
                phase = manual ? .failed((error as? VoxError)?.message ?? "无法连接 GitHub，请检查网络或代理后重试。") : previous
            }
        }
    }
    /// Downloads the update, then quits; a helper replaces the app and reopens it.
    func install(beforeQuit: @escaping () -> Void) {
        guard let release = availableRelease else { return }
        let destination = Bundle.main.bundleURL
        if let blocker = UpdateLogic.replaceBlocker(destination) { phase = .failed(blocker); return }
        phase = .installing
        Task {
            do {
                let app = try await UpdateLogic.fetch(release, replacing: destination)
                let helper = Process()
                helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                helper.arguments = ["-c", UpdateLogic.swapScript, "kongvox-update", String(ProcessInfo.processInfo.processIdentifier), app.path, destination.path]
                helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
                try helper.run()
                beforeQuit()
                NSApp.terminate(nil)
            } catch {
                phase = .failed((error as? VoxError)?.message ?? "更新未完成：\(error.localizedDescription)")
            }
        }
    }
}

struct UpdateView: View {
    @EnvironmentObject var updater: AppUpdater
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("软件更新").font(.title2.bold())
            Text("当前版本 \(updater.current)").font(.caption).foregroundStyle(.secondary)
            switch updater.phase {
            case .idle: Text("尚未检查。")
            case .checking: HStack { ProgressView().controlSize(.small); Text("正在检查更新…") }
            case .upToDate: Label("已是最新版本。", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .installing: HStack { ProgressView().controlSize(.small); Text("正在下载并校验更新，完成后 KongVox 会自动重新打开…") }
            case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .available(let release):
                Text("发现新版本 \(release.version)").font(.headline)
                if let size = release.size { Text("安装包约 \(size / 1_048_576) MB").font(.caption).foregroundStyle(.secondary) }
                ScrollView { Text(release.notes.isEmpty ? "此版本没有填写更新说明。" : release.notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 220)
                Text("更新会退出并重新打开 KongVox；项目、音频和服务设置保留在本机，不受影响。升级后首次读取密钥时，macOS 可能再次要求输入登录密码。").font(.caption).foregroundStyle(.secondary)
                if studio.isWorking { Text("正在生成或导出，完成后才能更新。").font(.caption).foregroundStyle(.orange) }
            }
            Toggle("启动时自动检查更新（每天最多一次）", isOn: $updater.autoCheck).font(.caption)
            HStack {
                Link("打开发布页", destination: updater.availableRelease?.page ?? URL(string: "https://github.com/\(UpdateLogic.repository)/releases")!)
                Spacer()
                Button("关闭") { dismiss() }.disabled(updater.phase == .installing)
                if updater.availableRelease != nil {
                    Button("下载并安装") { updater.install(beforeQuit: { studio.flushPendingSave() }) }.buttonStyle(.borderedProminent).disabled(studio.isWorking)
                } else {
                    Button("重新检查") { updater.check(manual: true) }.disabled(updater.phase == .checking || updater.phase == .installing)
                }
            }
        }
        .padding(22).frame(width: 520)
    }
}
