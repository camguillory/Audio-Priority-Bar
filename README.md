# Audio Priority Bar

<p align="center">
  <img src="AudioPriorityBar/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="128" height="128" alt="Audio Priority Bar icon">
</p>

A native macOS menu bar app that automatically switches to your
highest-priority connected headphones, speakers, and microphone.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![MIT License](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="screenshot-light.png" width="49%" alt="Audio Priority Bar light panel showing automatic switching, volume, and three device priority lists">
  <img src="screenshot-dark.png" width="49%" alt="Audio Priority Bar dark panel showing automatic switching, volume, and three device priority lists">
</p>

## Features

- Automatic switching prefers your top available headphones, then speakers
- Persistent Speakers, Headphones, and Microphones priority lists
- One-click manual override from the app or macOS Sound Settings
- Volume control by slider or scroll wheel, with mute and availability status
- Drag ordering within lists and between output lists, with forbidden-drop feedback
- Per-list visibility controls, Never Auto-Select, and remembered devices
- Output categories taken from what each device reports, in any system language
- New HDMI and DisplayPort outputs start excluded, since a screen rarely is
  where you want sound
- Optional microphone switching with a matching physical USB output
- Settings, right-click quick actions, VoiceOver support, and Open at Login
- Jabra Link headset power-off detection, asked of the dongle rather than guessed

## Install

Requires macOS 14 Sonoma or later. Releases are universal for Apple silicon
and Intel Macs.

### Homebrew

```bash
brew install --cask camguillory/tap/audio-priority-bar
```

The fully qualified command trusts only this cask, not every current and future
item in the tap.

### Direct download

Download `AudioPriorityBar.zip` and `AudioPriorityBar.zip.sha256` from the
[latest release](https://github.com/camguillory/Audio-Priority-Bar/releases/latest)
into the same folder. Verify the archive before unzipping it:

```bash
cd ~/Downloads
shasum -a 256 -c AudioPriorityBar.zip.sha256
```

Move `AudioPriorityBar.app` to `/Applications`.

### Gatekeeper

Audio Priority Bar is ad-hoc signed, not signed with an Apple Developer ID or
notarized. If macOS blocks the first launch, open
**System Settings > Privacy & Security** and click **Open Anyway**.

Advanced users may instead remove only this app's quarantine attribute:

```bash
xattr -d com.apple.quarantine /Applications/AudioPriorityBar.app
```

### Build from source

```bash
git clone https://github.com/camguillory/Audio-Priority-Bar.git
cd Audio-Priority-Bar
./build.sh
```

The universal, ad-hoc-signed app is written to `dist/AudioPriorityBar.app`.
You can also open `AudioPriorityBar.xcodeproj` in Xcode and build with Command-R.

## Use

### Automatic and manual switching

- Automatic switching uses the first available headphone, then the first speaker.
- Selecting a device in the panel or macOS Sound Settings turns automatic
  switching off so that choice stays active.
- Turn automatic switching back on to resume priority-based selection.
- With **Move microphone with output** enabled, matching input and output
  halves of a physical USB headset switch together.

Speakers, Headphones, and Microphones remain visible in both modes.

### Device controls

- Drag outputs within or between Speakers and Headphones.
- Reorder microphones within Microphones.
- Use each row's actions menu for keyboard-accessible Move Up, Move Down, and
  Move to commands.
- Exclude a device from one output list or both, or keep it visible while
  preventing automatic selection.
- Use **Show all** to manage excluded and disconnected remembered devices.
- Forget a disconnected device to remove its saved settings.

A monitor or TV connected over HDMI or DisplayPort is excluded the first time
it is seen. Including one from **Show all** is permanent, and the
**Hide new HDMI and DisplayPort outputs** setting turns the behaviour off for
devices seen later. Whatever is currently playing always stays listed, even
when excluded, so you can see where the sound is going.

### Jabra Link monitoring

Jabra Link dongles remain visible to CoreAudio when their wireless headset is
powered off, so the app asks the dongle directly which remembered device is
connected and falls back to the next usable output when nothing is.

The dongle's simple HID link bit is not sufficient on its own. Roughly 1.8
seconds after USB enumeration the dongle asserts that a headset is linked,
identically whether one is powered on or off, and never corrects it. That is
why the app queries the dongle's vendor management channel instead, and keeps
the link bit only as a fallback and as a hint that something changed.

Transitions are not polled. The dongle announces a headset connecting or
disconnecting about 100ms after it happens, and that announcement triggers a
fresh query, so powering a headset off is reflected in well under a second. A
periodic refresh stays in place only for an announcement that never arrives.

A dongle is used this way whenever its HID descriptor exposes the management
collection and it answers the query, rather than because its model appears in a
list. Only a complete answer is trusted: a timeout, a malformed record or a
partial scan leaves the state unknown and the device selectable, so an
unrecognised dongle degrades instead of misbehaving. Link 380 is locally
hardware-verified, including USB replug and cold start with the headset off.
Link 390 is expected to work through the same capability check but has not been
verified on hardware; it retains the fallback measurements from
[tobi/AudioPriorityBar#32](https://github.com/tobi/AudioPriorityBar/pull/32).

Right after replugging a dongle while the headset is on, the app briefly
reports the headset as off. That is accurate: the wireless link takes a couple
of seconds to re-establish, and until it does audio sent there would not be
heard.

macOS may request **Input Monitoring** permission. Open at Login may separately
require approval in **System Settings > General > Login Items**.

### Upgrading from V1

V2 keeps the newer `app.audioprioritybar` bundle identifier and imports
recognized settings once from the public V1 identifier
`com.example.AudioPriorityBar`. Existing V2 settings take precedence. Because
the bundle identity changed, macOS may ask you to approve Input Monitoring or
Open at Login again.

## Contributing

Issues and pull requests are welcome. `main` reflects the latest release;
`develop` is the next version in progress.

For anything substantial, open an issue first so the approach can be agreed
before you spend time on it.

- Work from a fork rather than pushing to this repository.
- Branch from `develop` and open the pull request against `develop`. GitHub
  bases new pull requests on `main`, so switch it before submitting.
- Every pull request runs both Swift Testing suites and a universal build.
- Releases are tagged and published manually.

## License

[MIT License](LICENSE)

## Acknowledgments

Originally created by [tobi](https://github.com/tobi).

The Jabra GNP framing and pairing-record query are based on
[jabridge](https://github.com/Watchdog0x/jabridge) by Watchdog0x (Apache-2.0).

Built with SwiftUI, AppKit, CoreAudio, and IOKit.
