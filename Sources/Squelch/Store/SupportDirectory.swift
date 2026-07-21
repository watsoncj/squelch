import Foundation

/// Application Support/Squelch — migrating the RadioFun-era directory
/// (decode log, QSO log, geocode cache) on first use after the rename.
func squelchSupportDirectory() -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Squelch", isDirectory: true)
    let legacy = base.appendingPathComponent("RadioFun", isDirectory: true)
    if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
        try? fm.moveItem(at: legacy, to: dir)
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
