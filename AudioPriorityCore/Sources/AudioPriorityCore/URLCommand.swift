import Foundation

/// An `audioprioritybar://` URL, as opened by Shortcuts, Raycast or a Stream
/// Deck. Any app or web page can open one, so only these exact forms are
/// accepted: no path, query, fragment, user or port.
public enum URLCommand: String, CaseIterable, Sendable {
    case toggleMicMute = "toggle-mic-mute"
    case muteMic = "mute-mic"
    case unmuteMic = "unmute-mic"

    public static let scheme = "audioprioritybar"

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme,
              parts.path.isEmpty,
              parts.query == nil,
              parts.fragment == nil,
              parts.user == nil,
              parts.password == nil,
              parts.port == nil,
              let host = parts.host?.lowercased() else {
            return nil
        }
        self.init(rawValue: host)
    }
}
