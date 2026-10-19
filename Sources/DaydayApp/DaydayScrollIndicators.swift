import AppKit
import SwiftUI

/// A shared scroll container that keeps native scrolling physics and accessibility while replacing
/// the visually heavy system scroller with Dayday's quiet, theme-aware overlay indicator.
struct DaydayScrollView<Content: View>: View {
  private let axes: Axis.Set
  private let showsIndicators: Bool
  private let content: Content

  init(
    _ axes: Axis.Set = .vertical,
    showsIndicators: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.axes = axes
    self.showsIndicators = showsIndicators
    self.content = content()
  }

  var body: some View {
    ScrollView(axes, showsIndicators: showsIndicators) {
      content
        .background(DaydayScrollIndicatorInstaller())
    }
  }
}

extension View {
  /// Use on AppKit-backed scrolling views that cannot be expressed through `DaydayScrollView`,
  /// notably SwiftUI `List`. The installer stays non-interactive and does not alter row layout.
  func daydayScrollIndicators() -> some View {
    background(DaydayScrollIndicatorInstaller())
  }
}

enum DaydayScrollIndicatorMetrics {
  static let regularThickness: CGFloat = 4
  static let increasedContrastThickness: CGFloat = 5
  static let edgeInset: CGFloat = 3

  static func visualKnobRect(
    in systemKnobRect: CGRect,
    isVertical: Bool,
    increasedContrast: Bool
  ) -> CGRect {
    guard !systemKnobRect.isEmpty else { return .zero }
    let thickness = increasedContrast ? increasedContrastThickness : regularThickness
    if isVertical {
      return CGRect(
        x: systemKnobRect.maxX - edgeInset - thickness,
        y: systemKnobRect.minY,
        width: thickness,
        height: systemKnobRect.height
      )
    }
    return CGRect(
      x: systemKnobRect.minX,
      y: systemKnobRect.minY + edgeInset,
      width: systemKnobRect.width,
      height: thickness
    )
  }
}

private struct DaydayScrollIndicatorInstaller: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.daydayAccent) private var accent

  func makeNSView(context: Context) -> DaydayScrollIndicatorProbe {
    DaydayScrollIndicatorProbe()
  }

  func updateNSView(_ probe: DaydayScrollIndicatorProbe, context: Context) {
    let environment = DaydayThemeEnvironment(
      appearance: colorScheme == .dark ? .dark : .light,
      contrast: contrast == .increased ? .increased : .standard,
      reduceTransparency: false
    )
    let primitive = DaydayTheme.mineralCandidate(for: environment, accent: accent).primitive(.action)
    probe.configure(
      color: NSColor(
        red: CGFloat(primitive.red),
        green: CGFloat(primitive.green),
        blue: CGFloat(primitive.blue),
        alpha: 1
      ),
      increasedContrast: contrast == .increased
    )
  }
}

private final class DaydayScrollIndicatorProbe: NSView {
  private var color = NSColor.controlAccentColor
  private var increasedContrast = false
  private var installationAttempts = 0

  override var intrinsicContentSize: NSSize { .zero }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(color: NSColor, increasedContrast: Bool) {
    self.color = color
    self.increasedContrast = increasedContrast
    installWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    installationAttempts = 0
    installWhenReady()
  }

  private func installWhenReady() {
    guard let scrollView = enclosingScrollView else {
      guard installationAttempts < 6 else { return }
      installationAttempts += 1
      DispatchQueue.main.async { [weak self] in self?.installWhenReady() }
      return
    }
    installationAttempts = 0
    DaydayOverlayScroller.install(
      in: scrollView,
      color: color,
      increasedContrast: increasedContrast
    )
  }
}

final class DaydayOverlayScroller: NSScroller {
  private var daydayColor = NSColor.controlAccentColor
  private var increasedContrast = false
  private var isPointerInside = false
  private var hoverTrackingArea: NSTrackingArea?

  override class var isCompatibleWithOverlayScrollers: Bool {
    self == DaydayOverlayScroller.self
  }

  static func install(
    in scrollView: NSScrollView,
    color: NSColor,
    increasedContrast: Bool
  ) {
    let showsVerticalIndicator = scrollView.hasVerticalScroller
    let showsHorizontalIndicator = scrollView.hasHorizontalScroller
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = NSScroller.preferredScrollerStyle == .overlay

    if showsVerticalIndicator {
      let scroller = (scrollView.verticalScroller as? DaydayOverlayScroller)
        ?? DaydayOverlayScroller(frame: .zero)
      scroller.configure(color: color, increasedContrast: increasedContrast)
      if scrollView.verticalScroller !== scroller { scrollView.verticalScroller = scroller }
      scrollView.hasVerticalScroller = true
    }
    if showsHorizontalIndicator {
      let scroller = (scrollView.horizontalScroller as? DaydayOverlayScroller)
        ?? DaydayOverlayScroller(frame: .zero)
      scroller.configure(color: color, increasedContrast: increasedContrast)
      if scrollView.horizontalScroller !== scroller { scrollView.horizontalScroller = scroller }
      scrollView.hasHorizontalScroller = true
    }
  }

  override func updateTrackingAreas() {
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    super.updateTrackingAreas()
    let hoverTrackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeInActiveApp, .mouseEnteredAndExited],
      owner: self
    )
    addTrackingArea(hoverTrackingArea)
    self.hoverTrackingArea = hoverTrackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    isPointerInside = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    isPointerInside = false
    needsDisplay = true
  }

  override func drawKnob() {
    let systemRect = rect(for: .knob)
    let isVertical = bounds.height >= bounds.width
    let rect = DaydayScrollIndicatorMetrics.visualKnobRect(
      in: systemRect,
      isVertical: isVertical,
      increasedContrast: increasedContrast
    )
    guard !rect.isEmpty else { return }
    let opacity: CGFloat
    if increasedContrast {
      opacity = isPointerInside ? 0.82 : 0.64
    } else {
      opacity = isPointerInside ? 0.52 : 0.28
    }
    daydayColor.withAlphaComponent(opacity).setFill()
    NSBezierPath(
      roundedRect: rect,
      xRadius: min(rect.width, rect.height) / 2,
      yRadius: min(rect.width, rect.height) / 2
    ).fill()
  }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
    // Intentionally transparent. The thumb alone carries scroll position without adding a rail.
  }

  private func configure(color: NSColor, increasedContrast: Bool) {
    daydayColor = color
    self.increasedContrast = increasedContrast
    needsDisplay = true
  }
}
