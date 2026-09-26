import AppKit
import AudioPriorityCore
import Testing
@testable import AudioPriorityBar

@Test
func statusItemRoutesMouseAndAccessibilityEvents() {
    #expect(ClickRouting.action(for: .leftMouseUp) == .togglePanel)
    #expect(ClickRouting.action(for: .rightMouseUp) == .showMenu)
    #expect(ClickRouting.action(
        for: .leftMouseUp,
        modifiers: .control
    ) == .showMenu)
    #expect(ClickRouting.action(for: .leftMouseDown) == .togglePanel)
}

@Test
func optionClickTogglesMute() {
    #expect(ClickRouting.action(for: .leftMouseUp, modifiers: .option) == .toggleMute)
    #expect(ClickRouting.action(
        for: .leftMouseUp,
        modifiers: [.option, .control]
    ) == .showMenu)
    #expect(ClickRouting.action(for: .rightMouseUp, modifiers: .option) == .showMenu)
}

@Test
func statusItemSuppressionIsConsumeOnceAndExpires() {
    #expect(ClickRouting.shouldSuppressOpen(suppressedAt: 10, now: 10.5))
    #expect(!ClickRouting.shouldSuppressOpen(suppressedAt: 10, now: 12))
    #expect(!ClickRouting.shouldSuppressOpen(suppressedAt: nil, now: 10))
}

@Test
func noticesAndThePanelSitCenteredUnderTheStatusItemInsideTheScreen() {
    let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let size = NSSize(width: 200, height: 40)
    #expect(PanelPlacement.origin(
        buttonRect: NSRect(x: 500, y: 800, width: 20, height: 24),
        size: size,
        visibleFrame: visible
    ) == NSPoint(x: 410, y: 756))
    // Near the right edge the window stays 4 points inside the screen.
    #expect(PanelPlacement.origin(
        buttonRect: NSRect(x: 980, y: 800, width: 20, height: 24),
        size: size,
        visibleFrame: visible
    ).x == 796)
}

@Test
func aHeadsetSwitchingBothHalvesReadsAsOneDevice() {
    let jabraOut = output(1, "jabra:1", "Jabra Link 380")
    let jabraIn = input(2, "jabra:2", "Jabra Link 380")
    let mic = input(3, "builtin", "MacBook Pro Microphone")
    func notice(_ devices: [AudioDevice]) -> NoticeContent {
        NoticeContent.switched(to: devices) { $0.role == .input ? "mic" : "headphones" }
    }
    #expect(notice([jabraOut]) == NoticeContent(
        lines: [.init(icon: "headphones", text: "Jabra Link 380")],
        announcement: "Output: Jabra Link 380"
    ))
    #expect(notice([jabraOut, jabraIn]) == NoticeContent(
        lines: [.init(icon: "headphones", text: "Jabra Link 380")],
        announcement: "Output and microphone: Jabra Link 380"
    ))
    // The icons carry the role on screen; VoiceOver still hears it spoken.
    #expect(notice([jabraOut, mic]) == NoticeContent(
        lines: [
            .init(icon: "headphones", text: "Jabra Link 380"),
            .init(icon: "mic", text: "MacBook Pro Microphone"),
        ],
        announcement: "Output: Jabra Link 380, Microphone: MacBook Pro Microphone"
    ))
}

@Test
func aSwitchNoticeOutranksTheMutedReminderButNeverCoversThePanel() {
    let notice = NoticeContent(
        lines: [.init(icon: "airpodspro", text: "AirPods Pro")],
        announcement: "Output: AirPods Pro"
    )
    #expect(NoticeContent.current(
        switchNotice: notice, showsMutedReminder: true, isSuppressed: false
    ) == notice)
    #expect(NoticeContent.current(
        switchNotice: nil, showsMutedReminder: true, isSuppressed: false
    ) == .mutedWhileRecording)
    #expect(NoticeContent.current(
        switchNotice: notice, showsMutedReminder: true, isSuppressed: true
    ) == nil)
}
