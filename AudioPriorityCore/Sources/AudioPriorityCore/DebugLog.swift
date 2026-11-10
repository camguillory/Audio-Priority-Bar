import Foundation

/// A plain text record of what the app saw and did, written only while the
/// user keeps it on, so a bug report can show the order things happened in.
/// One file per day, named by its date, so the day a problem happened is easy
/// to find. Each line goes straight to the file, so the lines before a crash
/// survive.
/// ponytail: writes on the main actor; a burst of hundreds of lines a second
/// would want a background queue.
@MainActor
public final class DebugLog {
    public static let shared = DebugLog(
        directory: URL.libraryDirectory.appending(path: "Logs/Audio Priority Bar")
    )

    public let directory: URL
    public let keptDays: Int
    public var isEnabled = false {
        didSet { if !isEnabled { close() } }
    }

    private let maxBytes: Int
    private let now: () -> Date
    private var handle: FileHandle?
    private var handleURL: URL?
    /// Every kept day's size, counted as lines are written so the cap needs
    /// no directory listing.
    private var totalBytes = 0
    private let timestamp = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .current
    )
    private let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    public init(
        directory: URL,
        keptDays: Int = 7,
        maxBytes: Int = 20_000_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.keptDays = keptDays
        self.maxBytes = maxBytes
        self.now = now
    }

    /// The day files, oldest first.
    public var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("debug-") && $0.hasSuffix(".log") }
            .sorted()
            .map { directory.appending(path: $0) }
    }

    public var totalSize: Int { files.reduce(0) { $0 + Self.size(of: $1) } }

    public func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let date = now()
        let line = Data("\(date.formatted(timestamp)) \(message())\n".utf8)
        guard let handle = try? openHandle(for: date) else { return }
        if totalBytes + line.count > maxBytes {
            prune(keepingFrom: date, room: line.count)
            // ponytail: a single day over the cap starts that day over, which
            // only a runaway writing 20 MB in one day reaches; keeping the
            // day's newest half would need a rewrite of the file.
            if totalBytes + line.count > maxBytes {
                try? handle.truncate(atOffset: 0)
                totalBytes = 0
            }
        }
        try? handle.write(contentsOf: line)
        totalBytes += line.count
    }

    /// Deletes every day file. Writing again starts a new one.
    public func clear() {
        close()
        for url in files { try? FileManager.default.removeItem(at: url) }
        totalBytes = 0
    }

    /// The newest line's message, without its timestamp, or nil when the log
    /// is empty or missing.
    public var lastMessage: String? {
        guard let newest = files.last,
              let reader = try? FileHandle(forReadingFrom: newest) else { return nil }
        defer { try? reader.close() }
        let size = (try? reader.seekToEnd()) ?? 0
        try? reader.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? reader.readToEnd(),
              let line = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").last else { return nil }
        return line.split(separator: " ", maxSplits: 1).last.map(String.init)
    }

    /// The day's file, opened when the day changes and reopened when it was
    /// deleted in Finder while the log is on.
    private func openHandle(for date: Date) throws -> FileHandle {
        let url = directory.appending(path: "debug-\(date.formatted(day)).log")
        let files = FileManager.default
        if let handle, handleURL == url, files.fileExists(atPath: url.path) { return handle }
        close()
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            files.createFile(atPath: url.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        handle = opened
        handleURL = url
        prune(keepingFrom: date)
        return opened
    }

    /// Deletes the days before the kept ones, then the oldest days until
    /// `room` more bytes fit under the cap, never the day being written.
    private func prune(keepingFrom date: Date, room: Int = 0) {
        let first = date.addingTimeInterval(-Double(keptDays - 1) * 86_400)
        let cutoff = "debug-\(first.formatted(day)).log"
        var kept: [URL] = []
        for url in files {
            if url.lastPathComponent < cutoff {
                try? FileManager.default.removeItem(at: url)
            } else {
                kept.append(url)
            }
        }
        totalBytes = kept.reduce(0) { $0 + Self.size(of: $1) }
        while totalBytes + room > maxBytes, kept.count > 1, kept[0] != handleURL {
            let oldest = kept.removeFirst()
            totalBytes -= Self.size(of: oldest)
            try? FileManager.default.removeItem(at: oldest)
        }
    }

    private static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func close() {
        try? handle?.close()
        handle = nil
        handleURL = nil
    }
}

public extension AudioDevice {
    /// The name a reader recognizes and the UID every setting is keyed by.
    var logName: String { "\"\(name)\" [\(uid)]" }

    /// CoreAudio's transport type as its four characters, such as `blue`.
    var transportCode: String {
        let bytes = withUnsafeBytes(of: transportType.bigEndian, Array.init)
        return bytes.allSatisfy({ (0x20...0x7e).contains($0) })
            ? String(decoding: bytes, as: UTF8.self)
            : String(transportType)
    }
}
