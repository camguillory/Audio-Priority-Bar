import Foundation

/// Replaces what identifies a person or a unit in diagnostics and log lines
/// with short tags, and keeps what a reader needs to debug: vendor, model,
/// transport, roles and flags. One redactor covers one report, so the same
/// value gets the same tag on every line. Tags count up in the order values
/// first appear, so nothing in them leads back to the original.
public struct Redactor: Sendable {
    /// Device names known to the app, longest first, so an owner name of
    /// several words is replaced whole.
    private let deviceNames: [String]
    private var tags: [String: String] = [:]
    private var counts: [String: Int] = [:]

    public init(deviceNames: [String]) {
        self.deviceNames = Set(deviceNames).sorted { $0.count > $1.count }
    }

    public mutating func redact(_ text: String) -> String {
        var text = text
        // Bluetooth address, in a UID (AA-11-…) or the paired list (aa:11:…).
        text = text.replacing(/(?:[0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}/) { match in
            let value = match.output.uppercased().filter { $0 != "-" && $0 != ":" }
            return tag("bt", value)
        }
        // USB UID: vendor, model and channel stay, the serial goes.
        text = text.replacing(/(AppleUSBAudioEngine:[^:\]\n]*:[^:\]\n]*:)([^:\]\n]+)(:\d+)/) { match in
            "\(match.output.1)\(tag("serial", match.output.2.uppercased()))\(match.output.3)"
        }
        // HID serial, lowercase in the Jabra key and as reported in its
        // attach line, the same value as in the USB UID.
        text = text.replacing(/serial([: ])([0-9A-Za-z]{6,})/) { match in
            "serial\(match.output.1)\(tag("serial", match.output.2.uppercased()))"
        }
        // A display's UUID. Its `_00000030` stream suffix stays, so every
        // stream of one display shares a tag.
        text = text.replacing(/[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}/) { match in
            tag("uuid", match.output.uppercased())
        }
        // Quoted names first, which covers devices the app no longer knows,
        // then the known names wherever they stand unquoted. The other order
        // would read a tagged name as a new owner.
        text = text.replacing(/"([^"\n]+)"/) { match in
            "\"\(redactName(String(match.output.1)) ?? String(match.output.1))\""
        }
        for name in deviceNames where text.contains(name) {
            if let redacted = redactName(name) { text = text.replacing(name, with: redacted) }
        }
        // ponytail: an owner name left unquoted is caught by its last word
        // only, and a renamed device without a possessive, such as "Alex
        // Headphones", is not caught at all; covering those means tagging
        // every device name and losing the model with it.
        text = text.replacing(/(\p{Lu}[\p{L}\p{M}\-]*)([’']s )/) { match in
            "\(tag("owner", String(match.output.1)))\(match.output.2)"
        }
        return text
    }

    /// The name with its owner tagged, keeping the apostrophe as written, or
    /// nil when it names no owner: "Alex’s AirPods Pro" in English, "AirPods
    /// Pro de Alex" in French, Spanish, German and Italian.
    private mutating func redactName(_ name: String) -> String? {
        if let match = name.firstMatch(of: /^(.+?)([’']s )(.+)$/) {
            return "\(tag("owner", String(match.output.1)))\(match.output.2)\(match.output.3)"
        }
        if let match = name.firstMatch(of: /^(.+) (de|von|di) (\p{Lu}.*)$/),
           !match.output.3.contains("Mac") {
            return "\(match.output.1) \(match.output.2) \(tag("owner", String(match.output.3)))"
        }
        return nil
    }

    private mutating func tag(_ kind: String, _ value: String) -> String {
        let key = "\(kind):\(value)"
        if let existing = tags[key] { return existing }
        let number = counts[kind, default: 0] + 1
        counts[kind] = number
        let tag = "\(kind)\(number)"
        tags[key] = tag
        return tag
    }
}
