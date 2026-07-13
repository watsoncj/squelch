import Foundation

/// Completed contacts, persisted as JSONL alongside the decode log.
final class QSOLog: ObservableObject {
    @Published private(set) var records: [QSORecord] = [] // newest first

    private let fileURL: URL
    private let encoder = JSONEncoder()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RadioFun", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("qsos.jsonl")
        encoder.dateEncodingStrategy = .iso8601
        load()
    }

    func append(_ record: QSORecord) {
        records.insert(record, at: 0)
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = content.split(separator: "\n")
            .compactMap { try? decoder.decode(QSORecord.self, from: Data($0.utf8)) }
            .reversed()
    }
}
