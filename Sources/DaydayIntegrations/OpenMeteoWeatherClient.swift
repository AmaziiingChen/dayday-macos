import Foundation

/// A small, key-free Open-Meteo client. Coordinates are request-only inputs:
/// this module never persists or logs them.
public struct OpenMeteoWeatherClient: Sendable {
  public struct Observation: Equatable, Sendable {
    public let observedAt: Date
    public let temperatureCelsius: Double
    public let feelsLikeCelsius: Double?
    public let humidityPercent: Int?
    public let windKilometersPerHour: Double?
    public let weatherCode: Int
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidResponse
    case unavailable
  }

  public init() {}

  public func currentWeather(latitude: Double, longitude: Double) async throws -> Observation {
    guard latitude.isFinite, longitude.isFinite,
      (-90...90).contains(latitude), (-180...180).contains(longitude) else {
      throw Error.invalidResponse
    }
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    components.queryItems = [
      .init(name: "latitude", value: String(latitude)),
      .init(name: "longitude", value: String(longitude)),
      .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code"),
      .init(name: "wind_speed_unit", value: "kmh"),
      .init(name: "timeformat", value: "unixtime"),
      .init(name: "timezone", value: "auto")
    ]
    let (data, response) = try await URLSession.shared.data(from: components.url!)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw Error.unavailable
    }
    let decoded = try JSONDecoder().decode(Response.self, from: data)
    let date = Date(timeIntervalSince1970: decoded.current.time)
    guard date.timeIntervalSinceReferenceDate.isFinite,
      decoded.current.temperature2m.isFinite,
      decoded.current.apparentTemperature?.isFinite ?? true,
      decoded.current.windSpeed10m?.isFinite ?? true else { throw Error.invalidResponse }
    return Observation(
      observedAt: date, temperatureCelsius: decoded.current.temperature2m,
      feelsLikeCelsius: decoded.current.apparentTemperature,
      humidityPercent: decoded.current.relativeHumidity2m,
      windKilometersPerHour: decoded.current.windSpeed10m,
      weatherCode: decoded.current.weatherCode
    )
  }

  private struct Response: Decodable {
    let current: Current
    struct Current: Decodable {
      let time: Double
      let temperature2m: Double
      let apparentTemperature: Double?
      let relativeHumidity2m: Int?
      let windSpeed10m: Double?
      let weatherCode: Int
      enum CodingKeys: String, CodingKey {
        case time, weatherCode = "weather_code", temperature2m = "temperature_2m"
        case apparentTemperature = "apparent_temperature", relativeHumidity2m = "relative_humidity_2m"
        case windSpeed10m = "wind_speed_10m"
      }
    }
  }
}
