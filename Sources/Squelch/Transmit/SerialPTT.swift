import Foundation
import CSerial

/// PTT keying via the Digirig's serial-port RTS line.
final class SerialPTT {
    private var fd: Int32 = -1

    var isOpen: Bool { fd >= 0 }

    /// Serial ports that could be the Digirig (its CP2102 shows up as
    /// cu.usbserial-XXXX or cu.SLAB_USBtoUART).
    static func availablePorts() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return all
            .filter { $0.hasPrefix("cu.") && $0 != "cu.debug-console" && $0 != "cu.wlan-debug" }
            .sorted()
            .map { "/dev/\($0)" }
    }

    /// Best guess at the PTT port. A CP2105 dual bridge (the FT-891's
    /// built-in USB) exposes two ports: interface 0 ("Enhanced") is CAT,
    /// interface 1 ("Standard") carries PTT-via-RTS — its device name sorts
    /// last, so prefer the last matching port.
    static func likelyPTTPort(in ports: [String]) -> String? {
        ports.last { $0.lowercased().contains("usbserial") || $0.contains("SLAB") }
    }

    func open(path: String) throws {
        guard fd < 0 else { return }
        fd = cserial_open(path)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Cannot open PTT port \(path): \(String(cString: strerror(errno)))",
            ])
        }
    }

    func key() {
        guard fd >= 0 else { return }
        _ = cserial_set_rts(fd, true)
    }

    func unkey() {
        guard fd >= 0 else { return }
        _ = cserial_set_rts(fd, false)
    }

    func close() {
        guard fd >= 0 else { return }
        cserial_close(fd)
        fd = -1
    }

    deinit {
        close()
    }
}
