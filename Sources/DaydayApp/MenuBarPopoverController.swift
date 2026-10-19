import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarPopoverLayout: ObservableObject {
  @Published private(set) var contentSize = MenuBarTimelineRange.recentNinetyMinutes.popoverSize

  func use(_ range: MenuBarTimelineRange) {
    contentSize = range.popoverSize
  }
}

@MainActor
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private let layout = MenuBarPopoverLayout()
  private var sizeSubscription: AnyCancellable?

  init(
    runtime: AppRuntimeModel,
    permissionOnboarding: PermissionOnboardingModel,
    timeline: MenuBarTimelineModel,
    insights: MenuBarInsightsModel,
    appearance: AppearanceSettingsModel,
    onOpenToday: @escaping @MainActor () -> Void
  ) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    guard let button = statusItem.button else { return }
    button.image = DaydayMenuBarIcon.image
    button.toolTip = "Dayday"
    button.target = self
    button.action = #selector(togglePopover)

    popover.behavior = .transient
    // Keep the system's standard menu-bar Popover transition. The hosted
    // SwiftUI content intentionally adds no independent scale or bounce.
    popover.animates = true
    popover.delegate = self
    popover.contentSize = layout.contentSize
    popover.contentViewController = NSHostingController(
      rootView: MenuBarView(
        runtime: runtime,
        permissionOnboarding: permissionOnboarding,
        timeline: timeline,
        insights: insights,
        appearance: appearance,
        layout: layout,
        onOpenToday: { [weak self] in
          self?.dismissPopover()
          onOpenToday()
        },
        onQuit: { [weak self] in
          self?.dismissPopover()
          DaydayWindowCoordinator.requestTermination()
        }
      )
    )
    sizeSubscription = layout.$contentSize
      .removeDuplicates()
      .sink { [weak self] size in self?.popover.contentSize = size }
  }

  @objc private func togglePopover() {
    if popover.isShown {
      dismissPopover()
    } else {
      showPopover()
    }
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    NSApplication.shared.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    button.state = .on
    DispatchQueue.main.async { [weak self] in
      self?.popover.contentViewController?.view.window?.makeKey()
    }
  }

  private func dismissPopover() {
    popover.performClose(nil)
    statusItem.button?.state = .off
  }

  func popoverDidClose(_ notification: Notification) {
    statusItem.button?.state = .off
  }
}

/// The menu bar has its own small, monochrome representation. Keeping it as a
/// template image lets macOS supply the correct contrast in light and dark
/// menu bars. It keeps the approved static double-D mark, using rounded,
/// slightly heavier tracks so the symbol remains legible at menu-bar size.
private enum DaydayMenuBarIcon {
  static let image: NSImage = {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.black.setStroke()
    let outerTrack = NSBezierPath()
    outerTrack.move(to: NSPoint(x: 3.55, y: 2.35))
    outerTrack.line(to: NSPoint(x: 3.55, y: 15.65))
    outerTrack.curve(
      to: NSPoint(x: 3.55, y: 2.35),
      controlPoint1: NSPoint(x: 13.15, y: 15.65),
      controlPoint2: NSPoint(x: 13.15, y: 2.35)
    )
    outerTrack.lineWidth = 2.15
    outerTrack.lineCapStyle = .round
    outerTrack.lineJoinStyle = .round
    outerTrack.stroke()

    let innerTrack = NSBezierPath()
    innerTrack.move(to: NSPoint(x: 6.95, y: 5.1))
    innerTrack.line(to: NSPoint(x: 6.95, y: 12.9))
    innerTrack.curve(
      to: NSPoint(x: 6.95, y: 5.1),
      controlPoint1: NSPoint(x: 11.55, y: 12.9),
      controlPoint2: NSPoint(x: 11.55, y: 5.1)
    )
    innerTrack.lineWidth = 1.7
    innerTrack.lineCapStyle = .round
    innerTrack.lineJoinStyle = .round
    innerTrack.stroke()

    image.isTemplate = true
    image.accessibilityDescription = "Dayday"
    return image
  }()
}
