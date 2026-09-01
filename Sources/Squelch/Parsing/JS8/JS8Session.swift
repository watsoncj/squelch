import Foundation
import Combine

/// Main-thread owner of the JS8 receive side: feeds frames to the
/// assembler, publishes what's still arriving, and manages the word table.
final class JS8Session: ObservableObject {
    /// Messages still being received (a directed command waiting for its
    /// text, free text mid-transmission).
    @Published private(set) var pending: [JS8Receiver.Pending] = []
    @Published private(set) var wordTableInstalled: Bool
    @Published private(set) var wordTableStatus: String?
    @Published private(set) var installingWordTable = false

    private let receiver: JS8Receiver

    static let wordTableURL = URL(string: "https://raw.githubusercontent.com/JS8Call-improved/JS8Call-improved/HEAD/JS8_JSC/JSC_map.cpp")!

    init() {
        let dict = JS8Dictionary.installed
        receiver = JS8Receiver(dictionary: dict)
        wordTableInstalled = dict != nil
    }

    /// One slot's frames → completed messages.
    func ingest(results: [FT8Result], slotStart: Date, speed: DigiMode) -> [JS8Message] {
        let inputs = results.compactMap { r -> JS8Receiver.Input? in
            guard let frame = r.js8 else { return nil }
            return JS8Receiver.Input(frame: frame, offsetHz: r.freqHz, snr: r.snr, timeOffset: r.timeOffset,
                                     timestamp: slotStart, speed: speed)
        }
        let messages = receiver.ingest(inputs, now: slotStart.addingTimeInterval(speed.slotSeconds))
        pending = receiver.pending
        return messages
    }

    func reset() {
        pending = []
    }

    // MARK: Word table

    /// Install from a local JSC_map.cpp (or compact) file.
    func installWordTable(from url: URL) {
        installingWordTable = true
        wordTableStatus = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try JS8Dictionary.install(from: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installingWordTable = false
                switch result {
                case .success(let dict):
                    self.receiver.setDictionary(dict)
                    self.wordTableInstalled = true
                    self.wordTableStatus = "Installed \(dict.words.count) words"
                case .failure(let error):
                    self.wordTableStatus = error.localizedDescription
                }
            }
        }
    }

    /// Fetch JS8Call's table from its repository and install it.
    func downloadWordTable() {
        guard !installingWordTable else { return }
        installingWordTable = true
        wordTableStatus = "Downloading JSC_map.cpp (7 MB)…"
        let task = URLSession.shared.downloadTask(with: Self.wordTableURL) { [weak self] tmp, response, error in
            let outcome: Result<URL, Error> = {
                if let error { return .failure(error) }
                guard let tmp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                    return .failure(JS8Dictionary.LoadError.badTable("download failed"))
                }
                let dest = JS8Dictionary.sourceURL
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    return .success(dest)
                } catch {
                    return .failure(error)
                }
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let url):
                    self.installingWordTable = false
                    self.installWordTable(from: url)
                case .failure(let error):
                    self.installingWordTable = false
                    self.wordTableStatus = "Download failed: \(error.localizedDescription)"
                }
            }
        }
        task.resume()
    }
}
