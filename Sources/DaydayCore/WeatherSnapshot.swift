import Foundation

// MARK: - Objective city-level weather

public struct CityWeatherLocationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct WeatherProviderLocationKey: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidValue
    }

    public let rawValue: String

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue.utf8.allSatisfy(\.isSafeProviderKeyByte),
              !Self.looksLikeCoordinatePair(rawValue) else {
            throw ValidationError.invalidValue
        }
        self.rawValue = rawValue
    }

    private static func looksLikeCoordinatePair(_ value: String) -> Bool {
        for separator in [",", ":"] {
            let parts = value.split(separator: Character(separator), omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let latitude = Double(parts[0]),
                  let longitude = Double(parts[1]) else {
                continue
            }
            if (-90...90).contains(latitude), (-180...180).contains(longitude) {
                return true
            }
        }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CityWeatherLocation: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyDisplayName
        case invalidDisplayName
        case suspectedPreciseLocation
        case invalidIANATimeZone(String)
    }

    public let id: CityWeatherLocationID
    public let displayName: String
    public let timeZoneIdentifier: String
    public let providerLocationKey: WeatherProviderLocationKey

    public init(
        id: CityWeatherLocationID,
        displayName: String,
        timeZoneIdentifier: String,
        providerLocationKey: WeatherProviderLocationKey
    ) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ValidationError.emptyDisplayName
        }
        guard trimmedName == displayName,
              displayName.utf8.count <= 96,
              displayName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ValidationError.invalidDisplayName
        }
        let preciseSeparators = CharacterSet(charactersIn: ",，;；/\\")
        guard displayName.rangeOfCharacter(from: .decimalDigits) == nil,
              displayName.rangeOfCharacter(from: preciseSeparators) == nil else {
            throw ValidationError.suspectedPreciseLocation
        }
        guard timeZoneIdentifier == "UTC"
                || TimeZone.knownTimeZoneIdentifiers.contains(timeZoneIdentifier) else {
            throw ValidationError.invalidIANATimeZone(timeZoneIdentifier)
        }
        self.id = id
        self.displayName = displayName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.providerLocationKey = providerLocationKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, timeZoneIdentifier, providerLocationKey
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(CityWeatherLocationID.self, forKey: .id),
            displayName: values.decode(String.self, forKey: .displayName),
            timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier),
            providerLocationKey: values.decode(
                WeatherProviderLocationKey.self,
                forKey: .providerLocationKey
            )
        )
    }
}

public struct WeatherSnapshot: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyProvider
        case emptyProviderSchemaVersion
        case nonFiniteDate
        case nonFiniteMeasurement
        case negativePrecipitation
        case humidityOutsidePercentage(Int)
        case negativeWindSpeed
        case invalidDailyTemperatureRange
    }

    public let id: WeatherSnapshotID
    public let dayID: DayID
    public let location: CityWeatherLocation
    public let provider: String
    public let providerSchemaVersion: String
    public let observedAt: Date
    public let retrievedAt: Date
    public let condition: String?
    public let temperatureCelsius: Double?
    public let feelsLikeCelsius: Double?
    public let dailyLowCelsius: Double?
    public let dailyHighCelsius: Double?
    public let precipitationMillimeters: Double?
    public let humidityPercent: Int?
    public let windKilometersPerHour: Double?
    public let sunriseAt: Date?
    public let sunsetAt: Date?
    public let attribution: String?

    public init(
        id: WeatherSnapshotID = WeatherSnapshotID(),
        dayID: DayID,
        location: CityWeatherLocation,
        provider: String,
        providerSchemaVersion: String,
        observedAt: Date,
        retrievedAt: Date,
        condition: String? = nil,
        temperatureCelsius: Double? = nil,
        feelsLikeCelsius: Double? = nil,
        dailyLowCelsius: Double? = nil,
        dailyHighCelsius: Double? = nil,
        precipitationMillimeters: Double? = nil,
        humidityPercent: Int? = nil,
        windKilometersPerHour: Double? = nil,
        sunriseAt: Date? = nil,
        sunsetAt: Date? = nil,
        attribution: String? = nil
    ) throws {
        guard !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProvider
        }
        guard !providerSchemaVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProviderSchemaVersion
        }
        let dates = [observedAt, retrievedAt] + [sunriseAt, sunsetAt].compactMap { $0 }
        guard dates.allSatisfy(\.isFinite) else {
            throw ValidationError.nonFiniteDate
        }
        let measurements = [
            temperatureCelsius,
            feelsLikeCelsius,
            dailyLowCelsius,
            dailyHighCelsius,
            precipitationMillimeters,
            windKilometersPerHour
        ].compactMap { $0 }
        guard measurements.allSatisfy(\.isFinite) else {
            throw ValidationError.nonFiniteMeasurement
        }
        if let precipitationMillimeters, precipitationMillimeters < 0 {
            throw ValidationError.negativePrecipitation
        }
        if let humidityPercent, !(0...100).contains(humidityPercent) {
            throw ValidationError.humidityOutsidePercentage(humidityPercent)
        }
        if let windKilometersPerHour, windKilometersPerHour < 0 {
            throw ValidationError.negativeWindSpeed
        }
        if let dailyLowCelsius, let dailyHighCelsius, dailyLowCelsius > dailyHighCelsius {
            throw ValidationError.invalidDailyTemperatureRange
        }

        self.id = id
        self.dayID = dayID
        self.location = location
        self.provider = provider
        self.providerSchemaVersion = providerSchemaVersion
        self.observedAt = observedAt
        self.retrievedAt = retrievedAt
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.feelsLikeCelsius = feelsLikeCelsius
        self.dailyLowCelsius = dailyLowCelsius
        self.dailyHighCelsius = dailyHighCelsius
        self.precipitationMillimeters = precipitationMillimeters
        self.humidityPercent = humidityPercent
        self.windKilometersPerHour = windKilometersPerHour
        self.sunriseAt = sunriseAt
        self.sunsetAt = sunsetAt
        self.attribution = attribution
    }

    private enum CodingKeys: String, CodingKey {
        case id, dayID, location, provider, providerSchemaVersion, observedAt, retrievedAt
        case condition, temperatureCelsius, feelsLikeCelsius, dailyLowCelsius, dailyHighCelsius
        case precipitationMillimeters, humidityPercent, windKilometersPerHour
        case sunriseAt, sunsetAt, attribution
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(WeatherSnapshotID.self, forKey: .id),
            dayID: values.decode(DayID.self, forKey: .dayID),
            location: values.decode(CityWeatherLocation.self, forKey: .location),
            provider: values.decode(String.self, forKey: .provider),
            providerSchemaVersion: values.decode(String.self, forKey: .providerSchemaVersion),
            observedAt: values.decode(Date.self, forKey: .observedAt),
            retrievedAt: values.decode(Date.self, forKey: .retrievedAt),
            condition: values.decodeIfPresent(String.self, forKey: .condition),
            temperatureCelsius: values.decodeIfPresent(Double.self, forKey: .temperatureCelsius),
            feelsLikeCelsius: values.decodeIfPresent(Double.self, forKey: .feelsLikeCelsius),
            dailyLowCelsius: values.decodeIfPresent(Double.self, forKey: .dailyLowCelsius),
            dailyHighCelsius: values.decodeIfPresent(Double.self, forKey: .dailyHighCelsius),
            precipitationMillimeters: values.decodeIfPresent(
                Double.self,
                forKey: .precipitationMillimeters
            ),
            humidityPercent: values.decodeIfPresent(Int.self, forKey: .humidityPercent),
            windKilometersPerHour: values.decodeIfPresent(
                Double.self,
                forKey: .windKilometersPerHour
            ),
            sunriseAt: values.decodeIfPresent(Date.self, forKey: .sunriseAt),
            sunsetAt: values.decodeIfPresent(Date.self, forKey: .sunsetAt),
            attribution: values.decodeIfPresent(String.self, forKey: .attribution)
        )
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }

    var isSafeProviderKeyByte: Bool {
        isASCIIAlphaNumeric || self == 45 || self == 46 || self == 58 || self == 95
    }
}
