import Foundation

/// The life of one case over several walks of the same street.
///
/// A works depot does not walk a street once. It walks it every spring, and what it wants
/// from the second walk is not a second list but an answer: which of last time's cases are
/// gone, which got worse, which are new. A repeat walk therefore starts from the previous
/// one — every case still outstanding is copied into it — and each copy remembers which
/// case it descends from.
public enum FindingHistory {

    /// One station in a case's history: how it stood on one walk.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var surveyID: UUID
        public var surveyName: String
        public var findingID: UUID
        public var date: Date
        public var severity: Int
        public var status: FindingStatus

        public var id: UUID { findingID }
    }

    /// What a repeat walk found compared with the one it repeats.
    public struct Comparison: Sendable, Equatable {
        /// In the new walk and not in the old one.
        public var new: Int
        /// Outstanding before, resolved or „no action" now.
        public var resolved: Int
        public var worse: Int
        public var better: Int
        public var unchanged: Int
        /// In the old walk, outstanding, and not visited in the new one yet.
        public var notYetChecked: Int
    }

    /// The root of the chain a case belongs to.
    public static func origin(of finding: GroundFinding) -> UUID {
        finding.originID ?? finding.id
    }

    /// Every station of a case across `surveys`, oldest first.
    public static func chain(for finding: GroundFinding, in surveys: [Survey]) -> [Entry] {
        let root = origin(of: finding)
        var entries: [Entry] = []
        for survey in surveys {
            for candidate in survey.findings where origin(of: candidate) == root {
                entries.append(Entry(surveyID: survey.id, surveyName: survey.name,
                                     findingID: candidate.id, date: candidate.statusChangedAt ?? candidate.capturedAt,
                                     severity: candidate.severity, status: candidate.status))
            }
        }
        return entries.sorted { $0.date < $1.date }
    }

    /// A new walk that starts from `survey`: the cases still waiting are copied in as open,
    /// without photos — the new photo is the evidence that someone looked again.
    ///
    /// - Parameter includeResolved: also copy cases that were closed, to check that a repair
    ///   held. Off by default; a spring walk that re-lists every fixed pothole drowns.
    public static func repeating(_ survey: Survey, name: String, id: UUID = UUID(), now: Date = Date(),
                                 includeResolved: Bool = false, copyID: () -> UUID = { UUID() }) -> Survey {
        var next = Survey(id: id, name: name, startedAt: now, catalogID: survey.catalogID,
                          repeatsSurveyID: survey.id)
        for finding in survey.findingsByTime {
            guard includeResolved || finding.status.isOutstanding else { continue }
            var copy = GroundFinding(
                id: copyID(), capturedAt: now, hostTime: 0, location: finding.location,
                positionSource: finding.positionSource, severity: finding.severity,
                label: finding.label, note: "", media: [], area: finding.area,
                status: .open, attributes: finding.attributes, originID: origin(of: finding))
            copy.positionSampleCount = finding.positionSampleCount
            copy.positionSpread = finding.positionSpread
            next.findings.append(copy)
        }
        return next
    }

    /// How `newer` stands against `older`, matching cases by their chain.
    public static func compare(older: Survey, newer: Survey) -> Comparison {
        let newestByOrigin = Dictionary(newer.findings.map { (origin(of: $0), $0) },
                                        uniquingKeysWith: { first, _ in first })
        var comparison = Comparison(new: 0, resolved: 0, worse: 0, better: 0, unchanged: 0, notYetChecked: 0)
        var matched = Set<UUID>()
        for before in older.findings where before.status.isOutstanding {
            let root = origin(of: before)
            guard let after = newestByOrigin[root] else {
                comparison.notYetChecked += 1
                continue
            }
            matched.insert(root)
            if !after.status.isOutstanding {
                comparison.resolved += 1
            } else if after.severity > before.severity {
                comparison.worse += 1
            } else if after.severity < before.severity {
                comparison.better += 1
            } else {
                comparison.unchanged += 1
            }
        }
        // A case in the new walk with no ancestor in the old one, or one the old one had
        // already closed.
        let olderOrigins = Set(older.findings.map { origin(of: $0) })
        comparison.new = newer.findings.filter { !olderOrigins.contains(origin(of: $0)) }.count
        return comparison
    }
}

/// Putting walks from several phones together — the team that splits a district and wants one
/// list at the end, without a server in between.
public enum SurveyMerge {

    public struct Report: Sendable, Equatable {
        public var added = 0
        /// Cases both had where the other phone's version was newer.
        public var updated = 0
        /// Cases both had where this phone's version was newer or equal.
        public var kept = 0
        public var trackPointsAdded = 0

        public var changedAnything: Bool { added + updated + trackPointsAdded > 0 }
    }

    /// When a case was last touched on its own phone.
    private static func lastTouched(_ finding: GroundFinding) -> Date {
        max(finding.statusChangedAt ?? finding.capturedAt, finding.capturedAt)
    }

    /// Folds `remote` into `local`, both versions of the same walk.
    ///
    /// A case both phones have is taken from whichever touched it last; at a tie the local one
    /// stays. Photos and clips are the union, by id, so neither phone loses one. The track
    /// is the union of points by time. The result is the same whichever phone merges first.
    public static func merge(local: Survey, remote: Survey) -> (survey: Survey, report: Report) {
        var merged = local
        var report = Report()

        for incoming in remote.findings {
            guard let index = merged.findings.firstIndex(where: { $0.id == incoming.id }) else {
                merged.findings.append(incoming)
                report.added += 1
                continue
            }
            var current = merged.findings[index]
            let remoteWins = lastTouched(incoming) > lastTouched(current)
            var winner = remoteWins ? incoming : current
            let loser = remoteWins ? current : incoming
            for item in loser.media where !winner.media.contains(where: { $0.id == item.id }) {
                winner.media.append(item)
            }
            current = winner
            if remoteWins { report.updated += 1 } else { report.kept += 1 }
            merged.findings[index] = current
        }

        let known = Set(merged.track.map { $0.time.timeIntervalSince1970.rounded() })
        let extra = remote.track.filter { !known.contains($0.time.timeIntervalSince1970.rounded()) }
        if !extra.isEmpty {
            merged.track = (merged.track + extra).sorted { $0.time < $1.time }
            report.trackPointsAdded = extra.count
        }
        if let theirEnd = remote.endedAt, merged.endedAt == nil || theirEnd > (merged.endedAt ?? .distantPast) {
            merged.endedAt = theirEnd
        }
        merged.findings.sort { $0.capturedAt < $1.capturedAt }
        return (merged, report)
    }

    /// Several different walks as one: every case, every track, the earliest start.
    public static func combine(_ surveys: [Survey], name: String, id: UUID = UUID()) -> Survey {
        var combined = Survey(id: id, name: name,
                              startedAt: surveys.map(\.startedAt).min() ?? Date(),
                              catalogID: surveys.first?.catalogID)
        combined.endedAt = surveys.compactMap(\.endedAt).max()
        for survey in surveys {
            for finding in survey.findings where !combined.findings.contains(where: { $0.id == finding.id }) {
                combined.findings.append(finding)
            }
            combined.track.append(contentsOf: survey.track)
        }
        combined.findings.sort { $0.capturedAt < $1.capturedAt }
        combined.track.sort { $0.time < $1.time }
        return combined
    }
}
