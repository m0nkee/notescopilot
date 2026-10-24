import Foundation

enum NotesTemplateImporter {
    struct Result {
        let templates: [TemplateNote]
        let addedCount: Int
        let skippedCount: Int
    }

    /// Import is explicit and additive: an existing local template is never overwritten.
    static func merging(_ candidates: [(name: String, content: String)], into existing: [TemplateNote]) -> Result {
        var templates = existing
        var names = Set(existing.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var skipped = 0
        for candidate in candidates {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !content.isEmpty, names.insert(name.lowercased()).inserted else { skipped += 1; continue }
            templates.append(TemplateNote(name: name, content: candidate.content))
        }
        return Result(templates: templates, addedCount: templates.count - existing.count, skippedCount: skipped)
    }

    static func read(from store: NotesStore) -> [(name: String, content: String)] {
        store.folders().filter { $0.name.caseInsensitiveCompare("Templates") == .orderedSame }
            .flatMap { folder in store.notes(folderPK: folder.pk) }
            .compactMap { note in
                let content = store.content(for: note)
                guard content.isComplete else { return nil }
                return (name: note.title, content: content.markdown)
            }
    }
}
