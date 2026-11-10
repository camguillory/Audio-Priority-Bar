import Foundation
import Testing
@testable import AudioPriorityCore

@MainActor
private func withLogFolder(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "DebugLogTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

/// Noon on 1 November 2026 plus `days`, so a daylight saving change never
/// moves a line to another date.
private func noon(plus days: Int) throws -> Date {
    try #require(Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 1 + days, hour: 12)
    ))
}

@Test @MainActor
func theDebugLogWritesNothingUntilTurnedOn() throws {
    try withLogFolder { folder in
        let date = try noon(plus: 2)
        let log = DebugLog(directory: folder, now: { date })
        log.write("hidden")
        #expect(log.files.isEmpty)

        log.isEnabled = true
        log.write("output switched")
        #expect(log.files.map(\.lastPathComponent) == ["debug-2026-11-03.log"])
        let text = try String(contentsOf: try #require(log.files.first), encoding: .utf8)
        #expect(text.hasSuffix(" output switched\n"))
        #expect(!text.contains("hidden"))
        // Starts with a timestamp, to the millisecond, such as
        // 2026-11-03T12:00:00.000+0100.
        #expect(text.firstMatch(of: /^2026-11-03T12:00:00\.000/) != nil)
    }
}

@Test @MainActor
func theDebugLogStartsAFileEachDayAndKeepsAWeek() throws {
    try withLogFolder { folder in
        var date = try noon(plus: 0)
        let log = DebugLog(directory: folder, now: { date })
        log.isEnabled = true
        for day in 0..<10 {
            date = try noon(plus: day)
            log.write("day \(day)")
            log.write("again on day \(day)")
        }
        #expect(log.files.map(\.lastPathComponent) == (4...10).map {
            "debug-2026-11-\(String(format: "%02d", $0)).log"
        })
        #expect(log.lastMessage == "again on day 9")
    }
}

@Test @MainActor
func theDebugLogDropsItsOldestDaysToStayUnderItsCap() throws {
    try withLogFolder { folder in
        var date = try noon(plus: 0)
        let log = DebugLog(directory: folder, maxBytes: 300, now: { date })
        log.isEnabled = true
        for day in 0..<5 {
            date = try noon(plus: day)
            for line in 0..<3 { log.write("day \(day) line \(line)") }
        }
        #expect(log.totalSize <= 300)
        #expect(log.files.count < 5)
        #expect(log.lastMessage == "day 4 line 2")
    }
}

@Test @MainActor
func clearingTheDebugLogDeletesEveryDay() throws {
    try withLogFolder { folder in
        var date = try noon(plus: 0)
        let log = DebugLog(directory: folder, now: { date })
        log.isEnabled = true
        log.write("first day")
        date = try noon(plus: 1)
        log.write("second day")
        #expect(log.files.count == 2)

        log.clear()
        #expect(log.files.isEmpty)
        #expect(log.totalSize == 0)
        #expect(log.lastMessage == nil)
        log.write("after clearing")
        #expect(log.lastMessage == "after clearing")
    }
}

@Test
func aTransportTypeReadsAsItsFourCharacters() {
    var device = AudioDevice(platformID: 1, uid: "a", name: "A", role: .output)
    device.transportType = 0x626c_7565
    #expect(device.transportCode == "blue")
    device.transportType = 0
    #expect(device.transportCode == "0")
}
