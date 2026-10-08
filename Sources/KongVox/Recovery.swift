import Foundation

struct ServiceFailure: LocalizedError {
    let stage: String
    let category: String
    let hint: String
    var status: Int? = nil
    var errorDescription: String? { "\(stage)：\(hint)" }
    var report: String { "KongVox 0.11.2\n阶段：\(stage)\n分类：\(category)\nHTTP：\(status.map(String.init) ?? "无")\n建议：\(hint)" }
    static func http(_ status: Int, body: Data, download: Bool = false) -> ServiceFailure {
        if download {
            return Self(stage: "音频下载失败", category: "download", hint: status == 403 || status == 404 ? "下载链接可能已过期。可先重试；仍失败时选择「放弃下载缓存」，再重新生成（可能计费）。" : "生成结果已保留，请检查网络后继续下载。", status: status)
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let nested = json?["error"] as? [String: Any]
        let code = ((json?["code"] as? String) ?? (nested?["code"] as? String) ?? (nested?["status"] as? String) ?? "").lowercased()
        let category: String, hint: String
        if status == 401 || code.contains("apikey") || code.contains("api_key") {
            category = "credentials"; hint = "密钥无效或已过期，请在服务设置中更换 API Key。"
        } else if code.contains("quota") || code.contains("balance") || code.contains("arrear") {
            category = "quota"; hint = "账户额度不足，请检查服务商的余额或配额。"
        } else if status == 429 {
            category = "rate_or_quota"; hint = "请求过于频繁或配额不足，请稍后重试并检查账户额度。"
        } else if status == 403 {
            category = "permission"; hint = "当前账户没有访问权限，请检查地域和模型开通情况。"
        } else if status == 400 || status == 404 || code.contains("invalid") {
            category = "configuration"; hint = "请核对服务地址、模型、声音 ID 及音色与模型的对应关系。"
        } else {
            category = "service"; hint = "服务暂时不可用，请稍后重试；若地址发生跳转，请填写最终 HTTPS 地址。"
        }
        return Self(stage: "服务请求失败", category: category, hint: hint, status: status)
    }
    static func network(_ error: Error, download: Bool) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        return Self(stage: download ? "音频下载失败" : "服务连接失败", category: "network", hint: download ? "请检查网络后继续下载，已保存的生成结果不会重新合成。" : "请检查网络、代理和服务地址后重试。")
    }
    static func report(_ error: Error) -> String {
        // Never copy response bodies, URLs, keys, user text or arbitrary NSError descriptions.
        (error as? ServiceFailure)?.report ?? "KongVox 0.11.2\n分类：本地配置或音频处理\n请核对界面提示。诊断未包含文稿、密钥或下载链接。"
    }
}

struct DownloadReceipt: Codable {
    let url: URL
    static func audioFile(_ file: URL) -> URL { file.appendingPathExtension("wav") }
    static func clear(_ file: URL) throws {
        for url in [audioFile(file), file] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
