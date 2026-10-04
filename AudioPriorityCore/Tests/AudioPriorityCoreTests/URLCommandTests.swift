import Foundation
import Testing
@testable import AudioPriorityCore

private func command(_ string: String) -> URLCommand? {
    URL(string: string).flatMap(URLCommand.init(url:))
}

@Test
func theThreeMicrophoneURLsAreRecognised() {
    #expect(command("audioprioritybar://toggle-mic-mute") == .toggleMicMute)
    #expect(command("audioprioritybar://mute-mic") == .muteMic)
    #expect(command("audioprioritybar://unmute-mic") == .unmuteMic)
    #expect(command("AudioPriorityBar://Toggle-Mic-Mute") == .toggleMicMute)
}

@Test
func anythingBeyondTheExactFormIsRejected() {
    for rejected in [
        "https://toggle-mic-mute",
        "audioprioritybar://",
        "audioprioritybar://toggle-mic",
        "audioprioritybar://toggle-mic-mute/",
        "audioprioritybar://toggle-mic-mute/extra",
        "audioprioritybar://toggle-mic-mute?on=1",
        "audioprioritybar://toggle-mic-mute#now",
        "audioprioritybar://user@toggle-mic-mute",
        "audioprioritybar://toggle-mic-mute:8080",
        "audioprioritybar:toggle-mic-mute",
    ] {
        #expect(command(rejected) == nil, "\(rejected)")
    }
}
