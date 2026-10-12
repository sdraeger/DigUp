import Foundation

/// What a query says, in plain words, about which files to look in, apart from what's in them: "PDFs from March about
/// the lease" looks for the lease, in PDFs, from March. A date filters by when a file was changed (a photo: taken). A
/// kind word up front filters when it comes with a date or alone ("photos from last summer", "screenshots"); otherwise
/// it stays a hint, as before ("screenshot of the error"). The filter's words leave the text that's searched. English
/// only; seasons are the northern hemisphere's.
public struct QueryFilter: Equatable, Sendable {
    /// The query without the filter's words.
    public var text: String
    public var kinds: Set<FileKind>?
    /// Changed (or taken) in this; open ends are `Date.distantPast` and now.
    public var dates: DateInterval?

    /// Nothing left to search for: what the filter lets through, newest first (`Searcher.listing`).
    public var isListing: Bool { (kinds != nil || dates != nil) && Searcher.terms(text).isEmpty }

    public init(_ query: String, now: Date = Date(), calendar: Calendar = .current) {
        let words = Self.words(query)
        var cut: [Range<String.Index>] = []
        func drop(_ indices: Range<Int>) {
            cut.append(words[indices.lowerBound].range.lowerBound..<words[indices.upperBound - 1].range.upperBound)
        }
        // The first date phrase, with its preposition (and a verb before that: "taken in", "saved on").
        var dates: DateInterval?
        var start = 0
        while dates == nil, start < words.count {
            var at = start
            if Self.verbs.contains(words[at].word), at + 1 < words.count { at += 1 }
            let preposition = Self.prepositions.contains(words[at].word) && at + 1 < words.count ? words[at].word : nil
            if preposition != nil { at += 1 }
            if preposition != nil, words[at].word == "the", at + 1 < words.count { at += 1 }   // "in the last week"
            if let (interval, length) = Self.date(words[at...].map(\.word), preposition: preposition, now: now,
                                                  calendar: calendar) {
                switch preposition {
                case "since", "after":
                    dates = DateInterval(start: preposition == "since" ? interval.start : interval.end,
                                         end: max(now, interval.end))
                case "before": dates = DateInterval(start: .distantPast, end: interval.start)
                default: dates = interval
                }
                drop(start..<at + length)
            }
            start += 1
        }
        // A kind word up front ("my", "all", "the" before it don't count).
        let isCut = { (index: Int) in cut.contains { $0.contains(words[index].range.lowerBound) } }
        let head = words.indices.first { !Self.determiners.contains(words[$0].word) && !isCut($0) }
        let kinds = head.flatMap { Self.kindWords[words[$0].word] }
        let rest = words.indices.filter { $0 != head && !isCut($0) }
        if let head, kinds != nil,
           dates != nil || Searcher.terms(rest.map { words[$0].word }.joined(separator: " ")).isEmpty {
            drop(head..<head + 1)
            self.kinds = kinds
        } else {
            self.kinds = nil
        }
        var text = query
        var removedFrom = text.endIndex
        for range in cut.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            text.removeSubrange(range.lowerBound..<min(range.upperBound, removedFrom))
            removedFrom = range.lowerBound
        }
        self.text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.dates = dates
    }

    /// The query's words, lowercased, with where each is in it.
    private static func words(_ query: String) -> [(word: String, range: Range<String.Index>)] {
        var words: [(String, Range<String.Index>)] = []
        var index = query.startIndex
        while index < query.endIndex {
            guard query[index].isLetter || query[index].isNumber else {
                index = query.index(after: index)
                continue
            }
            let start = index
            while index < query.endIndex, query[index].isLetter || query[index].isNumber {
                index = query.index(after: index)
            }
            words.append((query[start..<index].lowercased(), start..<index))
        }
        return words
    }

    /// A date phrase at the start of `words`: when, and how many words it takes. A month, a season or a year alone
    /// needs a preposition before it ("from March", not "on": "notes on March Madness"), and a weekday any ("on
    /// Monday"): "march" and "may" are words too, and "2023" in "taxes 2023" is what the file is about.
    static func date(_ words: [String], preposition: String?, now: Date, calendar: Calendar) -> (DateInterval, Int)? {
        let alone = preposition != nil && preposition != "on"
        guard let first = words.first else { return nil }
        let word = { (index: Int) in index < words.count ? words[index] : "" }
        func of(_ unit: Calendar.Component, _ date: Date) -> DateInterval? {
            calendar.dateInterval(of: unit, for: date)
        }
        func back(_ unit: Calendar.Component, _ count: Int) -> Date {
            calendar.date(byAdding: unit, value: -count, to: now)!
        }
        switch first {
        case "today": return of(.day, now).map { ($0, 1) }
        case "yesterday": return of(.day, back(.day, 1)).map { ($0, 1) }
        default: break
        }
        // this / last / past + week, month, year, weekend, a season, a month, a weekday; last / past + N + units
        if ["this", "last", "past"].contains(first) {
            let last = first != "this"
            if let unit = units[word(1)] {
                if first == "past" { return (DateInterval(start: back(unit, 1), end: now), 2) }
                return of(unit, last ? back(unit, 1) : now).map { ($0, 2) }
            }
            if word(1) == "weekend" {
                return calendar.nextWeekend(startingAfter: now, direction: .backward).map { ($0, 2) }
            }
            if let count = number(word(1)), let unit = units[word(2)] ?? units[String(word(2).dropLast())] {
                return (DateInterval(start: back(unit, count), end: now), 3)
            }
            if let season = seasons[word(1)] {
                return Self.season(season, now: now, calendar: calendar, finished: last).map { ($0, 2) }
            }
            if let month = months[word(1)] {
                return Self.month(month, now: now, calendar: calendar, finished: last).map { ($0, 2) }
            }
            if let weekday = weekdays[word(1)] {
                return Self.day(weekday, now: now, calendar: calendar).map { ($0, 2) }
            }
            return nil
        }
        // N units ago
        if let count = number(first), word(2) == "ago",
           let unit = units[word(1)] ?? units[String(word(1).dropLast())] {
            return of(unit, back(unit, count)).map { ($0, 3) }
        }
        // March, March 2024, March 3, March 3 2024
        if let month = months[first] {
            let day = Int(word(1).prefix { $0.isNumber }).flatMap { (1...31).contains($0) ? $0 : nil }
            let yearAt = day == nil ? 1 : 2
            let year = Int(word(yearAt)).flatMap { (1900...2100).contains($0) ? $0 : nil }
            if let day {
                var components = DateComponents(year: year ?? calendar.component(.year, from: now), month: month,
                                                day: day)
                if year == nil, let date = calendar.date(from: components), date > now { components.year! -= 1 }
                return calendar.date(from: components).flatMap { of(.day, $0) }.map { ($0, year == nil ? 2 : 3) }
            }
            if let year {
                return calendar.date(from: DateComponents(year: year, month: month)).flatMap { of(.month, $0) }
                    .map { ($0, 2) }
            }
            return alone ? Self.month(month, now: now, calendar: calendar, finished: false).map { ($0, 1) } : nil
        }
        // summer, summer 2024
        if let season = seasons[first] {
            if let year = Int(word(1)), (1900...2100).contains(year) {
                return Self.season(season, year: year, calendar: calendar).map { ($0, 2) }
            }
            return alone ? Self.season(season, now: now, calendar: calendar, finished: false).map { ($0, 1) } : nil
        }
        if alone, let year = Int(first), (1900...2100).contains(year), first.count == 4 {
            return calendar.date(from: DateComponents(year: year)).flatMap { of(.year, $0) }.map { ($0, 1) }
        }
        if preposition != nil, let weekday = weekdays[first] {
            return Self.day(weekday, now: now, calendar: calendar).map { ($0, 1) }
        }
        return nil
    }

    /// The latest `month` that has started (`finished`: that has ended).
    private static func month(_ month: Int, now: Date, calendar: Calendar, finished: Bool) -> DateInterval? {
        var year = calendar.component(.year, from: now)
        while year > 1900 {
            if let start = calendar.date(from: DateComponents(year: year, month: month)),
               let interval = calendar.dateInterval(of: .month, for: start), (finished ? interval.end : start) <= now {
                return interval
            }
            year -= 1
        }
        return nil
    }

    /// The latest `season` that has started (`finished`: that has ended).
    private static func season(_ first: Int, now: Date, calendar: Calendar, finished: Bool) -> DateInterval? {
        var year = calendar.component(.year, from: now) + 1
        while year > 1900 {
            if let interval = season(first, year: year, calendar: calendar),
               (finished ? interval.end : interval.start) <= now {
                return interval
            }
            year -= 1
        }
        return nil
    }

    /// Three months from `first` (winter 2024: December 2023 to February 2024).
    private static func season(_ first: Int, year: Int, calendar: Calendar) -> DateInterval? {
        let startYear = first == 12 ? year - 1 : year
        guard let start = calendar.date(from: DateComponents(year: startYear, month: first, day: 1)),
              let end = calendar.date(byAdding: .month, value: 3, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The latest `weekday` before today.
    private static func day(_ weekday: Int, now: Date, calendar: Calendar) -> DateInterval? {
        guard let today = calendar.dateInterval(of: .day, for: now)?.start,
              let date = calendar.nextDate(after: today, matching: DateComponents(weekday: weekday),
                                           matchingPolicy: .nextTime, direction: .backward) else { return nil }
        return calendar.dateInterval(of: .day, for: date)
    }

    private static func number(_ word: String) -> Int? {
        Int(word).flatMap { $0 > 0 && $0 < 1000 ? $0 : nil } ?? numberWords[word]
    }

    static let units: [String: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year]
    static let numberWords = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                              "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    /// Each season's first month.
    static let seasons = ["spring": 3, "summer": 6, "fall": 9, "autumn": 9, "winter": 12]
    static let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6,
                           "saturday": 7]
    static let prepositions: Set<String> = ["from", "in", "during", "on", "since", "before", "after"]
    static let verbs: Set<String> = ["taken", "made", "shot", "recorded", "saved", "downloaded", "created", "modified",
                                     "edited", "changed", "added", "sent", "received", "written"]
    static let determiners: Set<String> = ["my", "all", "the", "any", "some", "every", "show", "find"]
    static let kindWords: [String: Set<FileKind>] = [
        "screenshot": [.screenshot], "screenshots": [.screenshot],
        "photo": [.image], "photos": [.image], "picture": [.image], "pictures": [.image], "pic": [.image],
        "pics": [.image], "image": [.image], "images": [.image],
        "pdf": [.pdf], "pdfs": [.pdf], "paper": [.pdf], "papers": [.pdf],
        "document": [.pdf, .doc], "documents": [.pdf, .doc], "doc": [.pdf, .doc], "docs": [.pdf, .doc],
        "note": [.pdf, .doc], "notes": [.pdf, .doc],
        "video": [.video], "videos": [.video], "movie": [.video], "movies": [.video], "clip": [.video],
        "clips": [.video],
        "recording": [.audio, .video], "recordings": [.audio, .video], "audio": [.audio], "song": [.audio],
        "songs": [.audio], "podcast": [.audio], "podcasts": [.audio],
    ]
}
