import Foundation
import Testing
@testable import SensorstormCore

@Suite("Pro-Freischaltung")
struct ProAccessTests {

    // MARK: - Der Fluchtweg für die eigenen Daten

    /// The promise the whole gating rests on: buying Pro adds formats, it never becomes the
    /// precondition for reading your own measurements back out. If this test ever has to be
    /// changed to make a build pass, the change is the bug.
    @Test("CSV bleibt ohne Pro exportierbar — Aufnahme wie Begehung")
    func csvStaysFree() {
        #expect(ProAccess.free.allows(recordingFormat: .csvBundle))
        #expect(ProAccess.free.allows(surveyFormat: .csv))
    }

    @Test("Ohne Pro ist genau CSV frei, sonst nichts")
    func onlyCSVIsFree() {
        let freeRecording = RecordingExporter.Format.allCases
            .filter { ProAccess.free.allows(recordingFormat: $0) }
        #expect(Set(freeRecording) == ProAccess.freeRecordingFormats)

        let freeSurvey = SurveyExporter.Format.allCases
            .filter { ProAccess.free.allows(surveyFormat: $0) }
        #expect(Set(freeSurvey) == ProAccess.freeSurveyFormats)
    }

    /// A format added later gets `nil` for its `proFeature` only if someone wrote that
    /// deliberately — the switches are exhaustive, so the compiler asks first. This checks
    /// the other direction: Pro really does open everything, with no case left behind.
    @Test("Mit Pro ist jedes Format freigeschaltet")
    func proAllowsEverything() {
        for format in RecordingExporter.Format.allCases {
            #expect(ProAccess.pro.allows(recordingFormat: format), "\(format)")
        }
        for format in SurveyExporter.Format.allCases {
            #expect(ProAccess.pro.allows(surveyFormat: format), "\(format)")
        }
        for feature in ProFeature.allCases {
            #expect(ProAccess.pro.allows(feature), "\(feature)")
        }
    }

    @Test("Ohne Pro ist keine der Funktionen freigeschaltet")
    func freeAllowsNoFeature() {
        for feature in ProFeature.allCases {
            #expect(!ProAccess.free.allows(feature), "\(feature)")
        }
    }

    // MARK: - Begehungen

    @Test("Die erste Begehung ist frei, die zweite nicht")
    func firstSurveyIsFree() {
        #expect(ProAccess.free.allowsStartingSurvey(existingCount: 0))
        #expect(!ProAccess.free.allowsStartingSurvey(existingCount: 1))
        #expect(!ProAccess.free.allowsStartingSurvey(existingCount: 9))
    }

    @Test("Mit Pro ist die Zahl der Begehungen unbegrenzt")
    func proSurveysAreUnlimited() {
        #expect(ProAccess.pro.allowsStartingSurvey(existingCount: 0))
        #expect(ProAccess.pro.allowsStartingSurvey(existingCount: 500))
    }

    // MARK: - Abtastrate

    /// The boundary is the interesting part: 200 Hz is the last free rate, not the first
    /// paid one. Every rate the picker offers has to land on one side deliberately.
    @Test("200 Hz ist frei, 400 Hz nicht")
    func rateBoundary() {
        #expect(ProAccess.free.allowsRate(200))
        #expect(!ProAccess.free.allowsRate(400))
        #expect(ProAccess.pro.allowsRate(400))
    }

    @Test("Jede angebotene Rate ausser der höchsten ist ohne Pro nutzbar")
    func onlyTheTopRateIsGated() {
        let rates: [Double] = [10, 25, 50, 100, 200, 400]
        let free = rates.filter { ProAccess.free.allowsRate($0) }
        #expect(free == [10, 25, 50, 100, 200])
    }

    // MARK: - Kamerapose

    @Test("Der klassische Kamerastapel ist frei, ARKit nicht")
    func captureEngineGating() {
        #expect(ProAccess.free.allows(captureEngine: .classic))
        #expect(!ProAccess.free.allows(captureEngine: .arkit))
        #expect(ProAccess.pro.allows(captureEngine: .arkit))
    }

    // MARK: - Die Tabelle selbst

    /// The gating is only as good as the mapping behind it. A format that maps to no
    /// feature is free by definition, so this pins down which ones do that.
    @Test("Nur CSV hat kein Pro-Merkmal hinterlegt")
    func onlyCSVHasNoFeature() {
        let withoutFeature = RecordingExporter.Format.allCases.filter { $0.proFeature == nil }
        #expect(withoutFeature == [.csvBundle])

        let surveysWithoutFeature = SurveyExporter.Format.allCases.filter { $0.proFeature == nil }
        #expect(surveysWithoutFeature == [.csv])
    }
}
