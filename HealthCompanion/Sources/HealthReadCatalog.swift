import Foundation
@preconcurrency import HealthKit

enum HealthReadGroup: String, CaseIterable, Identifiable {
    case vitals
    case activity
    case body
    case sleepAndMindfulness
    case mobility
    case running
    case nutritionAndHydration
    case environmental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vitals: return "心肺与生命体征"
        case .activity: return "活动与锻炼"
        case .body: return "身体测量"
        case .sleepAndMindfulness: return "睡眠与正念"
        case .mobility: return "步行与行动能力"
        case .running: return "跑步指标"
        case .nutritionAndHydration: return "饮食与饮水"
        case .environmental: return "听力与环境"
        }
    }

    var symbolName: String {
        switch self {
        case .vitals: return "heart.text.clipboard"
        case .activity: return "figure.run"
        case .body: return "figure.stand"
        case .sleepAndMindfulness: return "bed.double"
        case .mobility: return "figure.walk"
        case .running: return "figure.run.circle"
        case .nutritionAndHydration: return "drop"
        case .environmental: return "ear"
        }
    }
}

/// A closed, non-clinical catalog. Adding a type here changes the authorization request and must
/// remain an intentional product decision rather than an opaque "read everything" switch.
enum HealthReadKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case heartRate
    case restingHeartRate
    case heartRateVariabilitySDNN
    case respiratoryRate
    case oxygenSaturation
    case walkingHeartRateAverage
    case vo2Max
    case sleepingWristTemperature

    case stepCount
    case distanceWalkingRunning
    case distanceCycling
    case flightsClimbed
    case activeEnergyBurned
    case basalEnergyBurned
    case appleExerciseTime
    case appleStandTime
    case appleMoveTime
    case timeInDaylight
    case workout

    case bodyMass
    case bodyMassIndex
    case height
    case bodyFatPercentage
    case leanBodyMass

    case sleepAnalysis
    case mindfulSession
    case appleStandHour

    case walkingSpeed
    case walkingStepLength
    case walkingAsymmetryPercentage
    case walkingDoubleSupportPercentage
    case appleWalkingSteadiness
    case stairAscentSpeed
    case stairDescentSpeed
    case sixMinuteWalkTestDistance

    case runningSpeed
    case runningPower
    case runningStrideLength
    case runningGroundContactTime
    case runningVerticalOscillation

    case dietaryWater
    case dietaryEnergyConsumed
    case dietaryProtein
    case dietaryCarbohydrates
    case dietaryFatTotal
    case dietarySugar
    case dietaryFiber
    case dietarySodium
    case dietaryCaffeine

    case headphoneAudioExposure
    case environmentalAudioExposure

    var id: String { rawValue }

    var group: HealthReadGroup {
        switch self {
        case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate,
                .oxygenSaturation, .walkingHeartRateAverage, .vo2Max, .sleepingWristTemperature:
            return .vitals
        case .stepCount, .distanceWalkingRunning, .distanceCycling, .flightsClimbed,
                .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime, .appleStandTime,
                .appleMoveTime, .timeInDaylight, .workout, .appleStandHour:
            return .activity
        case .bodyMass, .bodyMassIndex, .height, .bodyFatPercentage, .leanBodyMass:
            return .body
        case .sleepAnalysis, .mindfulSession:
            return .sleepAndMindfulness
        case .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage,
                .walkingDoubleSupportPercentage, .appleWalkingSteadiness, .stairAscentSpeed,
                .stairDescentSpeed, .sixMinuteWalkTestDistance:
            return .mobility
        case .runningSpeed, .runningPower, .runningStrideLength, .runningGroundContactTime,
                .runningVerticalOscillation:
            return .running
        case .dietaryWater, .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
                .dietaryFatTotal, .dietarySugar, .dietaryFiber, .dietarySodium, .dietaryCaffeine:
            return .nutritionAndHydration
        case .headphoneAudioExposure, .environmentalAudioExposure:
            return .environmental
        }
    }

    var title: String {
        switch self {
        case .heartRate: return "心率"
        case .restingHeartRate: return "静息心率"
        case .heartRateVariabilitySDNN: return "心率变异性（SDNN）"
        case .respiratoryRate: return "呼吸频率"
        case .oxygenSaturation: return "血氧饱和度"
        case .walkingHeartRateAverage: return "步行平均心率"
        case .vo2Max: return "心肺适能（VO₂ max）"
        case .sleepingWristTemperature: return "睡眠腕温变化"
        case .stepCount: return "步数"
        case .distanceWalkingRunning: return "步行与跑步距离"
        case .distanceCycling: return "骑行距离"
        case .flightsClimbed: return "爬楼层数"
        case .activeEnergyBurned: return "活动能量"
        case .basalEnergyBurned: return "静息能量"
        case .appleExerciseTime: return "锻炼时间"
        case .appleStandTime: return "站立时间"
        case .appleMoveTime: return "活动时间"
        case .timeInDaylight: return "日照时间"
        case .workout: return "训练"
        case .bodyMass: return "体重"
        case .bodyMassIndex: return "BMI"
        case .height: return "身高"
        case .bodyFatPercentage: return "体脂率"
        case .leanBodyMass: return "去脂体重"
        case .sleepAnalysis: return "睡眠分析"
        case .mindfulSession: return "正念时段"
        case .appleStandHour: return "站立小时"
        case .walkingSpeed: return "步行速度"
        case .walkingStepLength: return "步幅"
        case .walkingAsymmetryPercentage: return "步态不对称性"
        case .walkingDoubleSupportPercentage: return "双支撑时间"
        case .appleWalkingSteadiness: return "步行稳定性"
        case .stairAscentSpeed: return "上楼速度"
        case .stairDescentSpeed: return "下楼速度"
        case .sixMinuteWalkTestDistance: return "六分钟步行距离"
        case .runningSpeed: return "跑步速度"
        case .runningPower: return "跑步功率"
        case .runningStrideLength: return "跑步步幅"
        case .runningGroundContactTime: return "触地时间"
        case .runningVerticalOscillation: return "垂直振幅"
        case .dietaryWater: return "饮水"
        case .dietaryEnergyConsumed: return "膳食能量"
        case .dietaryProtein: return "膳食蛋白质"
        case .dietaryCarbohydrates: return "膳食碳水化合物"
        case .dietaryFatTotal: return "膳食脂肪"
        case .dietarySugar: return "膳食糖"
        case .dietaryFiber: return "膳食膳食纤维"
        case .dietarySodium: return "膳食钠"
        case .dietaryCaffeine: return "膳食咖啡因"
        case .headphoneAudioExposure: return "耳机音量暴露"
        case .environmentalAudioExposure: return "环境音量暴露"
        }
    }
}

enum HealthReadCatalog {
    enum PayloadKind {
        case quantity(unit: HKUnit)
        case category
        case workout
    }

    static let kinds = HealthReadKind.allCases.filter { sampleType(for: $0) != nil }

    static let readTypes: Set<HKSampleType> = Set(kinds.compactMap(sampleType(for:)))

    static func kinds(in group: HealthReadGroup) -> [HealthReadKind] {
        kinds.filter { $0.group == group }
    }

    static func sampleType(for kind: HealthReadKind) -> HKSampleType? {
        switch kind {
        case .sleepAnalysis, .mindfulSession, .appleStandHour:
            return HKObjectType.categoryType(forIdentifier: categoryIdentifier(for: kind))
        case .workout:
            return HKObjectType.workoutType()
        default:
            return HKObjectType.quantityType(forIdentifier: quantityIdentifier(for: kind))
        }
    }

    static func payloadKind(for kind: HealthReadKind) -> PayloadKind {
        switch kind {
        case .sleepAnalysis, .mindfulSession, .appleStandHour:
            return .category
        case .workout:
            return .workout
        default:
            return .quantity(unit: quantityUnit(for: kind))
        }
    }

    private static func categoryIdentifier(for kind: HealthReadKind) -> HKCategoryTypeIdentifier {
        switch kind {
        case .sleepAnalysis: return .sleepAnalysis
        case .mindfulSession: return .mindfulSession
        case .appleStandHour: return .appleStandHour
        default:
            preconditionFailure("\(kind.rawValue) is not a category type")
        }
    }

    private static func quantityIdentifier(for kind: HealthReadKind) -> HKQuantityTypeIdentifier {
        switch kind {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .heartRateVariabilitySDNN: return .heartRateVariabilitySDNN
        case .respiratoryRate: return .respiratoryRate
        case .oxygenSaturation: return .oxygenSaturation
        case .walkingHeartRateAverage: return .walkingHeartRateAverage
        case .vo2Max: return .vo2Max
        case .sleepingWristTemperature: return .appleSleepingWristTemperature
        case .stepCount: return .stepCount
        case .distanceWalkingRunning: return .distanceWalkingRunning
        case .distanceCycling: return .distanceCycling
        case .flightsClimbed: return .flightsClimbed
        case .activeEnergyBurned: return .activeEnergyBurned
        case .basalEnergyBurned: return .basalEnergyBurned
        case .appleExerciseTime: return .appleExerciseTime
        case .appleStandTime: return .appleStandTime
        case .appleMoveTime: return .appleMoveTime
        case .timeInDaylight: return .timeInDaylight
        case .bodyMass: return .bodyMass
        case .bodyMassIndex: return .bodyMassIndex
        case .height: return .height
        case .bodyFatPercentage: return .bodyFatPercentage
        case .leanBodyMass: return .leanBodyMass
        case .walkingSpeed: return .walkingSpeed
        case .walkingStepLength: return .walkingStepLength
        case .walkingAsymmetryPercentage: return .walkingAsymmetryPercentage
        case .walkingDoubleSupportPercentage: return .walkingDoubleSupportPercentage
        case .appleWalkingSteadiness: return .appleWalkingSteadiness
        case .stairAscentSpeed: return .stairAscentSpeed
        case .stairDescentSpeed: return .stairDescentSpeed
        case .sixMinuteWalkTestDistance: return .sixMinuteWalkTestDistance
        case .runningSpeed: return .runningSpeed
        case .runningPower: return .runningPower
        case .runningStrideLength: return .runningStrideLength
        case .runningGroundContactTime: return .runningGroundContactTime
        case .runningVerticalOscillation: return .runningVerticalOscillation
        case .dietaryWater: return .dietaryWater
        case .dietaryEnergyConsumed: return .dietaryEnergyConsumed
        case .dietaryProtein: return .dietaryProtein
        case .dietaryCarbohydrates: return .dietaryCarbohydrates
        case .dietaryFatTotal: return .dietaryFatTotal
        case .dietarySugar: return .dietarySugar
        case .dietaryFiber: return .dietaryFiber
        case .dietarySodium: return .dietarySodium
        case .dietaryCaffeine: return .dietaryCaffeine
        case .headphoneAudioExposure: return .headphoneAudioExposure
        case .environmentalAudioExposure: return .environmentalAudioExposure
        case .sleepAnalysis, .mindfulSession, .appleStandHour, .workout:
            preconditionFailure("\(kind.rawValue) is not a quantity type")
        }
    }

    private static func quantityUnit(for kind: HealthReadKind) -> HKUnit {
        switch kind {
        case .heartRate, .restingHeartRate, .respiratoryRate, .walkingHeartRateAverage:
            return HKUnit(from: "count/min")
        case .heartRateVariabilitySDNN, .runningGroundContactTime:
            return .secondUnit(with: .milli)
        case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage,
                .walkingDoubleSupportPercentage:
            return .percent()
        case .vo2Max:
            return HKUnit(from: "ml/(kg*min)")
        case .sleepingWristTemperature:
            return .degreeCelsius()
        case .stepCount, .flightsClimbed:
            return .count()
        case .distanceWalkingRunning, .distanceCycling, .height, .walkingStepLength,
                .sixMinuteWalkTestDistance, .runningStrideLength, .runningVerticalOscillation:
            return .meter()
        case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed:
            return .kilocalorie()
        case .appleExerciseTime, .appleStandTime, .appleMoveTime, .timeInDaylight:
            return .minute()
        case .bodyMass, .leanBodyMass, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
                .dietarySugar, .dietaryFiber:
            return .gramUnit(with: .kilo)
        case .bodyMassIndex, .appleWalkingSteadiness:
            return .count()
        case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed, .runningSpeed:
            return HKUnit(from: "m/s")
        case .runningPower:
            return .watt()
        case .dietaryWater:
            return .liter()
        case .dietarySodium:
            return .gramUnit(with: .milli)
        case .dietaryCaffeine:
            return .gramUnit(with: .milli)
        case .headphoneAudioExposure, .environmentalAudioExposure:
            return .decibelAWeightedSoundPressureLevel()
        case .sleepAnalysis, .mindfulSession, .appleStandHour, .workout:
            preconditionFailure("\(kind.rawValue) has no quantity unit")
        }
    }
}
