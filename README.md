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

- Automatic switching to your top available headphones, then speakers, with
  one-click manual override
- Persistent priority lists for Speakers, Headphones, and Microphones, with
  drag reordering
- Volume control by slider or scroll wheel, with mute and availability status
- Device visibility controls, Never Auto-Select, and remembered devices
- Output categories taken from what each device reports, in any system language
- Configurable paired selection for a physical USB headset's input and output
- Settings, right-click quick actions, VoiceOver support, and Open at Login
- Jabra Link headset power-off detection, asked of the dongle rather than guessed

## Install

Requires macOS 14 Sonoma or later. Releases are universal for Apple silicon
and Intel Macs.

### Homebrew

```bash
brew install --cask camguillory/tap/audio-priority-bar
```

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
- With **Select headset input and output together** enabled, choosing
  either half of a physical USB headset selects the other too.

Speakers, Headphones, and Microphones remain visible in both modes.

### Device controls

- Drag outputs within or between Speakers and Headphones.
- Reorder microphones within Microphones.
- Use each row's actions menu for keyboard-accessible Move Up, Move Down, and
  Move to commands.
- Hide a device to remove it from Speakers, Headphones, or Microphones, or
  keep it visible while blocking automatic selection with **Never
  Auto-Select**.
- Use **Show hidden and disconnected devices** to manage hidden and
  disconnected remembered devices.
- Forget a disconnected device to remove its saved settings.
- A device with a paired counterpart, like a USB headset's input and output
  halves, shows an override for the current default: **Mic only** or
  **Output only** while **Select headset input and output together** is on,
  or **Use both** while it's off. It appears only when picking it would
  change something.

New HDMI and DisplayPort outputs start hidden; showing one is permanent, and
**Hide new HDMI and DisplayPort outputs** turns this off for future devices.
The active device always stays listed, even when hidden.

### Jabra Link monitoring

The app asks a Jabra Link dongle directly whether its wireless headset is
powered off, since CoreAudio can't tell, and falls back automatically in
under a second. Right after replugging, it briefly shows the headset as off
while the wireless link re-establishes, which is expected, not a bug.

Link 380 is hardware-verified. Link 390 uses the same detection but is
unverified on hardware
([details](https://github.com/tobi/AudioPriorityBar/pull/32)). An
unrecognised dongle fails open rather than being treated as off.

May prompt for **Input Monitoring** permission. Open at Login may separately
need approval in **System Settings > General > Login Items**.

### Upgrading from V1

V2 imports V1 settings once on first launch (existing V2 values win). The new
bundle identifier may require re-approving Input Monitoring or Open at Login.

## Contributing

Issues and pull requests are welcome. Open an issue first for anything
substantial. `main` is the latest release; `develop` is next.

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
