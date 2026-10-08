import Foundation

/// Keep decimal points and closing quotation marks attached to their sentence.
enum SentenceText {
    static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var output: [String] = [], start = 0, i = 0
        while i < chars.count {
            let c = chars[i]
            let decimal = c == "." && i > 0 && i + 1 < chars.count && chars[i-1].isNumber && chars[i+1].isNumber
            let latinStop = c == "." && (i + 1 == chars.count || chars[i+1].isWhitespace || "\"'”’」』".contains(chars[i+1]))
            if !decimal && ("。！？!?；;".contains(c) || latinStop) {
                var end = i + 1
                while end < chars.count && "。！？!?；;\"'”’」』".contains(chars[end]) { end += 1 }
                while end < chars.count && chars[end].isWhitespace { end += 1 }
                output.append(String(chars[start..<end])); start = end; i = end
            } else { i += 1 }
        }
        if start < chars.count { output.append(String(chars[start...])) }
        return output.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func chunks(_ text: String, limit: Int) -> [LongChunker.Chunk] {
        var output: [LongChunker.Chunk] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let pieces = split(paragraph).flatMap { TextSplitter.split($0, limit: limit) }
            output += pieces.enumerated().map { LongChunker.Chunk(text: $0.element, paragraphEnd: $0.offset == pieces.count - 1) }
        }
        return output
    }
}

enum ReadingPreview {
    static func suggest(_ source: String) -> String {
        let pattern = #"\b[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}\b|[0-9]+(?:\.[0-9]+)?|[A-Z]{2,8}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.numberStyle = .spellOut
        func digits(_ value: String) -> String { value.map { c in c.wholeNumberValue.map { String(Array("零一二三四五六七八九")[$0]) } ?? String(c) }.joined() }
        func number(_ value: String) -> String {
            if value.count > 8 || (value.count > 1 && value.first == "0") { return digits(value) }
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            let whole = Int64(pieces[0]).flatMap { formatter.string(from: NSNumber(value: $0)) } ?? digits(String(pieces[0]))
            return whole + (pieces.count == 2 ? "点" + digits(String(pieces[1])) : "")
        }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range]), date = token.split(separator: "-")
            let replacement: String
            if date.count == 3, let month = Int(date[1]), let day = Int(date[2]), (1...12).contains(month), (1...31).contains(day) {
                replacement = digits(String(date[0])) + "年" + number(String(month)) + "月" + number(String(day)) + "日"
            } else if token.first?.isNumber == true { replacement = number(token) }
            else { replacement = token.map(String.init).joined(separator: " ") }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

struct PreflightIssue: Identifiable {
    var id = UUID()
    var message: String
    var blocking: Bool
}
enum ServicePreflight {
    static func inspect(_ project: Project, catalog: ServiceCatalog) -> [PreflightIssue] {
        let service = project.settings.resolvedService
        var result: [PreflightIssue] = []
        func add(_ message: String, _ blocking: Bool = true) { result.append(PreflightIssue(message: message, blocking: blocking)) }
        do { _ = try service.validated() } catch { add(error.localizedDescription) }
        if let current = catalog.profiles.first(where: { $0.id == service.id }) {
            if !current.enabled { add("服务已停用。") }
            if current != service { add("服务配置已改变，请先应用最新服务配置。") }
        } else { add("服务不存在，请重新选择。") }
        if !service.voices.contains(project.settings.voice) { add("声音不在此服务的配置列表中，请重新选择音色。") }
        for (index, segment) in project.segments.enumerated() {
            let settings = segment.effectiveSettings(project.settings), text = settings.reading(segment.spokenText)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > project.chunkLimit || text.utf8.count > 12000 { add("第 \(index + 1) 段朗读文本为空或超过服务长度限制。") }
            if !settings.speed.isFinite || !(0.7...1.3).contains(settings.speed) { add("第 \(index + 1) 段语速超出 0.7–1.3 倍范围。") }
        }
        if !service.modelPresets.contains(service.model) { add("使用自定义模型，需自行核对模型与音色权限。", false) }
        if service.kind == .volcengine && service.model != "seed-tts-2.0" && project.settings.voice == "zh_female_vv_uranus_bigtts" { add("VV 默认音色搭配 2.0 资源；请核对当前资源与音色版本。", false) }
        if service.kind == .qwenTTS && !service.model.contains("instruct") { add("此 Qwen 标准模型不应用语速与表达要求。", false) }
        if service.kind == .volcengine && !project.settings.direction.isEmpty { add("火山引擎当前不发送表达要求。", false) }
        if project.settings.contextHintEnabled == true && service.kind == .volcengine { add("当前火山引擎接口不接收前后句语气提示；本次仍只生成目标句。", false) }
        return result
    }
}

struct CompletionReport {
    var lines: [String]
    static func make(_ project: Project, root: URL) -> CompletionReport {
        var p = project; if p.isLongMode { p.prepareLongDocument() }
        func ready(_ s: Segment) -> Bool {
            s.ready(p.settings) && s.current.map { FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio/" + $0.file).path) } == true
        }
        let complete = p.segments.filter(ready).count
        let textCount = p.isLongMode ? p.fullText.count : p.segments.reduce(p.draft.count) { $0 + $1.text.count }
        var lines = ["当前文稿：\(textCount) 字 · \(p.segments.count) 个处理片段", "已就绪：\(complete) / \(p.segments.count)"]
        if !p.draft.isEmpty { lines.append("有尚未添加的草稿，请先添加为配音段落。") }
        if let first = p.segments.first { lines.append("开头：" + (ready(first) ? "音频已保存" : "缺失或待更新")) }
        if let last = p.segments.last { lines.append("结尾：" + (ready(last) ? "音频已保存" : "缺失或待更新")) }
        for chapter in p.chapters {
            let parts = p.segments.filter { chapter.segmentIDs.contains($0.id) }
            lines.append("\(chapter.title)：\(parts.filter(ready).count) / \(parts.count) 已就绪")
        }
        if p.segments.isEmpty { lines.append("文稿为空，尚无可检查的内容。") }
        lines.append("检查依据为当前文稿与本地文件；不推断尚未导入的章节，也不判定逐字漏读。")
        return CompletionReport(lines: lines)
    }
}
