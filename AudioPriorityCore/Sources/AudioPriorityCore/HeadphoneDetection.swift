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

    public static func isHeadphone(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return keywords.contains { normalized.contains($0) }
    }
}
