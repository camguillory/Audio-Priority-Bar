public enum HeadphoneDetection {
    private static let keywords = [
        "headphone", "headset", "earphone", "earbud", "earbuds", "buds", "pods",
        "airpods", "earpods", "beats", "powerbeats", "beatsx", "beats fit",
        "beats solo", "beats studio", "wh-1000", "wf-1000", "linkbuds", "inzone",
        "galaxy buds", "buds pro", "buds live", "buds fe", "quietcomfort",
        "qc ultra", "qc45", "qc35", "soundsport", "sport earbuds", "momentum",
        "hd 4", "hd 5", "pxc", "jabra", "elite", "evolve", "jbl tune",
        "jbl live", "jbl tour", "jbl reflect", "anker", "soundcore",
        "skullcandy", "nothing ear", "oneplus buds", "pixel buds",
        "huawei freebuds", "oppo enco", "technics eah", "bowers", "b&w px",
        "denon perl", "focal bathys", "hifiman", "shure aonic",
        "audio-technica ath", "beyerdynamic", "marshall", "bang & olufsen",
        "b&o", "akg", "plantronics", "poly", "razer", "steelseries", "hyperx",
        "logitech g pro", "astro", "corsair", "1more", "tozo", "edifier",
        "fiio", "moondrop",
    ]

    /// Product lines that are speakers even though a brand keyword above would
    /// otherwise claim them. Entries must name a product line, never a brand:
    /// excluding "marshall" or "anker" would misfile the headphones those same
    /// brands make.
    private static let speakerProducts = [
        "jabra speak",
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
