import Foundation

struct ManuscriptChange {
    let text: String
    let added: Bool
    let offset: Int?

    static func compare(_ original: String, _ current: String) -> [ManuscriptChange] {
        let before = original.components(separatedBy: "\n")
        let after = current.components(separatedBy: "\n")
        var offsets = [0]
        for line in after { offsets.append(offsets[offsets.count - 1] + line.utf16.count + 1) }
        let diff = after.difference(from: before)
        let removals = Dictionary(uniqueKeysWithValues: diff.removals.compactMap { change -> (Int, String)? in
            guard case let .remove(index, text, _) = change else { return nil }
            return (index, text)
        })
        let additions = Dictionary(uniqueKeysWithValues: diff.insertions.compactMap { change -> (Int, String)? in
            guard case let .insert(index, text, _) = change else { return nil }
            return (index, text)
        })
        var old = 0, new = 0
        var results = [ManuscriptChange]()
        while old < before.count || new < after.count {
            if let text = removals[old] {
                let anchor = new < after.count ? offsets[new] : current.utf16.count
                results.append(.init(text: text, added: false, offset: anchor))
                old += 1
            } else if let text = additions[new] {
                results.append(.init(text: text, added: true, offset: offsets[new]))
                new += 1
            } else {
                old += 1
                new += 1
            }
        }
        return results
    }
}
