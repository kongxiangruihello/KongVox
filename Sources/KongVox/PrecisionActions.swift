import SwiftUI

extension Studio {
    func savePrecision(_ id: UUID, pronunciation: String, speed: Double?, pause: Double?) {
        guard speed.map({ $0.isFinite && (0.7...1.3).contains($0) }) ?? true,
              pause.map({ $0.isFinite && (0...3).contains($0) }) ?? true else { error = "语速或停顿超出范围。"; return }
        edit { p in
            guard let i = p.segments.firstIndex(where: { $0.id == id }) else { return }
            p.segments[i].pronunciation = pronunciation
            p.segments[i].speedOverride = speed; p.segments[i].pauseOverride = pause
        }
    }
    func checkConfiguration() {
        guard !isWorking, var p = project else { return }
        if p.isLongMode { p.prepareLongDocument() }
        let issues = ServicePreflight.inspect(p, catalog: catalog)
        var lines = issues.map { ($0.blocking ? "需修正：" : "提示：") + $0.message }
        if !issues.contains(where: \.blocking) {
            do {
                let key = try keyProvider(p.settings.resolvedService)
                if key.isEmpty { lines.append("需修正：此服务尚未保存 API Key。") }
                else {
                    let sample = p.segments.first ?? Segment(text: "配置检查")
                    _ = try client.request(text: p.settings.reading(sample.spokenText), settings: sample.effectiveSettings(p.settings), key: key)
                    lines.append("本地请求格式与密钥读取正常。")
                }
            } catch { lines.append("需修正：" + error.localizedDescription) }
        }
        lines.append("未联网验证密钥有效性、额度和模型/音色权限；这些需通过真实试听确认。")
        preflightMessage = lines.joined(separator: "\n")
    }
    func enableSentenceEditing() {
        guard !isWorking, let p = project else { return }
        guard p.segments.allSatisfy({ $0.pronunciation.isEmpty && $0.speedOverride == nil && $0.pauseOverride == nil }) else {
            error = "项目存在读法、语速或停顿精修。请先备份并清除这些设置，再切换按句精修，避免拆分后丢失对应关系。"; return
        }
        edit { p in
            if !p.isLongMode { p.longText = (p.segments.map(\.text) + (p.draft.isEmpty ? [] : [p.draft])).joined(separator: "\n\n") }
            p.sentenceEditing = true; p.prepareLongDocument()
        }
        status = "已按句准备；可复用的音频保留，需更新的句子将在生成前列出。"
    }
}
