@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import DaydayCore
import Foundation

/// Why an application/window observation contains no window content.
public enum ApplicationWindowContextDisposition: Equatable, Hashable, Sendable {
  case available
  case foregroundApplicationMissing
  case applicationIdentityMissing
  case accessibilityDenied
  case focusedWindowMissing
  case excluded(ApplicationWindowContextExclusionReason)
  case unknownSafetyState
}

public enum ApplicationWindowContextExclusionReason: String, CaseIterable, Hashable, Sendable {
  case userExclusion
  case passwordManager
  case authenticationContext
  case securitySensitiveRole
}

/// Text that has passed the application/window privacy filter and a field-specific
/// UTF-8 byte bound. It has no public initializer, so unfiltered text cannot be
/// mistaken for admitted output.
public struct PrivacyFilteredApplicationText: Equatable, Hashable, Sendable {
  public let value: String

  fileprivate init(value: String) {
    self.value = value
  }
}

/// Volatile, privacy-filtered application/window metadata.
///
/// This fact is deliberately not Codable. Persistence belongs to the later R06
/// privacy gate and a separate reviewed event projection.
public struct ApplicationWindowContextFact: Equatable, Hashable, Sendable {
  public let observedAt: Date
  public let applicationIdentifier: ApplicationIdentifier?
  public let applicationDisplayLabel: PrivacyFilteredApplicationText?
  public let redactedWindowTitle: PrivacyFilteredApplicationText?
  public let redactedDocumentHint: PrivacyFilteredApplicationText?
  public let disposition: ApplicationWindowContextDisposition

  fileprivate init(
    observedAt: Date,
    applicationIdentifier: ApplicationIdentifier? = nil,
    applicationDisplayLabel: PrivacyFilteredApplicationText? = nil,
    redactedWindowTitle: PrivacyFilteredApplicationText? = nil,
    redactedDocumentHint: PrivacyFilteredApplicationText? = nil,
    disposition: ApplicationWindowContextDisposition
  ) {
    self.observedAt = observedAt
    self.applicationIdentifier = applicationIdentifier
    self.applicationDisplayLabel = applicationDisplayLabel
    self.redactedWindowTitle = redactedWindowTitle
    self.redactedDocumentHint = redactedDocumentHint
    self.disposition = disposition
  }
}

enum RawApplicationWindowState: Sendable {
  case available
  case accessibilityDenied
  case focusedWindowMissing
}

/// Raw platform values remain module-internal and live only for one synchronous
/// privacy-filter invocation.
struct RawApplicationWindowContext: Sendable {
  let state: RawApplicationWindowState
  let bundleIdentifier: String?
  let applicationDisplayName: String?
  let windowTitle: String?
  let documentURLString: String?
  let windowRole: String?
  let windowSubrole: String?
  let focusedElementRole: String?
}

enum RawApplicationWindowSnapshot: Sendable {
  case foregroundApplicationMissing
  case context(RawApplicationWindowContext)
  case unknown
}

struct FilteredApplicationWindowContent: Sendable {
  let applicationDisplayLabel: PrivacyFilteredApplicationText?
  let redactedWindowTitle: PrivacyFilteredApplicationText?
  let redactedDocumentHint: PrivacyFilteredApplicationText?
}

/// A privacy-filtered, bounded observation awaiting opaque identity resolution.
///
/// This value is intentionally module-internal. `bundleIdentifier` is the only
/// remaining raw platform identity and must be consumed by the runtime's
/// injected asynchronous resolver before any Core value is constructed.
struct FilteredApplicationWindowCandidate: Sendable {
  let observedAt: Date
  let bundleIdentifier: String?
  let applicationDisplayLabel: PrivacyFilteredApplicationText?
  let redactedWindowTitle: PrivacyFilteredApplicationText?
  let redactedDocumentHint: PrivacyFilteredApplicationText?
  let disposition: ApplicationWindowContextDisposition

  var equivalenceKey: EquivalenceKey {
    EquivalenceKey(
      bundleIdentifier: bundleIdentifier,
      applicationDisplayLabel: applicationDisplayLabel,
      redactedWindowTitle: redactedWindowTitle,
      redactedDocumentHint: redactedDocumentHint,
      disposition: disposition
    )
  }

  struct EquivalenceKey: Hashable, Sendable {
    let bundleIdentifier: String?
    let applicationDisplayLabel: PrivacyFilteredApplicationText?
    let redactedWindowTitle: PrivacyFilteredApplicationText?
    let redactedDocumentHint: PrivacyFilteredApplicationText?
    let disposition: ApplicationWindowContextDisposition
  }
}

enum ApplicationWindowPrivacyDecision: Sendable {
  case allowed(FilteredApplicationWindowContent)
  case excluded(ApplicationWindowContextExclusionReason)
  case unknown
}

protocol ApplicationWindowPrivacyFiltering: Sendable {
  func filter(_ context: RawApplicationWindowContext) -> ApplicationWindowPrivacyDecision
}

private enum ApplicationWindowInputInspection {
  /// AX text is untrusted and may be arbitrarily large. Every downstream
  /// normalization, tokenization, case fold, and URL parse first crosses this
  /// scalar inspection budget on the caller's thread.
  static let maximumScalars = 4_096

  static func admitted(_ value: String?) -> String? {
    guard let value else { return nil }
    let scalars = value.unicodeScalars
    var index = scalars.startIndex
    var inspected = 0
    while index != scalars.endIndex {
      guard inspected < maximumScalars else { return nil }
      scalars.formIndex(after: &index)
      inspected += 1
    }
    return value
  }
}

private enum ApplicationBundleIdentifierAdmission {
  static func admitted(_ value: String?) -> String? {
    guard let value = ApplicationWindowInputInspection.admitted(value),
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.utf8.count <= 255,
      value.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...90).contains(byte)
          || (97...122).contains(byte) || byte == 46 || byte == 45
      })
    else {
      return nil
    }
    return value
  }
}

/// Non-negotiable privacy classification applied by the monitor before any
/// injected, product-specific filter. A permissive policy cannot bypass it.
private enum MandatoryApplicationWindowPrivacyGate {
  private static let passwordManagerBundleIDs: Set<String> = [
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.dashlane.dashlanephonefinal",
    "com.lastpass.lastpass",
    "com.apple.keychainaccess",
  ]
  private static let authenticationBundleIDs: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.securityagent",
  ]
  private static let sensitiveRoles: Set<String> = [
    "axsecuretextfield",
    "axpasswordfield",
  ]

  static func rejection(
    for context: RawApplicationWindowContext
  ) -> ApplicationWindowPrivacyDecision? {
    guard
      let bundleIdentifier = ApplicationBundleIdentifierAdmission.admitted(
        context.bundleIdentifier
      )
    else {
      return .unknown
    }
    let normalizedBundleID = bundleIdentifier.lowercased()
    if passwordManagerBundleIDs.contains(normalizedBundleID) {
      return .excluded(.passwordManager)
    }
    if authenticationBundleIDs.contains(normalizedBundleID) {
      return .excluded(.authenticationContext)
    }

    guard context.state == .available else { return nil }
    guard let windowRole = normalizedRole(context.windowRole),
      let focusedRole = normalizedRole(context.focusedElementRole)
    else {
      return .unknown
    }
    let roles = [windowRole, normalizedRole(context.windowSubrole), focusedRole]
      .compactMap { $0 }
    if roles.contains(where: isSecuritySensitiveRole) {
      return .excluded(.securitySensitiveRole)
    }
    return nil
  }

  private static func normalizedRole(_ role: String?) -> String? {
    guard
      let admitted = ApplicationWindowInputInspection.admitted(role)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !admitted.isEmpty
    else {
      return nil
    }
    return admitted.lowercased()
  }

  private static func isSecuritySensitiveRole(_ role: String) -> Bool {
    sensitiveRoles.contains(role)
      || role.contains("password")
      || role.contains("secure")
      || role.contains("authentication")
      || role.contains("login")
  }
}

/// Conservative built-in filter. Product/user exclusions are injected, while
/// mandatory authentication, password-manager, and role exclusions always apply.
struct DefaultApplicationWindowPrivacyFilter: ApplicationWindowPrivacyFiltering {
  private let excludedBundleIDs: Set<String>

  init(excludedBundleIdentifiers: Set<String> = []) {
    self.excludedBundleIDs = Set(excludedBundleIdentifiers.map { $0.lowercased() })
  }

  func filter(_ context: RawApplicationWindowContext) -> ApplicationWindowPrivacyDecision {
    if let mandatoryRejection = MandatoryApplicationWindowPrivacyGate.rejection(for: context) {
      return mandatoryRejection
    }
    guard
      let bundleIdentifier = ApplicationBundleIdentifierAdmission.admitted(
        context.bundleIdentifier
      )
    else {
      return .unknown
    }
    let normalizedBundleID = bundleIdentifier.lowercased()
    if excludedBundleIDs.contains(normalizedBundleID) {
      return .excluded(.userExclusion)
    }

    let displayLabel = Self.filteredText(context.applicationDisplayName, limit: 96)
    guard context.state == .available else {
      return .allowed(
        FilteredApplicationWindowContent(
          applicationDisplayLabel: displayLabel,
          redactedWindowTitle: nil,
          redactedDocumentHint: nil
        ))
    }

    let isSupportedChromium = SupportedChromiumBundleID.all.contains(normalizedBundleID)
    return .allowed(
      FilteredApplicationWindowContent(
        applicationDisplayLabel: displayLabel,
        redactedWindowTitle: isSupportedChromium
          ? nil : Self.filteredText(context.windowTitle, limit: 256),
        redactedDocumentHint: isSupportedChromium
          ? nil
          : Self.documentHint(context.documentURLString)
      ))
  }

  private static func documentHint(_ rawValue: String?) -> PrivacyFilteredApplicationText? {
    guard let rawValue = ApplicationWindowInputInspection.admitted(rawValue),
      !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    let candidate: String
    if let url = URL(string: rawValue), let scheme = url.scheme?.lowercased() {
      guard scheme == "file" else { return nil }
      candidate = url.lastPathComponent
    } else {
      guard !containsUnsafeRelativeDelimiter(rawValue) else { return nil }
      candidate = URL(fileURLWithPath: rawValue).lastPathComponent
    }
    guard !containsUnsafeRelativeDelimiter(candidate) else { return nil }
    return filteredText(candidate, limit: 128)
  }

  private static func containsUnsafeRelativeDelimiter(_ value: String) -> Bool {
    // Relative/schemeless AX document hints have no trustworthy URL grammar.
    // Reject percent escapes outright so no finite decode-depth policy can be
    // bypassed with another layer of encoding.
    value.contains("%") || value.contains("?") || value.contains("#")
  }

  private static func filteredText(
    _ rawValue: String?,
    limit: Int
  ) -> PrivacyFilteredApplicationText? {
    guard let rawValue = ApplicationWindowInputInspection.admitted(rawValue) else { return nil }

    let withoutControls = String(
      rawValue.unicodeScalars.map { scalar -> Character in
        if CharacterSet.controlCharacters.contains(scalar)
          || CharacterSet.newlines.contains(scalar)
        {
          return " "
        }
        return Character(String(scalar))
      })
    let normalized =
      withoutControls
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .map { token -> String in
        let lowercased = token.lowercased()
        let isAbsolutePath = token.hasPrefix("/") || token.hasPrefix("~/")
        let isWindowsPath =
          token.count >= 3
          && token[token.index(after: token.startIndex)] == ":"
          && ["/", "\\"].contains(token[token.index(token.startIndex, offsetBy: 2)])
        if lowercased.contains("://") || lowercased.hasPrefix("www.")
          || isAbsolutePath || isWindowsPath
        {
          return "[redacted-location]"
        }
        return token
      }
      .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }

    var result = ""
    result.reserveCapacity(limit)
    var outputByteCount = 0
    for character in normalized {
      let addition = String(character)
      let additionByteCount = addition.utf8.count
      guard outputByteCount + additionByteCount <= limit else { break }
      result.append(character)
      outputByteCount += additionByteCount
    }
    guard !result.isEmpty else { return nil }
    return PrivacyFilteredApplicationText(value: result)
  }
}

private enum SupportedChromiumBundleID {
  static let all = BrowserCaptureSafetyStateStore.supportedBundleIdentifiers
}

@MainActor
protocol ApplicationWindowPlatformObservation: AnyObject {
  /// True only while both focused-window and focused-element notifications
  /// are registered for the current foreground application.
  var isCurrentApplicationWindowObservationActive: Bool { get }
  func cancel()
}

@MainActor
protocol ApplicationWindowPlatformSourcing: AnyObject {
  func snapshot() -> RawApplicationWindowSnapshot
  func observe(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ApplicationWindowPlatformObservation
}

/// Main-actor monitor with event-driven refresh. It never requests Accessibility
/// permission and never polls.
@MainActor
final class ApplicationWindowContextMonitor {
  typealias OutputHandler = @MainActor @Sendable (FilteredApplicationWindowCandidate) -> Void

  private let platformSource: any ApplicationWindowPlatformSourcing
  private let privacyFilter: any ApplicationWindowPrivacyFiltering
  private let clock: @Sendable () -> Date
  private let outputHandler: OutputHandler
  private var observation: (any ApplicationWindowPlatformObservation)?
  private var observationID: UUID?

  init(
    platformSource: (any ApplicationWindowPlatformSourcing)? = nil,
    excludedBundleIdentifiers: Set<String> = [],
    clock: @escaping @Sendable () -> Date = Date.init,
    outputHandler: @escaping OutputHandler
  ) {
    self.platformSource = platformSource
      ?? MacOSApplicationWindowPlatformSource(
        excludedBundleIdentifiers: excludedBundleIdentifiers
      )
    self.privacyFilter = DefaultApplicationWindowPrivacyFilter(
      excludedBundleIdentifiers: excludedBundleIdentifiers
    )
    self.clock = clock
    self.outputHandler = outputHandler
  }

  /// Test seam for exercising a product policy after the mandatory gate.
  /// Production composition injects only user bundle exclusions above.
  init(
    testingPlatformSource: any ApplicationWindowPlatformSourcing,
    testingPrivacyFilter: any ApplicationWindowPrivacyFiltering,
    clock: @escaping @Sendable () -> Date = Date.init,
    outputHandler: @escaping OutputHandler
  ) {
    self.platformSource = testingPlatformSource
    self.privacyFilter = testingPrivacyFilter
    self.clock = clock
    self.outputHandler = outputHandler
  }

  func start() {
    guard observation == nil else { return }
    let newID = UUID()
    observationID = newID
    let newObservation = platformSource.observe { [weak self] in
      guard self?.observationID == newID else { return }
      self?.capture()
    }
    guard observationID == newID else {
      newObservation.cancel()
      return
    }
    observation = newObservation
    capture()
  }

  func stop() {
    observationID = nil
    observation?.cancel()
    observation = nil
  }

  var isRunning: Bool { observation != nil }

  private func capture() {
    let observedAt = clock()
    guard observedAt.timeIntervalSinceReferenceDate.isFinite else { return }

    let snapshot = platformSource.snapshot()
    guard observation?.isCurrentApplicationWindowObservationActive == true else {
      switch snapshot {
      case .foregroundApplicationMissing:
        emit(observedAt: observedAt, disposition: .foregroundApplicationMissing)
      case .context(let context) where context.state == .accessibilityDenied:
        emit(observedAt: observedAt, disposition: .accessibilityDenied)
      case .context, .unknown:
        emit(observedAt: observedAt, disposition: .unknownSafetyState)
      }
      return
    }

    switch snapshot {
    case .foregroundApplicationMissing:
      emit(observedAt: observedAt, disposition: .foregroundApplicationMissing)
    case .unknown:
      emit(observedAt: observedAt, disposition: .unknownSafetyState)
    case .context(let rawContext) where rawContext.state == .accessibilityDenied:
      emit(observedAt: observedAt, disposition: .accessibilityDenied)
    case .context(let rawContext):
      emit(rawContext, observedAt: observedAt)
    }
  }

  private func emit(_ rawContext: RawApplicationWindowContext, observedAt: Date) {
    if let mandatoryRejection = MandatoryApplicationWindowPrivacyGate.rejection(
      for: rawContext
    ) {
      switch mandatoryRejection {
      case .excluded(let reason):
        emit(observedAt: observedAt, disposition: .excluded(reason))
      case .unknown:
        emit(observedAt: observedAt, disposition: .unknownSafetyState)
      case .allowed:
        preconditionFailure("Mandatory gate cannot admit filtered content")
      }
      return
    }

    switch privacyFilter.filter(rawContext) {
    case .excluded(let reason):
      emit(observedAt: observedAt, disposition: .excluded(reason))
    case .unknown:
      emit(observedAt: observedAt, disposition: .unknownSafetyState)
    case .allowed(let content):
      guard
        let bundleIdentifier = Self.admittedBundleIdentifier(
          rawContext.bundleIdentifier
        )
      else {
        emit(observedAt: observedAt, disposition: .unknownSafetyState)
        return
      }

      let disposition: ApplicationWindowContextDisposition
      switch rawContext.state {
      case .available:
        disposition = .available
      case .accessibilityDenied:
        disposition = .accessibilityDenied
      case .focusedWindowMissing:
        disposition = .focusedWindowMissing
      }
      outputHandler(
        FilteredApplicationWindowCandidate(
          observedAt: observedAt,
          bundleIdentifier: bundleIdentifier,
          applicationDisplayLabel: content.applicationDisplayLabel,
          redactedWindowTitle: content.redactedWindowTitle,
          redactedDocumentHint: content.redactedDocumentHint,
          disposition: disposition
        ))
    }
  }

  private func emit(
    observedAt: Date,
    disposition: ApplicationWindowContextDisposition
  ) {
    outputHandler(
      FilteredApplicationWindowCandidate(
        observedAt: observedAt,
        bundleIdentifier: nil,
        applicationDisplayLabel: nil,
        redactedWindowTitle: nil,
        redactedDocumentHint: nil,
        disposition: disposition
      ))
  }

  private static func admittedBundleIdentifier(_ value: String?) -> String? {
    ApplicationBundleIdentifierAdmission.admitted(value)
  }
}

@MainActor
private final class MacOSApplicationWindowPlatformSource: ApplicationWindowPlatformSourcing {
  private let excludedBundleIdentifiers: Set<String>

  init(excludedBundleIdentifiers: Set<String>) {
    self.excludedBundleIdentifiers = excludedBundleIdentifiers
  }

  func snapshot() -> RawApplicationWindowSnapshot {
    guard let application = NSWorkspace.shared.frontmostApplication else {
      return .foregroundApplicationMissing
    }
    let applicationMetadata = (
      bundleIdentifier: application.bundleIdentifier,
      displayName: application.localizedName
    )
    if applicationMetadata.bundleIdentifier.map(excludedBundleIdentifiers.contains) == true {
      // Self/user exclusions are classified without querying the target process through AX.
      // This keeps private Dayday editors out of both the work-context pipeline and its main-
      // run-loop observer path.
      return .context(
        RawApplicationWindowContext(
          state: .available,
          bundleIdentifier: applicationMetadata.bundleIdentifier,
          applicationDisplayName: applicationMetadata.displayName,
          windowTitle: nil,
          documentURLString: nil,
          windowRole: nil,
          windowSubrole: nil,
          focusedElementRole: nil
        ))
    }
    guard AXIsProcessTrusted() else {
      return .context(
        RawApplicationWindowContext(
          state: .accessibilityDenied,
          bundleIdentifier: applicationMetadata.bundleIdentifier,
          applicationDisplayName: applicationMetadata.displayName,
          windowTitle: nil,
          documentURLString: nil,
          windowRole: nil,
          windowSubrole: nil,
          focusedElementRole: nil
        ))
    }

    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    let focusedWindowResult = Self.copyElement(
      attribute: kAXFocusedWindowAttribute as CFString,
      from: applicationElement
    )
    switch focusedWindowResult {
    case .missing:
      return .context(
        RawApplicationWindowContext(
          state: .focusedWindowMissing,
          bundleIdentifier: applicationMetadata.bundleIdentifier,
          applicationDisplayName: applicationMetadata.displayName,
          windowTitle: nil,
          documentURLString: nil,
          windowRole: nil,
          windowSubrole: nil,
          focusedElementRole: nil
        ))
    case .denied:
      return .context(
        RawApplicationWindowContext(
          state: .accessibilityDenied,
          bundleIdentifier: applicationMetadata.bundleIdentifier,
          applicationDisplayName: applicationMetadata.displayName,
          windowTitle: nil,
          documentURLString: nil,
          windowRole: nil,
          windowSubrole: nil,
          focusedElementRole: nil
        ))
    case .unknown:
      return .unknown
    case .value(let window):
      let focusedRole: String?
      switch Self.copyElement(
        attribute: kAXFocusedUIElementAttribute as CFString,
        from: applicationElement
      ) {
      case .value(let element):
        focusedRole = Self.copyString(
          attribute: kAXRoleAttribute as CFString,
          from: element
        )
      case .missing, .denied, .unknown:
        focusedRole = nil
      }

      return .context(
        RawApplicationWindowContext(
          state: .available,
          bundleIdentifier: applicationMetadata.bundleIdentifier,
          applicationDisplayName: applicationMetadata.displayName,
          windowTitle: Self.copyString(
            attribute: kAXTitleAttribute as CFString,
            from: window
          ),
          documentURLString: Self.copyString(
            attribute: kAXDocumentAttribute as CFString,
            from: window
          ),
          windowRole: Self.copyString(
            attribute: kAXRoleAttribute as CFString,
            from: window
          ),
          windowSubrole: Self.copyString(
            attribute: kAXSubroleAttribute as CFString,
            from: window
          ),
          focusedElementRole: focusedRole
        ))
    }
  }

  func observe(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ApplicationWindowPlatformObservation {
    MacOSApplicationWindowObservation(
      excludedBundleIdentifiers: excludedBundleIdentifiers,
      handler: handler
    )
  }

  private enum ElementResult {
    case value(AXUIElement)
    case missing
    case denied
    case unknown
  }

  private static func copyElement(
    attribute: CFString,
    from element: AXUIElement
  ) -> ElementResult {
    var rawValue: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
    switch error {
    case .success:
      guard let rawValue, CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
        return .missing
      }
      return .value(unsafeDowncast(rawValue, to: AXUIElement.self))
    case .noValue, .attributeUnsupported:
      return .missing
    case .apiDisabled:
      return .denied
    default:
      return .unknown
    }
  }

  private static func copyString(attribute: CFString, from element: AXUIElement) -> String? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == CFStringGetTypeID()
    else {
      return nil
    }
    return rawValue as? String
  }
}

@MainActor
private final class MacOSApplicationWindowObservation: ApplicationWindowPlatformObservation {
  private let notificationCenter = NSWorkspace.shared.notificationCenter
  private let handler: @MainActor @Sendable () -> Void
  private var activationToken: NSObjectProtocol?
  private var observer: AXObserver?
  private var observedApplicationElement: AXUIElement?
  private var observedProcessIdentifier: pid_t?
  private var excludedProcessIdentifier: pid_t?
  private let excludedBundleIdentifiers: Set<String>
  private let callbackBox: AXWindowObserverCallbackBox
  private var isCancelled = false

  var isCurrentApplicationWindowObservationActive: Bool {
    guard !isCancelled else { return false }
    if let excludedProcessIdentifier {
      return NSWorkspace.shared.frontmostApplication?.processIdentifier
        == excludedProcessIdentifier
    }
    guard observer != nil,
      observedApplicationElement != nil,
      let observedProcessIdentifier else { return false }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
      == observedProcessIdentifier
  }

  init(
    excludedBundleIdentifiers: Set<String>,
    handler: @escaping @MainActor @Sendable () -> Void
  ) {
    self.excludedBundleIdentifiers = excludedBundleIdentifiers
    self.handler = handler
    self.callbackBox = AXWindowObserverCallbackBox(handler: handler)
    activationToken = notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isCancelled else { return }
        self.refreshAXObserver()
        self.handler()
      }
    }
    refreshAXObserver()
  }

  deinit {
    if let activationToken {
      notificationCenter.removeObserver(activationToken)
    }
    if let observer {
      if let observedApplicationElement {
        AXObserverRemoveNotification(
          observer,
          observedApplicationElement,
          kAXFocusedWindowChangedNotification as CFString
        )
        AXObserverRemoveNotification(
          observer,
          observedApplicationElement,
          kAXFocusedUIElementChangedNotification as CFString
        )
      }
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .commonModes
      )
    }
    callbackBox.cancel()
  }

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    if let activationToken {
      notificationCenter.removeObserver(activationToken)
      self.activationToken = nil
    }
    removeAXObserver()
    callbackBox.cancel()
  }

  private func refreshAXObserver() {
    removeAXObserver()
    guard AXIsProcessTrusted(),
      let application = NSWorkspace.shared.frontmostApplication
    else {
      return
    }
    if application.bundleIdentifier.map(excludedBundleIdentifiers.contains) == true {
      excludedProcessIdentifier = application.processIdentifier
      return
    }

    var newObserver: AXObserver?
    guard
      AXObserverCreate(
        application.processIdentifier,
        daydayApplicationWindowAXCallback,
        &newObserver
      ) == .success, let newObserver
    else {
      return
    }
    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    let refcon = Unmanaged.passUnretained(callbackBox).toOpaque()
    guard
      AXObserverAddNotification(
        newObserver,
        applicationElement,
        kAXFocusedWindowChangedNotification as CFString,
        refcon
      ) == .success
    else {
      return
    }
    guard
      AXObserverAddNotification(
        newObserver,
        applicationElement,
        kAXFocusedUIElementChangedNotification as CFString,
        refcon
      ) == .success
    else {
      AXObserverRemoveNotification(
        newObserver,
        applicationElement,
        kAXFocusedWindowChangedNotification as CFString
      )
      return
    }
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(newObserver),
      .commonModes
    )
    observer = newObserver
    observedApplicationElement = applicationElement
    observedProcessIdentifier = application.processIdentifier
  }

  private func removeAXObserver() {
    guard let observer else { return }
    if let observedApplicationElement {
      AXObserverRemoveNotification(
        observer,
        observedApplicationElement,
        kAXFocusedWindowChangedNotification as CFString
      )
      AXObserverRemoveNotification(
        observer,
        observedApplicationElement,
        kAXFocusedUIElementChangedNotification as CFString
      )
    }
    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
    self.observer = nil
    observedApplicationElement = nil
    observedProcessIdentifier = nil
    excludedProcessIdentifier = nil
  }
}

private final class AXWindowObserverCallbackBox: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@MainActor @Sendable () -> Void)?

  init(handler: @escaping @MainActor @Sendable () -> Void) {
    self.handler = handler
  }

  func enqueue() {
    let handler = lock.withLock { self.handler }
    guard let handler else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        handler()
      }
    }
  }

  func cancel() {
    lock.withLock {
      handler = nil
    }
  }
}

private func daydayApplicationWindowAXCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  Unmanaged<AXWindowObserverCallbackBox>
    .fromOpaque(refcon)
    .takeUnretainedValue()
    .enqueue()
}
