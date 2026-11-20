# Privacy

Audio Priority Bar collects no data. There is no account, analytics, or
telemetry, and your settings stay in the app's local preferences.

Local builds have no update feed. In releases configured for automatic updates,
Sparkle checks the release host daily and downloads available updates. Like any
HTTPS request, the host receives the connecting IP address. Sparkle's default
user agent includes the app and updater versions. You can turn automatic
updates off in Settings.

The app requests Bluetooth access when you use the panel to connect or
disconnect a paired device. It reads Bluetooth inventory and battery levels
locally. With a compatible Jabra Link dongle, Input Monitoring allows it to
read headset link, battery and call-control events. It can also change headset
settings such as the busylight. Optional Accessibility access checks whether
the pointer is on the menu bar icon before showing its preview. The
**Microphone muted** reminder reads microphone activity and, where macOS makes
it available, the name of the recording app. It never reads audio samples.

**Keep a debug log** is off unless you turn it on in Settings. It writes your
device names, recognized URL command names, what you click in the app and what the app did to
`~/Library/Logs/Audio Priority Bar` on your Mac, one file per day, and keeps
the last 7 days. **Clear** in Settings deletes them. The app never sends the
log anywhere; attach it to an issue only if you choose to. **Export Redacted
Log** saves a copy to Downloads, and it and **Copy Diagnostics** replace owner
names in device names, Bluetooth addresses, serial numbers and display IDs
with short tags. A device you renamed without a possessive, such as "Alex
Headphones", keeps its name.

Questions: [open an issue](https://github.com/camguillory/Audio-Priority-Bar/issues).
