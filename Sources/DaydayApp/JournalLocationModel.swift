import CoreLocation
import DaydayCore
import Foundation

@MainActor
final class JournalLocationModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
  @Published private(set) var snapshots: [JournalLocationSnapshot] = []
  @Published private(set) var status = "未记录位置"
  @Published private(set) var isCapturing = false
  @Published private(set) var resolvedPlaceNames: [JournalLocationSnapshotID: String] = [:]
  @Published private(set) var resolvingPlaceIDs: Set<JournalLocationSnapshotID> = []

  private let manager = CLLocationManager()
  private var repository: (any JournalLocationSnapshotRepository)?
  private weak var journal: JournalEntryModel?
  private var captureAfterAuthorization = false
  private var captureDayID: DayID?
  private var reloadGeneration = 0

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.distanceFilter = kCLDistanceFilterNone
  }

  func configure(repository: any JournalLocationSnapshotRepository, journal: JournalEntryModel) {
    self.repository = repository
    self.journal = journal
    Task { await reloadForSelectedDay() }
  }

  func captureOnce() {
    guard repository != nil, let journal, let dayID = journal.selectedDay?.id else {
      status = "本地存储尚未就绪"
      return
    }
    guard !isCapturing, !captureAfterAuthorization else { return }
    captureDayID = dayID
    captureAfterAuthorization = true
    switch manager.authorizationStatus {
    case .notDetermined:
      status = "请允许一次位置访问；Dayday 不会后台追踪"
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      beginCapture()
    case .denied, .restricted:
      captureAfterAuthorization = false
      captureDayID = nil
      status = "未获位置权限；你仍可正常写日记"
    @unknown default:
      captureAfterAuthorization = false
      captureDayID = nil
      status = "系统位置状态不可用"
    }
  }

  /// Automatically records the current place only when this journal day does not already have
  /// a saved snapshot. Call this after `reloadForSelectedDay()` so reopening the page remains a
  /// cheap local read instead of restarting Core Location and reverse geocoding.
  func captureAutomaticallyIfNeeded() {
    guard snapshots.isEmpty else { return }
    captureOnce()
  }

  /// Looks up a human-readable place only after the person asks for it. The
  /// returned label is held in memory for this app run rather than becoming a
  /// second, provider-derived durable copy of an exact personal location.
  func resolvePlaceName(for snapshot: JournalLocationSnapshot) async {
    if let placeName = snapshot.placeName {
      resolvedPlaceNames[snapshot.id] = placeName
      return
    }
    guard resolvedPlaceNames[snapshot.id] == nil,
      !resolvingPlaceIDs.contains(snapshot.id)
    else { return }
    resolvingPlaceIDs.insert(snapshot.id)
    defer { resolvingPlaceIDs.remove(snapshot.id) }
    do {
      let location = CLLocation(
        coordinate: .init(latitude: snapshot.latitude, longitude: snapshot.longitude),
        altitude: snapshot.altitude ?? 0,
        horizontalAccuracy: snapshot.horizontalAccuracy,
        verticalAccuracy: snapshot.verticalAccuracy ?? -1,
        timestamp: snapshot.capturedAt
      )
      let placemarks = try await CLGeocoder().reverseGeocodeLocation(
        location,
        preferredLocale: Locale(identifier: "zh-Hans_CN")
      )
      guard let placemark = placemarks.first,
        let name = Self.placeName(from: placemark)
      else {
        status = "地图服务未返回可读地点名称；坐标已保留"
        return
      }
      resolvedPlaceNames[snapshot.id] = name
      status = "已查询地点名称"
    } catch {
      status = "无法查询地点名称；坐标已保留"
    }
  }

  func placeName(for snapshot: JournalLocationSnapshot) -> String? {
    snapshot.placeName ?? resolvedPlaceNames[snapshot.id]
  }

  func isResolvingPlaceName(for snapshot: JournalLocationSnapshot) -> Bool {
    resolvingPlaceIDs.contains(snapshot.id)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard captureAfterAuthorization else { return }
    guard captureDayID == journal?.selectedDay?.id else {
      captureAfterAuthorization = false
      captureDayID = nil
      status = "已切换日记日期；未记录位置"
      return
    }
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: beginCapture()
    case .denied, .restricted:
      captureAfterAuthorization = false
      captureDayID = nil
      status = "未获位置权限；你仍可正常写日记"
    case .notDetermined: break
    @unknown default:
      captureAfterAuthorization = false
      captureDayID = nil
      status = "系统位置状态不可用"
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
    manager.stopUpdatingLocation()
    isCapturing = false
    captureAfterAuthorization = false
    let dayID = captureDayID
    captureDayID = nil
    guard let dayID, dayID == journal?.selectedDay?.id else {
      status = "已切换日记日期；未记录位置"
      return
    }
    Task { await persist(location, for: dayID) }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    manager.stopUpdatingLocation()
    isCapturing = false
    captureAfterAuthorization = false
    captureDayID = nil
    status = "无法取得当前位置；未保存任何位置"
  }

  private func beginCapture() {
    guard !isCapturing else { return }
    isCapturing = true
    status = "正在获取一次高精度位置…"
    manager.requestLocation()
  }

  private func persist(_ location: CLLocation, for dayID: DayID) async {
    guard let repository, let journal else { return }
    do {
      status = "正在确认地点名称…"
      let placeName = await resolvedPlaceName(for: location)
      let anchor = try await journal.attachmentAnchor(now: location.timestamp)
      guard anchor.dayID == dayID else {
        status = "已切换日记日期；未记录位置"
        return
      }
      let snapshot = try JournalLocationSnapshot(
        journalEntryID: anchor.entryID,
        dayID: anchor.dayID,
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude,
        altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
        horizontalAccuracy: location.horizontalAccuracy,
        verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
        capturedAt: location.timestamp,
        placeName: placeName
      )
      _ = try await repository.insert(snapshot)
      snapshots.append(snapshot)
      if let placeName { resolvedPlaceNames[snapshot.id] = placeName }
      if location.horizontalAccuracy > 15 {
        status = "已记录位置（水平误差 ±\(Int(location.horizontalAccuracy.rounded())) 米；当前环境精度较低）"
      } else {
        status = "已记录位置（水平误差 ±\(Int(location.horizontalAccuracy.rounded())) 米）"
      }
    } catch {
      status = "位置未保存"
    }
  }

  func reloadForSelectedDay() async {
    guard let repository, let journal else { return }
    reloadGeneration &+= 1
    let generation = reloadGeneration
    let targetDayID = journal.selectedDay?.id
    do {
      let anchor = try await journal.attachmentAnchor()
      let snapshots = try await repository.snapshots(for: anchor.dayID)
      guard generation == reloadGeneration,
        journal.selectedDay?.id == anchor.dayID || journal.selectedDay == nil
      else { return }
      self.snapshots = snapshots
      if let latest = snapshots.last {
        status = "最近一次水平误差 ±\(Int(latest.horizontalAccuracy.rounded())) 米"
        if let placeName = latest.placeName {
          resolvedPlaceNames[latest.id] = placeName
        } else {
          Task { await resolvePlaceName(for: latest) }
        }
      }
    } catch {
      guard generation == reloadGeneration, journal.selectedDay?.id == targetDayID else { return }
      snapshots = []
      status = "读取已保存位置失败"
    }
  }

  private static func placeName(from placemark: CLPlacemark) -> String? {
    // Apple may provide the city in either `locality` or
    // `subAdministrativeArea`. Select the semantic hierarchy explicitly so a
    // Chinese address is displayed province → city → district → road, rather
    // than in the provider's arbitrary display-name order.
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

  private func resolvedPlaceName(for location: CLLocation) async -> String? {
    do {
      let placemarks = try await CLGeocoder().reverseGeocodeLocation(
        location,
        preferredLocale: Locale(identifier: "zh-Hans_CN")
      )
      return placemarks.first.flatMap(Self.placeName(from:))
    } catch {
      return nil
    }
  }
}
