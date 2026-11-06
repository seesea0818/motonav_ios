import Foundation

struct LyricsTrack: Equatable {
    // Foundation 使用 ICU 转换标识，兼容简繁中文搜索。
    private static let chineseTransform = StringTransform(rawValue: "Traditional-Simplified")
    let title: String, artist: String, album: String
    let duration: Double
    // 有些播放器把“歌名 - 歌手”放在标题，并用歌手字段推送当前歌词。
    static func lookupIdentity(title: String, artist: String) -> (title: String, artist: String) {
        for separator in [" — ", " – ", " - ", "—", "–"] {
            let parts = title.components(separatedBy: separator)
            if parts.count == 2 {
                let song = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let singer = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !song.isEmpty && !singer.isEmpty { return (song, singer) }
            }
        }
        return (title, artist)
    }
    var key: String { "\(title)\n\(artist)\n\(album)\n\(duration)" }
    var url: URL? {
        guard !title.isEmpty, !artist.isEmpty, duration.isFinite, (1...3600).contains(duration) else { return nil }
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "duration", value: String(duration))]
        if !album.isEmpty { url.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        return url.url
    }
    // 精确查询没有结果时，用简体和繁体搜索候选，不携带专辑筛选。
    var searchURLs: [URL] {
        let variants = [(title, artist),
                        (title.applyingTransform(Self.chineseTransform, reverse: true) ?? title,
                         artist.applyingTransform(Self.chineseTransform, reverse: true) ?? artist)]
        var seen = Set<String>()
        return variants.compactMap { pair in
            let (title, artist) = pair
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            components.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
            guard let url = components.url, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
    func matches(title: String, artist: String, album: String, duration: Double) -> Bool {
        func normalized(_ text: String) -> String {
            (text.applyingTransform(Self.chineseTransform, reverse: false) ?? text)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        return duration.isFinite && abs(self.duration - duration) <= 2.1 && normalized(self.title) == normalized(title)
            && normalized(self.artist) == normalized(artist)
            && (self.album.isEmpty || album.isEmpty || normalized(self.album) == normalized(album))
    }
    // 搜索候选的专辑可能是合辑，但歌曲、歌手和时长仍需严格一致。
    func matchesSearch(title: String, artist: String, duration: Double) -> Bool {
        matches(title: title, artist: artist, album: "", duration: duration)
    }
}

struct MediaPlaybackClock {
    let state: Int, rate: Double, elapsed: Double, anchor: TimeInterval
    init?(_ text: String, now: TimeInterval) {
        let p = text.split(separator: ",", omittingEmptySubsequences: false)
        guard p.count == 3, let state = Int(p[0]), (0...3).contains(state), let rate = Double(p[1]), rate.isFinite,
              let elapsed = Double(p[2]), elapsed.isFinite, elapsed >= 0 else { return nil }
        self.state = state; self.rate = rate; self.elapsed = elapsed; anchor = now
    }
    func position(now: TimeInterval, duration: Double) -> Double {
        // Paused clocks stay fixed even if the player supplied an old non-zero rate.
        let movement = state == 0 ? 0 : rate * max(0, now - anchor)
        return min(max(0, elapsed + movement), max(0, duration))
    }
}

struct LyricsTimeline {
    struct Cue: Equatable { let time: Double; let text: String }
    let cues: [Cue]
    init(_ lrc: String) {
        guard lrc.utf8.count <= 128 * 1024 else { cues = []; return }
        let stamp = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]"#)
        let offsetTag = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        var offset: Double = 0
        if let m = offsetTag.firstMatch(in: lrc, range: NSRange(lrc.startIndex..., in: lrc)),
           let r = Range(m.range(at: 1), in: lrc), let milliseconds = Double(lrc[r]), abs(milliseconds) <= 300_000 { offset = milliseconds / 1000 }
        var lines: [(Double, Int, String)] = []
        for (order, raw) in lrc.components(separatedBy: .newlines).prefix(3000).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces); var times: [Double] = []
            while let m = stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), times.count < 32 {
                let ns = line as NSString
                let minutes = Double(ns.substring(with: m.range(at: 1)))!, seconds = Double(ns.substring(with: m.range(at: 2)))!
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound { let digits = ns.substring(with: m.range(at: 3)); fraction = Double(digits)! / pow(10, Double(digits.count)) }
                times.append(max(0, minutes * 60 + seconds + fraction + offset))
                line = ns.substring(from: m.range.length)
            }
            let text = String(line.trimmingCharacters(in: .whitespaces).prefix(400))
            for time in times { lines.append((time, order, text)) }
        }
        lines.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var merged: [Cue] = []
        for (time, _, text) in lines {
            if let last = merged.last, last.time == time {
                if !text.isEmpty && !last.text.components(separatedBy: " / ").contains(text) {
                    merged[merged.count - 1] = Cue(time: time, text: last.text.isEmpty ? text : last.text + " / " + text)
                }
            } else { merged.append(Cue(time: time, text: text)) }
        }
        cues = merged
    }
    func line(at seconds: Double) -> String {
        lines(at: seconds).current
    }
    // 按时间定位当前歌词及相邻两句，开始前不显示未来歌词。
    func lines(at seconds: Double) -> (previous: String, current: String, next: String) {
        guard seconds.isFinite, seconds >= 0 else { return ("", "", "") }
        var low = 0, high = cues.count
        while low < high { let mid = (low + high) / 2; if cues[mid].time <= seconds { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return ("", "", "") }
        return (low >= 2 ? cues[low - 2].text : "", cues[low - 1].text, low < cues.count ? cues[low].text : "")
    }
    // 返回当前句和其后四句，时间未到第一句时保持空白。
    func upcoming(at seconds: Double) -> [String] {
        guard seconds.isFinite, seconds >= 0 else { return Array(repeating: "", count: 5) }
        var low = 0, high = cues.count
        while low < high { let mid = (low + high) / 2; if cues[mid].time <= seconds { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return Array(repeating: "", count: 5) }
        return (0..<5).map { offset in let i = low - 1 + offset; return i < cues.count ? cues[i].text : "" }
    }
}
