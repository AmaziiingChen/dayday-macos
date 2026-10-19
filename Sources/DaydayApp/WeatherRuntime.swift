import AppKit
@preconcurrency import CoreLocation
import DaydayCore
import DaydayIntegrations
import Foundation

@MainActor
final class WeatherRuntime: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
  enum State: Equatable {
    case unconfigured, needsPermission, loading, available, unavailable(String)
  }

  struct Snapshot: Codable, Equatable {
    let district: String
    let placeName: String?
    let temperatureCelsius: Double
    let feelsLikeCelsius: Double?
    let humidityPercent: Int?
    let windKilometersPerHour: Double?
    let weatherCode: Int
    let observedAt: Date
    let retrievedAt: Date

    init(
      district: String,
      placeName: String? = nil,
      temperatureCelsius: Double,
      feelsLikeCelsius: Double?,
      humidityPercent: Int?,
      windKilometersPerHour: Double?,
      weatherCode: Int,
      observedAt: Date,
      retrievedAt: Date
    ) {
      self.district = district
      self.placeName = placeName
      self.temperatureCelsius = temperatureCelsius
      self.feelsLikeCelsius = feelsLikeCelsius
      self.humidityPercent = humidityPercent
      self.windKilometersPerHour = windKilometersPerHour
      self.weatherCode = weatherCode
      self.observedAt = observedAt
      self.retrievedAt = retrievedAt
    }
  }

  @Published private(set) var state: State = .unconfigured
  @Published private(set) var snapshot: Snapshot?

  private let manager = CLLocationManager()
  private let client = OpenMeteoWeatherClient()
  private let defaults = UserDefaults.standard
  private var refreshTimer: Timer?
  private var activationObserver: NSObjectProtocol?
  private static let enabledKey = "weather.automaticDistrict.enabled"
  private static let snapshotKey = "weather.automaticDistrict.latestSnapshot"

  override init() {
    super.init()
    manager.delegate = self
    snapshot = Self.loadSnapshot(from: defaults)
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshIfNeeded() }
    }
  }

  func start() {
    guard defaults.bool(forKey: Self.enabledKey) else { state = .unconfigured; return }
    refreshIfNeeded()
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshIfNeeded(force: true) }
    }
  }

  func stop() {
    suspendRefresh()
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    activationObserver = nil
  }

  private func suspendRefresh() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    manager.stopUpdatingLocation()
  }

  func enableAutomaticDistrictWeather() {
    defaults.set(true, forKey: Self.enabledKey)
    requestLocationAuthorization()
  }

  /// Called only from an explicit weather action. Launch and timer refreshes
  /// deliberately never invoke this prompt.
  func requestLocationAuthorization() {
    switch manager.authorizationStatus {
    case .notDetermined:
      state = .needsPermission
      manager.requestWhenInUseAuthorization()
    case .authorized:
      refreshIfNeeded(force: true)
    default:
      state = .unavailable("定位未授权；天气未更新")
    }
  }

  func applyProductConsent(_ consent: CollectorConsent) {
    guard consent.collector == .weather else { return }
    if consent.status == .enabled {
      enableAutomaticDistrictWeather()
    } else {
      defaults.set(false, forKey: Self.enabledKey)
      suspendRefresh()
      state = .unconfigured
    }
  }

  /// Restores an already-recorded product decision without ever causing a
  /// location prompt during launch. The explicit Settings action above remains
  /// the only route that may request authorization.
  func restoreProductConsent(_ consent: CollectorConsent) {
    guard consent.collector == .weather else { return }
    if consent.status == .enabled {
      defaults.set(true, forKey: Self.enabledKey)
      start()
    } else {
      defaults.set(false, forKey: Self.enabledKey)
      suspendRefresh()
      state = .unconfigured
    }
  }

  func refreshIfNeeded(force: Bool = false) {
    guard defaults.bool(forKey: Self.enabledKey) else { state = .unconfigured; return }
    // `NSApp` is an implicitly-unwrapped global and may still be nil while
    // SwiftUI constructs the composition at launch. The running application
    // query has no such launch-order trap.
    guard NSRunningApplication.current.isActive else { return }
    guard force || snapshot.map({ Date.now.timeIntervalSince($0.retrievedAt) > 30 * 60 }) ?? true else {
      state = .available
      return
    }
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      state = .loading
      manager.requestLocation()
    case .notDetermined:
      state = .needsPermission
    default:
      state = .unavailable("定位未授权；保留最近一次天气")
    }
  }

  /// Older weather snapshots predate the readable place label. Refresh it once
  /// when a report first needs the label; a successful result is cached with
  /// the ordinary weather snapshot and does not add work to later navigation.
  func refreshPlaceNameIfNeeded() {
    guard snapshot?.placeName == nil else { return }
    refreshIfNeeded(force: true)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager.authorizationStatus == .authorized {
      refreshIfNeeded(force: true)
    } else if manager.authorizationStatus != .notDetermined {
      state = .unavailable("定位未授权；保留最近一次天气")
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    manager.stopUpdatingLocation()
    Task { [weak self] in await self?.fetchWeather(for: location) }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    state = .unavailable("无法获取当前位置；保留最近一次天气")
  }

  private func fetchWeather(for location: CLLocation) async {
    do {
      let placemarks = try await CLGeocoder().reverseGeocodeLocation(
        location,
        preferredLocale: Locale(identifier: "zh-Hans_CN")
      )
      guard let placemark = placemarks.first, let district = Self.districtLabel(from: placemark) else {
        state = .unavailable("无法解析到区级行政区；天气未更新")
        return
      }
      let observation = try await client.currentWeather(
        latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
      let value = Snapshot(district: district, placeName: Self.placeName(from: placemark),
                           temperatureCelsius: observation.temperatureCelsius,
                           feelsLikeCelsius: observation.feelsLikeCelsius,
                           humidityPercent: observation.humidityPercent,
                           windKilometersPerHour: observation.windKilometersPerHour,
                           weatherCode: observation.weatherCode,
                           observedAt: observation.observedAt, retrievedAt: .now)
      snapshot = value
      defaults.set(try JSONEncoder().encode(value), forKey: Self.snapshotKey)
      state = .available
    } catch {
      state = .unavailable("天气服务暂不可用；保留最近一次天气")
    }
  }

  private static func districtLabel(from placemark: CLPlacemark) -> String? {
    let parts = [placemark.locality, placemark.subLocality].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard parts.count == 2 else { return nil }
    return parts.joined()
  }

  private static func placeName(from placemark: CLPlacemark) -> String? {
    let city = placemark.locality ?? placemark.subAdministrativeArea
    let components = [
      placemark.administrativeArea,
      city,
      placemark.subLocality,
      placemark.thoroughfare,
      placemark.subThoroughfare,
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    var unique: [String] = []
    for component in components where !unique.contains(component) {
      unique.append(component)
    }
    return unique.isEmpty ? nil : unique.joined()
  }

  private static func loadSnapshot(from defaults: UserDefaults) -> Snapshot? {
    guard let data = defaults.data(forKey: snapshotKey) else { return nil }
    return try? JSONDecoder().decode(Snapshot.self, from: data)
  }

  /// Converts only a current-workday, district-level observation to the Core report allowlist.
  /// Coordinates and placemark objects never enter this value.
  func workReportSnapshot(for day: DayDescriptor) -> WeatherSnapshot? {
    guard let snapshot else { return nil }
    return Self.workReportSnapshot(from: snapshot, for: day)
  }

  static func workReportSnapshot(
    from snapshot: Snapshot,
    for day: DayDescriptor
  ) -> WeatherSnapshot? {
    guard
      snapshot.observedAt >= day.boundary.startsAt,
      snapshot.observedAt < day.boundary.endsAt
    else { return nil }
    let timeZoneIdentifier = day.timeZoneIdentifier
    let locationSeed = "\(snapshot.district)|\(timeZoneIdentifier)"
    guard let providerKey = try? WeatherProviderLocationKey(
      rawValue: "open-meteo-district-\(Self.fnvHex(locationSeed))"
    ),
      let location = try? CityWeatherLocation(
        id: CityWeatherLocationID(
          rawValue: Self.stableUUID(namespace: "weather-location", value: locationSeed)
        ),
        displayName: snapshot.district,
        timeZoneIdentifier: timeZoneIdentifier,
        providerLocationKey: providerKey
      )
    else { return nil }
    let snapshotSeed = [
      locationSeed,
      String(snapshot.observedAt.timeIntervalSinceReferenceDate),
      String(snapshot.retrievedAt.timeIntervalSinceReferenceDate),
      String(snapshot.temperatureCelsius),
      snapshot.feelsLikeCelsius.map { String($0) } ?? "nil",
      snapshot.humidityPercent.map { String($0) } ?? "nil",
      snapshot.windKilometersPerHour.map { String($0) } ?? "nil",
      String(snapshot.weatherCode),
    ].joined(separator: "|")
    return try? WeatherSnapshot(
      id: WeatherSnapshotID(
        rawValue: Self.stableUUID(namespace: "weather-snapshot", value: snapshotSeed)
      ),
      dayID: day.id,
      location: location,
      provider: "Open-Meteo",
      providerSchemaVersion: "current-v1",
      observedAt: snapshot.observedAt,
      retrievedAt: snapshot.retrievedAt,
      condition: Self.condition(for: snapshot.weatherCode),
      temperatureCelsius: snapshot.temperatureCelsius,
      feelsLikeCelsius: snapshot.feelsLikeCelsius,
      humidityPercent: snapshot.humidityPercent,
      windKilometersPerHour: snapshot.windKilometersPerHour,
      attribution: "Open-Meteo"
    )
  }

  private static func condition(for code: Int) -> String {
    switch code {
    case 0: "晴"
    case 1...3: "多云"
    case 45, 48: "雾"
    case 51...67, 80...82: "雨"
    case 71...77, 85...86: "雪"
    case 95...99: "雷雨"
    default: "天气代码 \(code)"
    }
  }

  private static func fnvHex(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  private static func stableUUID(namespace: String, value: String) -> UUID {
    func hash(seed: UInt64) -> UInt64 {
      "\(namespace)|\(value)".utf8.reduce(seed) { partial, byte in
        (partial ^ UInt64(byte)) &* 1_099_511_628_211
      }
    }
    let first = hash(seed: 14_695_981_039_346_656_037)
    let second = hash(seed: 7_809_847_782_465_536_322)
    var bytes = withUnsafeBytes(of: first.bigEndian, Array.init)
      + withUnsafeBytes(of: second.bigEndian, Array.init)
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }
}
