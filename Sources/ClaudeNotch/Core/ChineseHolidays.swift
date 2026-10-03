import Foundation

/// Days off under China's statutory holiday arrangement, keyed by the Beijing calendar day.
///
/// The State Council publishes each year's arrangement around November and there is no official
/// API for it, so the dates come from holiday-cn (github.com/NateScarlet/holiday-cn, MIT), which
/// turns each notice into one JSON file per year. Make-up working days are ignored on purpose:
/// they always fall on a weekend, which DeepSeek bills off-peak regardless.
struct ChineseHolidayCalendar: Equatable, Sendable {
    /// "yyyy-MM-dd" in Beijing time.
    private(set) var offDays: Set<String> = []
    /// Years whose arrangement is known. A year is never published without days off, so an empty
    /// file means the notice is not out yet.
    private(set) var years: Set<Int> = []

    static let empty = ChineseHolidayCalendar()

    func isOffDay(_ date: Date) -> Bool {
        offDays.contains(Self.dayKey(date))
    }

    func covers(_ date: Date) -> Bool {
        years.contains(Self.beijingCalendar.component(.year, from: date))
    }

    /// One holiday-cn year file merged over this calendar, replacing whatever was known about that
    /// year. nil when the file is not a usable year.
    func merging(holidayCNJSON data: Data) -> ChineseHolidayCalendar? {
        guard let file = try? JSONDecoder().decode(HolidayCNFile.self, from: data) else { return nil }
        let prefix = String(format: "%04d-", file.year)
        let days = file.days.filter { $0.isOffDay && $0.date.hasPrefix(prefix) }.map(\.date)
        guard !days.isEmpty else { return nil }
        var next = self
        next.offDays = offDays.filter { !$0.hasPrefix(prefix) }.union(days)
        next.years.insert(file.year)
        return next
    }

    static func dayKey(_ date: Date) -> String {
        let c = beijingCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A fixed +8 rather than Asia/Shanghai: China has kept no DST since 1991, and a fixed offset
    /// keeps the answer independent of the Mac's tz database.
    static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }

    private struct HolidayCNFile: Decodable {
        struct Day: Decodable {
            let date: String
            let isOffDay: Bool
        }
        let year: Int
        let days: [Day]
    }
}

/// The holiday calendar the DeepSeek provider prices against: the years shipped in the bundle,
/// then whatever a monthly check of holiday-cn (on the 28th) has added, so next year's arrangement arrives
/// without a release. Only the DeepSeek provider owns one, so nobody who hasn't set up DeepSeek
/// ever makes the request.
actor ChineseHolidaySource {
    private(set) var calendar: ChineseHolidayCalendar
    private let cacheDirectory: URL
    private let defaults: UserDefaults
    private static let checkedAtKey = "deepseekHolidaysCheckedAt"

    static func remoteURL(year: Int) -> URL {
        URL(string: "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/\(year).json")!
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Notch/holidays-cn", isDirectory: true)
    }

    init(bundled: [URL] = ResourceLocator.urls(prefix: "holiday-cn-", ext: "json"),
         cacheDirectory: URL = ChineseHolidaySource.defaultCacheDirectory,
         defaults: UserDefaults = .standard) {
        self.cacheDirectory = cacheDirectory
        self.defaults = defaults
        // Bundled years first, then cached ones over them: a cached year is at least as new, and
        // the State Council has amended a published arrangement before.
        let cached = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        let files = bundled.sorted { $0.lastPathComponent < $1.lastPathComponent }
            + cached.filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
        calendar = files.reduce(.empty) { calendar, url in
            guard let data = try? Data(contentsOf: url) else { return calendar }
            return calendar.merging(holidayCNJSON: data) ?? calendar
        }
    }

    /// Whether a check is due. An arrangement is published once a year and amended almost never,
    /// so once a month, on the 28th in Beijing (every month has one), or on the first refresh after
    /// it if the Mac was off; the November one catches a notice issued late October to mid
    /// November. While a year about to be needed is missing (this one, or next year in December)
    /// it is daily instead, so a late notice still lands before New Year's Day.
    static func isCheckDue(lastChecked: Date?, calendar: ChineseHolidayCalendar, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let beijing = ChineseHolidayCalendar.beijingCalendar
        let nextYear = beijing.date(byAdding: .year, value: 1, to: now)!
        if !calendar.covers(now)
            || (beijing.component(.month, from: now) == 12 && !calendar.covers(nextYear)) {
            return now.timeIntervalSince(lastChecked) >= 86_400
        }
        var day = beijing.dateComponents([.year, .month, .day], from: now)
        if day.day! < 28 { day.month! -= 1 }        // month 0 normalises to last December
        day.day = 28
        return lastChecked < beijing.date(from: day)!
    }

    /// This year, and next year once the November notice is out, when `isCheckDue` says so. A
    /// failure leaves the check due, and the calendar answers from what it already has meanwhile.
    func refreshIfDue(now: Date = Date()) async {
        let last = defaults.object(forKey: Self.checkedAtKey) as? Date
        guard Self.isCheckDue(lastChecked: last, calendar: calendar, now: now) else { return }
        let year = ChineseHolidayCalendar.beijingCalendar.component(.year, from: now)
        var failed = false
        for candidate in [year, year + 1] {
            var request = URLRequest(url: Self.remoteURL(year: candidate))
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                // Next year's file may not exist before the notice; only this year's counts.
                if candidate == year { failed = true }
                continue
            }
            guard let merged = calendar.merging(holidayCNJSON: data) else { continue }
            calendar = merged
            try? FileManager.default.createDirectory(at: cacheDirectory,
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheDirectory.appendingPathComponent("\(candidate).json"),
                            options: .atomic)
        }
        if !failed { defaults.set(now, forKey: Self.checkedAtKey) }
    }
}
