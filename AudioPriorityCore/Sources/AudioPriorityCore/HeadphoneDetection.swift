public enum HeadphoneDetection {
    private static let keywords = [
        "headphone", "headset", "earphone", "earbud", "earbuds", "buds", "pods",
        "airpods", "earpods", "beats", "powerbeats", "beatsx", "beats fit",
        "beats solo", "beats studio", "wh-1000", "wf-1000", "linkbuds", "inzone",
        "galaxy buds", "buds pro", "buds live", "buds fe", "quietcomfort",
        "qc ultra", "qc45", "qc35", "soundsport", "sport earbuds", "momentum",
        "hd 4", "hd 5", "pxc", "jabra", "elite", "evolve", "jbl tune",
        "jbl live", "jbl tour", "jbl reflect",
        "soundcore space", "soundcore life", "soundcore liberty",
        "soundcore aerofit", "soundcore sleep", "soundcore q", "soundcore p",
        "powerconf h", "ankerwork h",
        "skullcandy", "nothing ear", "oneplus buds", "pixel buds",
        "huawei freebuds", "oppo enco", "technics eah",
        "b&w px", "px5", "px7", "px8", "pi5", "pi7", "pi8",
        "denon perl", "focal bathys", "hifiman", "shure aonic",
        "audio-technica ath", "beyerdynamic",
        "marshall major", "marshall monitor", "marshall minor", "marshall motif",
        "beoplay h", "beoplay portal", "beoplay ex", "beoplay eq", "beoplay eleven",
        "akg", "plantronics", "poly",
        "blackshark", "kraken", "barracuda", "hammerhead", "razer opus", "razer kaira",
        "steelseries", "hyperx", "logitech g pro",
        "astro a10", "astro a20", "astro a30", "astro a40", "astro a50", "astro mixamp",
        "corsair hs", "corsair virtuoso", "corsair void",
        "1more", "tozo", "edifier w", "stax spirit",
        "fiio btr", "fiio utws", "fiio fw", "fiio eh", "moondrop",
    ]

    /// Product lines that are speakers even though a brand keyword above or a
    /// USB headset terminal would otherwise claim them. Entries must name a
    /// product line, never a brand: excluding "jabra" or "poly" would misfile
    /// the headsets those same brands make.
    private static let speakerProducts = [
        "homepod",
        "jabra speak",
        "poly sync",
        "calisto",
    ]

    public static func isHeadphone(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return keywords.contains { normalized.contains($0) }
    }

    /// A product known to be a speaker regardless of what it reports about
    /// itself. CoreAudio has no speakerphone terminal type, so a speakerphone
    /// may describe itself as headphones, and only the product line settles it.
    public static func isKnownSpeaker(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return speakerProducts.contains { normalized.contains($0) }
    }
}
