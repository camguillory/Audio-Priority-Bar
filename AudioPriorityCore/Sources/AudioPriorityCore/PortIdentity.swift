import Foundation

/// The parts of a wired device UID that can be compared across reconnects.
/// Parsing alone doesn't prove that a USB UID contains a location rather than
/// a hexadecimal serial number. The live device must confirm that separately.
struct PortIdentity {
    let family: String
    let port: String
    let endpoint: String
    var usbLocation: UInt32?

    init?(_ uid: String) {
        let parts = uid.components(separatedBy: ":")
        if parts.count == 5, parts[0] == "AppleUSBAudioEngine" {
            let location = parts[3]
            let streams = parts[4].components(separatedBy: ",")
            guard !parts[1].isEmpty, !parts[2].isEmpty,
                  (1...8).contains(location.count), location.allSatisfy(\.isHexDigit),
                  let address = UInt32(location, radix: 16), address != 0,
                  streams.allSatisfy({ UInt32($0) != nil }) else { return nil }
            family = parts.prefix(3).joined(separator: ":")
            port = location
            endpoint = parts[4]
            usbLocation = address
        } else {
            let parts = uid.components(separatedBy: "_")
            guard (1...2).contains(parts.count), parts[0].count == 36,
                  parts[0] != "00000000-0000-0000-0000-000000000000",
                  let uuid = UUID(uuidString: parts[0]) else { return nil }
            if parts.count == 2 {
                guard parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit) else { return nil }
            }
            family = uuid.uuidString
            port = uid
            endpoint = ""
        }
    }
}
