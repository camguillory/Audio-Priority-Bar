import Foundation

/// Caches a decoded preference while still observing writes made by another
/// store. A damaged row never prevents its valid neighbours from loading.
final class StoredRecords<Record: Codable> {
    let key: String
    private var data: Data?
    private var records: [Record] = []

    init(key: String) { self.key = key }

    func read(from defaults: UserDefaults) -> [Record] {
        let source = defaults.data(forKey: key)
        guard source != data else { return records }
        data = source
        guard let source else {
            records = []
            return records
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([Record].self, from: source) {
            records = decoded
        } else {
            // Preserve the exact input before an edit or a new device can
            // replace it. Keep distinct failures, including unparseable JSON.
            let archiveKey = key + ".unreadable"
            var originals = defaults.array(forKey: archiveKey) as? [Data] ?? []
            if !originals.contains(source) {
                originals.append(source)
                defaults.set(originals, forKey: archiveKey)
            }
            let rows = try? decoder.decode([RecoverableRecord<Record>].self, from: source)
            records = rows?.compactMap(\.value) ?? []
        }
        return records
    }

    func save(_ values: [Record], to defaults: UserDefaults) {
        guard let encoded = try? JSONEncoder().encode(values) else { return }
        defaults.set(encoded, forKey: key)
        records = values
        data = encoded
    }
}

private struct RecoverableRecord<Record: Decodable>: Decodable {
    let value: Record?
    init(from decoder: Decoder) throws { value = try? Record(from: decoder) }
}
