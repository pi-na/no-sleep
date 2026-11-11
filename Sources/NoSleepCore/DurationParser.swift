import Foundation

public enum DurationParser {
    /// Parses user input for the timer into an end date.
    /// Accepts `90` (minutes), `45m`, `2h`, `1h30m`, `1.5h`, `2h 15m`, `30s`, and clock times
    /// like `18:30` / `6:30pm` / `9am` (next occurrence).
    public static func endDate(for input: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let clock = clockTime(text, now: now, calendar: calendar) { return clock }
        guard let seconds = duration(text), seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    public static func duration(_ input: String) -> TimeInterval? {
        let text = input.lowercased().replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }
        if let minutes = Double(text) { return minutes > 0 ? minutes * 60 : nil }

        let units: [Character: Double] = ["d": 86_400, "h": 3_600, "m": 60, "s": 1]
        var total: Double = 0
        var number = ""
        var sawUnit = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNumber || character == "." || character == "," {
                number.append(character == "," ? "." : character)
                index = text.index(after: index)
                continue
            }
            // Accept long unit names ("min", "hours", "hrs"…) by keying off the first letter.
            guard let multiplier = units[character], let value = Double(number) else { return nil }
            total += value * multiplier
            number = ""
            sawUnit = true
            index = text.index(after: index)
            while index < text.endIndex, text[index].isLetter { index = text.index(after: index) }
        }
        if !number.isEmpty {
            // Trailing bare number after a unit, e.g. "1h30" → 30 minutes.
            guard sawUnit, let value = Double(number) else { return nil }
            total += value * 60
        }
        return total > 0 ? total : nil
    }

    static func clockTime(_ text: String, now: Date, calendar: Calendar) -> Date? {
        var body = text.replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where body.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            body = String(body.dropLast(suffix.count))
            break
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (meridiem != nil && parts.count == 1) || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0]),
              let minute = parts.count == 2 ? Int(parts[1]) : 0,
              (0..<60).contains(minute)
        else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard (0..<24).contains(hour) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// "1:05:09" / "4:09" style countdown.
    public static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// "15 min", "1 h", "1 h 30 min".
    public static func shortLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
