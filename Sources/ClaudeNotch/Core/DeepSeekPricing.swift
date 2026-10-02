import Foundation

/// DeepSeek's peak/off-peak billing rule, as its pricing page states it: peak is 09:00–12:00 and
/// 14:00–18:00 Beijing time, Monday to Friday, excluding Chinese statutory holidays; every other
/// minute — weekends and holidays included — bills at the off-peak rate, half the peak price.
/// https://api-docs.deepseek.com/quick_start/pricing
enum DeepSeekPricing {
    enum Phase: Equatable, Sendable {
        case peak, offPeak
    }

    struct Transition: Equatable, Sendable {
        let phase: Phase
        let date: Date
    }

    /// Minutes after Beijing midnight, [start, end).
    static let peakWindows: [(start: Int, end: Int)] = [(9 * 60, 12 * 60), (14 * 60, 18 * 60)]

    static func phase(at date: Date, holidays: ChineseHolidayCalendar) -> Phase {
        let calendar = ChineseHolidayCalendar.beijingCalendar
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, (2...6).contains(weekday),   // Monday…Friday
              !holidays.isOffDay(date) else { return .offPeak }
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return peakWindows.contains { $0.start <= minute && minute < $0.end } ? .peak : .offPeak
    }

    /// The next moment the phase changes. Only window edges can be one, so it walks those, a day
    /// at a time; sixteen days clears the longest stretch without a peak (the Spring Festival's
    /// nine days off between two weekends).
    static func nextTransition(after date: Date, holidays: ChineseHolidayCalendar) -> Transition? {
        let calendar = ChineseHolidayCalendar.beijingCalendar
        let current = phase(at: date, holidays: holidays)
        let edges = peakWindows.flatMap { [$0.start, $0.end] }.sorted()
        let day0 = calendar.startOfDay(for: date)
        for offset in 0...16 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: day0) else { continue }
            for minute in edges {
                let candidate = day.addingTimeInterval(TimeInterval(minute * 60))
                guard candidate > date else { continue }
                let next = phase(at: candidate, holidays: holidays)
                if next != current { return Transition(phase: next, date: candidate) }
            }
        }
        return nil
    }
}
