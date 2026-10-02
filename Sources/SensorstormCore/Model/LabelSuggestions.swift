import Foundation

/// The labels used so far, ranked, for the chips under the label field.
///
/// A label is free text on purpose — a fixed list is always missing the thing standing in
/// front of you — but free text alone makes „Schlagloch“, „schlagloch“ and „Schlagloch “
/// three different things on the day somebody counts them. Offering what was typed before,
/// spelled the way it was typed most often, keeps the freedom and removes the typos.
public enum LabelSuggestions {

    /// Case, accents and runs of spaces do not make a different label.
    public static func normalise(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// - Parameters:
    ///   - surveys: every walk on the device.
    ///   - prefix: what has been typed so far; empty offers everything.
    ///   - extra: names to offer after the ones in use, e.g. a catalogue's categories.
    ///   - limit: how many chips fit.
    /// - Returns: display spellings, most used first. A label already typed in full is not
    ///   offered back to the person who just typed it.
    public static func rank(_ surveys: [Survey], prefix: String = "",
                            extra: [String] = [], limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]

        func tally(_ label: String, weight: Int) {
            let trimmed = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = normalise(trimmed)
            guard !key.isEmpty else { return }
            counts[key, default: 0] += weight
            spellings[key, default: [:]][trimmed, default: 0] += weight
        }

        for survey in surveys {
            for finding in survey.findings { tally(finding.label, weight: 1_000) }
        }
        // Catalogue names rank below anything somebody actually used, by weight rather than
        // by a second list, so a name that is also in use is not offered twice.
        for name in extra { tally(name, weight: 1) }

        let wanted = normalise(prefix)
        let ranked = counts.keys
            .filter { key in
                (wanted.isEmpty || key.hasPrefix(wanted)) && key != wanted
            }
            .sorted { lhs, rhs in
                let (a, b) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
                return a != b ? a > b : lhs < rhs
            }
        return ranked.prefix(max(limit, 0)).compactMap { key in
            // The spelling used most often; ties go to the one that sorts first, so the
            // answer does not change between two runs over the same data.
            spellings[key]?.sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }.first?.key
        }
    }
}
