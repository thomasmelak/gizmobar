import Foundation

/// `[clock]` in config.toml. The default matches the SketchyBar clock:
/// `Fri 27 Nov 00:11:31 | 16:11 EST`, with a calendar and UTC in the popover.
public struct ClockSettings: Sendable, Equatable, Decodable {
    /// Local time, as a Unicode date pattern.
    public var format: String
    /// Between the local time and each inline world clock.
    public var separator: String
    /// Extra time zones. `inline` ones sit on the bar; all of them are listed
    /// in the popover.
    public var world: [WorldClock]
    /// Month calendar in the popover.
    public var calendar: Bool

    public static let defaultWorld = [
        WorldClock(zone: "America/New_York", inline: true),
        WorldClock(zone: "UTC", label: "UTC"),
    ]

    public init(format: String = "EEE dd MMM HH:mm:ss", separator: String = " | ",
                world: [WorldClock] = ClockSettings.defaultWorld, calendar: Bool = true)
    {
        self.format = format
        self.separator = separator
        self.world = world
        self.calendar = calendar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClockSettings()
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? d.format
        separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? d.separator
        world = try c.decodeIfPresent([WorldClock].self, forKey: .world) ?? d.world
        calendar = try c.decodeIfPresent(Bool.self, forKey: .calendar) ?? d.calendar
    }

    enum CodingKeys: String, CodingKey { case format, separator, world, calendar }
}

/// One `[[clock.world]]` entry.
public struct WorldClock: Sendable, Equatable, Decodable, Identifiable {
    /// IANA time zone, e.g. `America/New_York`, `Europe/London`, `UTC`.
    public var zone: String
    /// Shown instead of the zone abbreviation, e.g. "NYC". Defaults to the
    /// zone's short name (EST/EDT) on the bar and its city in the popover.
    public var label: String?
    public var inline: Bool
    /// Time pattern for this clock. Default `HH:mm`.
    public var format: String

    public var id: String { zone + (label ?? "") }

    public init(zone: String, label: String? = nil, inline: Bool = false, format: String = "HH:mm") {
        self.zone = zone
        self.label = label
        self.inline = inline
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zone = try c.decode(String.self, forKey: .zone)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        inline = try c.decodeIfPresent(Bool.self, forKey: .inline) ?? false
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "HH:mm"
    }

    enum CodingKeys: String, CodingKey { case zone, label, inline, format }

    public var timeZone: TimeZone? { TimeZone(identifier: zone) }

    /// Short zone name for the bar (EST, CET, UTC). Foundation maps the "UTC"
    /// identifier to GMT, so UTC spellings are kept as written.
    public func abbreviation(at date: Date) -> String {
        if ["UTC", "Etc/UTC", "UCT", "Etc/UCT", "Zulu", "Etc/Zulu"].contains(zone) { return "UTC" }
        guard let tz = timeZone else { return zone }
        return ClockText.abbreviation(tz, at: date)
    }

    /// City name from the zone id: `America/New_York` → "New York".
    public var city: String {
        label ?? zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone
    }
}

public enum ClockText {
    /// The bar label: local time, then each inline world clock.
    public static func bar(_ now: Date, _ s: ClockSettings, locale: Locale = .current, local: TimeZone = .current) -> String {
        var parts = [format(now, s.format, zone: local, locale: locale)]
        for w in s.world where w.inline {
            parts.append(inline(now, w, locale: locale))
        }
        return parts.joined(separator: s.separator)
    }

    /// `16:11 EST`, or `16:11 NYC` with a label.
    public static func inline(_ now: Date, _ w: WorldClock, locale: Locale = .current) -> String {
        guard let tz = w.timeZone else { return "?? \(w.zone)" }
        let name = w.label ?? w.abbreviation(at: now)
        return "\(format(now, w.format, zone: tz, locale: locale)) \(name)"
    }

    /// Short zone name like `date +%Z` prints (EST/EDT, CET, JST). Uses the
    /// en_US names on purpose: other locales (and POSIX) give "GMT-5".
    public static func abbreviation(_ zone: TimeZone, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = zone
        f.dateFormat = "zzz"
        return f.string(from: date)
    }

    /// Whole-day difference from local time: -1, 0 or +1 (for "Yesterday"/"Tomorrow").
    public static func dayOffset(_ now: Date, _ w: WorldClock, local: TimeZone = .current) -> Int {
        guard let tz = w.timeZone else { return 0 }
        var a = Calendar(identifier: .gregorian); a.timeZone = local
        var b = Calendar(identifier: .gregorian); b.timeZone = tz
        let da = a.dateComponents([.year, .month, .day], from: now)
        let db = b.dateComponents([.year, .month, .day], from: now)
        guard let x = a.date(from: da), let y = a.date(from: db) else { return 0 }
        return a.dateComponents([.day], from: x, to: y).day ?? 0
    }

    public static func format(_ date: Date, _ pattern: String, zone: TimeZone, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// A month grid, Monday first, as in the SketchyBar calendar popup.
public struct MonthGrid: Sendable, Equatable {
    public var title: String
    /// Up to six weeks of seven cells; nil cells are blank.
    public var weeks: [[Int?]]
    public var today: Int?

    public init(for date: Date, zone: TimeZone = .current, locale: Locale = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let first = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1))!
        let days = cal.range(of: .day, in: .month, for: first)!.count
        // Monday = 0 ... Sunday = 6
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        var cells: [Int?] = Array(repeating: nil, count: lead) + (1...days).map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        today = comps.day
        title = ClockText.format(date, "LLLL yyyy", zone: zone, locale: locale)
    }
}
