import SwiftUI

struct VoiceFavorite: Codable, Identifiable {
    var id = UUID()
    var name: String
    var tags: String
    var settings: VoiceSettings
}
extension Studio {
    func saveFavorites(_ values: [VoiceFavorite]) {
        guard !isWorking, storageAvailable else { return }
        do { try JSONEncoder().encode(values).write(to: root.appendingPathComponent("voices.json"), options: .atomic); voiceFavorites = values }
        catch { self.error = "音色收藏保存失败。" }
    }
    func favoriteCurrentVoice(name: String, tags: String) {
        guard var settings = project?.settings, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings.pronunciationRules = nil; settings.globalPronunciationRules = nil
        saveFavorites(voiceFavorites + [VoiceFavorite(name: String(name.prefix(60)), tags: String(tags.prefix(100)), settings: settings)])
    }
    func useFavorite(_ favorite: VoiceFavorite) {
        guard catalog.profiles.contains(where: { $0 == favorite.settings.resolvedService && $0.enabled }) else { error = "收藏使用的服务已改变，请重新收藏当前配置。"; return }
        edit { p in p.settings.service = favorite.settings.service; p.settings.voice = favorite.settings.voice; p.settings.speed = favorite.settings.speed; p.settings.mode = favorite.settings.mode; p.settings.direction = favorite.settings.direction }
    }
    func voiceSampleURL(_ favorite: VoiceFavorite, text: String) -> URL {
        root.appendingPathComponent("VoiceSamples").appendingPathComponent(Segment(text: text).fingerprint(favorite.settings) + ".wav")
    }
    func hasVoiceSample(_ favorite: VoiceFavorite, text: String) -> Bool { FileManager.default.fileExists(atPath: voiceSampleURL(favorite, text: text).path) }
    func compareFavorites(ids: Set<UUID>, text: String) {
        guard !isWorking, storageAvailable else { return }
        let chosen = voiceFavorites.filter { ids.contains($0.id) }
        guard (1...2).contains(chosen.count), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 300 else { error = "请选择 1–2 个收藏音色，并输入最多 300 字的相同试听文稿。"; return }
        for favorite in chosen {
            var p = Project(); p.settings = favorite.settings; p.segments = [Segment(text: text)]
            let issues = ServicePreflight.inspect(p, catalog: catalog).filter(\.blocking)
            guard issues.isEmpty else { error = issues.map(\.message).joined(separator: "\n"); return }
        }
        busy = true; comparingVoices = true; stop(); status = "正在准备音色对比…"
        task = Task {
            defer { busy = false; comparingVoices = false; task = nil }
            do {
                let folder = root.appendingPathComponent("VoiceSamples")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var keys: [String: String] = [:]
                // Validate every new request before submitting the first paid synthesis.
                for favorite in chosen where !hasVoiceSample(favorite, text: text) {
                    let service = favorite.settings.resolvedService
                    if keys[service.keyAccount] == nil { keys[service.keyAccount] = try keyProvider(service) }
                    _ = try client.request(text: text, settings: favorite.settings, key: keys[service.keyAccount] ?? "")
                }
                for favorite in chosen {
                    try Task.checkCancellation()
                    let url = voiceSampleURL(favorite, text: text)
                    if FileManager.default.fileExists(atPath: url.path) { continue }
                    let recovery = folder.appendingPathComponent("Recovery").appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json")
                    status = "正在生成试听：\(favorite.name)"
                    let pcm = try await client.generate(text: text, settings: favorite.settings, key: keys[favorite.settings.resolvedService.keyAccount] ?? "", recoveryFile: recovery)
                    try Task.checkCancellation(); try AudioFiles.writePCM(pcm, to: url); try? DownloadReceipt.clear(recovery)
                }
                status = "对比音频已保存，可分别点击试听；再次对比相同文稿会复用。"
            } catch { self.error = Task.isCancelled ? nil : error.localizedDescription; status = "对比已停止，已完成试听保留。" }
        }
    }
}
