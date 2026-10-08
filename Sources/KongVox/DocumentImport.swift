import Foundation

struct ImportedDocument: Identifiable {
    var id = UUID()
    var title: String
    var text: String
}
struct ImportOptions { var omitURLs = true; var omitFootnotes = true }
enum DocumentImport {
    /// GB18030 (a superset of GBK/GB2312), common in older Chinese .txt files. Tried after UTF-8 and UTF-16.
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static func read(_ url: URL) throws -> ImportedDocument {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024 else { throw VoxError(message: "文稿文件超过 20 MB。") }
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "docx" {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", url.path, "word/document.xml"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() }; pipe.fileHandleForReading.closeFile() }
            var data = Data()
            while let part = try pipe.fileHandleForReading.read(upToCount: 65536), !part.isEmpty {
                guard data.count + part.count <= 16 * 1024 * 1024 else { throw VoxError(message: "Word 文稿正文过大。") }
                data.append(part)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw VoxError(message: "无法读取 Word 文稿，请使用未加密的 DOCX 文件。") }
            text = try wordText(data)
        } else {
            guard ["txt", "md", "markdown"].contains(ext) else { throw VoxError(message: "请选择 TXT、Markdown 或 DOCX 文稿。") }
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8) ?? ((data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])) ? String(data: data, encoding: .utf16) : String(data: data, encoding: gb18030)) else { throw VoxError(message: "文字编码无法识别（已尝试 UTF-8、UTF-16 与 GB18030），请另存为 UTF-8 文本。") }
            text = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200000 else { throw VoxError(message: "文稿为空或超过 20 万字，请拆成多份后导入。") }
        return ImportedDocument(title: url.deletingPathExtension().lastPathComponent, text: text)
    }
    static func clean(_ source: String, options: ImportOptions) -> String {
        var value = source.replacingOccurrences(of: "\r\n", with: "\n")
        func replace(_ pattern: String, _ template: String) {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
            }
        }
        if options.omitFootnotes {
            replace("(?m)^\\s*\\[\\^[^\\]]+\\]:[^\\n]*(?:\\n(?: {4}|\\t)[^\\n]*)*", "")
            replace("\\[\\^[^\\]]+\\]", "")
        }
        if options.omitURLs {
            replace("!?\\[([^\\]]*)\\]\\(https?://[^\\s)]+\\)", "$1")
            replace("https?://[^\\s<>，。；！？）]+", "")
        }
        replace("(?m)^\\s*```[^\\n]*$", "")
        replace("(?m)^\\s*>\\s?", "")
        replace("\\*\\*([^*]+)\\*\\*", "$1")
        replace("`([^`]+)`", "$1")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func wordText(_ data: Data) throws -> String {
        // Word's main document excludes headers and footnote bodies. Never resolve external entities.
        guard let source = String(data: data, encoding: .utf8), !source.uppercased().contains("<!DOCTYPE"), !source.uppercased().contains("<!ENTITY") else { throw VoxError(message: "Word 文稿结构不受支持。") }
        let delegate = WordParagraphParser(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw VoxError(message: "Word 正文结构损坏。") }
        return delegate.paragraphs.joined(separator: "\n\n")
    }
}
private final class WordParagraphParser: NSObject, XMLParserDelegate {
    var paragraphs: [String] = [], paragraph = "", inText = false, heading = false, deleted = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "w:del" { deleted += 1 }
        guard deleted == 0 else { return }
        if name == "w:p" { paragraph = ""; heading = false }
        if name == "w:pStyle", let style = attributes["w:val"]?.lowercased() { heading = style.hasPrefix("heading") || style.hasPrefix("标题") || style == "title" }
        if name == "w:t" { inText = true }
        if name == "w:tab" || name == "w:br" { paragraph += " " }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText && deleted == 0 { paragraph += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "w:del" { deleted -= 1; return }
        guard deleted == 0 else { return }
        if name == "w:t" { inText = false }
        if name == "w:p" {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append((heading ? "# " : "") + text) }
        }
    }
}
