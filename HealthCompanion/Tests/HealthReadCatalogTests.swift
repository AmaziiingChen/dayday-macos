import Testing
@testable import DaydayHealthCompanion

@Suite("Health read catalog")
struct HealthReadCatalogTests {
    @Test("The catalog covers the agreed broad non-clinical fact groups")
    func coversBroadNonClinicalFactGroups() {
        #expect(HealthReadCatalog.kinds(in: .vitals).contains(.heartRate))
        #expect(HealthReadCatalog.kinds(in: .sleepAndMindfulness).contains(.sleepAnalysis))
        #expect(HealthReadCatalog.kinds(in: .activity).contains(.workout))
        #expect(HealthReadCatalog.kinds(in: .activity).contains(.appleStandHour))
        #expect(HealthReadCatalog.kinds(in: .body).contains(.bodyMassIndex))
        #expect(HealthReadCatalog.kinds(in: .nutritionAndHydration).contains(.dietaryWater))
        #expect(HealthReadCatalog.kinds(in: .environmental).contains(.headphoneAudioExposure))
        #expect(HealthReadCatalog.kinds.count >= 50)
    }

    @Test("Every catalog kind resolves to an explicit HealthKit sample type")
    func everyKindHasAnExplicitSampleType() {
        #expect(HealthReadCatalog.kinds.allSatisfy { HealthReadCatalog.sampleType(for: $0) != nil })
        #expect(HealthReadCatalog.readTypes.count == HealthReadCatalog.kinds.count)
    }

    @Test("Clinical and document-like objects remain outside the closed catalog")
    func excludesClinicalAndDocumentLikeObjects() {
        #expect(!HealthReadKind.allCases.map(\.rawValue).contains("electrocardiogram"))
        #expect(!HealthReadKind.allCases.map(\.rawValue).contains("clinicalRecord"))
        #expect(!HealthReadKind.allCases.map(\.rawValue).contains("workoutRoute"))
    }
}
