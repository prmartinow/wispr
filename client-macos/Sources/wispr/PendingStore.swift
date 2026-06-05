import Foundation

struct PendingItem: Codable, Identifiable {
    let id: UUID
    let file: String
    let date: Date
    let reason: String
}

/// Failed takes, buffered to disk so a transient outage never loses your speech.
/// Stored as WAV files under Application Support + a small index; retried via batch later.
final class PendingStore: ObservableObject {
    @Published private(set) var items: [PendingItem] = []
    private let dir: URL
    private let indexURL: URL
    private let cap = 30

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wispr/pending", isDirectory: true)
        PrivateFiles.ensureDirectory(base)
        dir = base
        indexURL = base.appendingPathComponent("index.json")
        PrivateFiles.lockDownIfPresent(indexURL)
        load()
    }

    var count: Int { items.count }
    func oldest() -> PendingItem? { items.last }
    func wav(for item: PendingItem) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(item.file)) }

    func add(wav: Data, reason: String) {
        let item = PendingItem(id: UUID(), file: "\(UUID().uuidString).wav", date: Date(), reason: reason)
        try? PrivateFiles.write(wav, to: dir.appendingPathComponent(item.file))
        items.insert(item, at: 0)
        while items.count > cap, let dropped = items.popLast() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(dropped.file))
        }
        save()
    }

    func remove(_ item: PendingItem) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.file))
        items.removeAll { $0.id == item.id }
        save()
    }

    private func load() {
        if let d = try? Data(contentsOf: indexURL), let arr = try? JSONDecoder().decode([PendingItem].self, from: d) {
            items = arr
        }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? PrivateFiles.write(d, to: indexURL) }
    }
}
