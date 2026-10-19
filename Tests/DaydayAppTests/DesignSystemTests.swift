import Testing

@testable import DaydayApp

@Suite("Candidate Mineral design system")
struct DesignSystemTests {
  @Test("Semantic state roles remain independent")
  func semanticRolesAreNotAliasColors() {
    let theme = DaydayTheme.mineralCandidate(
      for: .init(appearance: .light, contrast: .standard, reduceTransparency: false))
    #expect(theme.primitive(.action) != theme.primitive(.recording))
    #expect(theme.primitive(.recording) != theme.primitive(.success))
    #expect(theme.primitive(.evidenceObjective) != theme.primitive(.evidenceInference))
    #expect(theme.primitive(.evidenceInference) != theme.primitive(.evidenceCorrection))
  }

  @Test("Accent choice updates interactive roles without rewriting status colours")
  func accentChoiceUpdatesInteractiveRolesOnly() {
    let environment = DaydayThemeEnvironment(
      appearance: .light,
      contrast: .standard,
      reduceTransparency: false
    )
    let blue = DaydayTheme.mineralCandidate(for: environment, accent: .systemBlue)
    let rose = DaydayTheme.mineralCandidate(for: environment, accent: .rose)

    #expect(blue.primitive(.action) != rose.primitive(.action))
    #expect(blue.primitive(.evidenceInference) != rose.primitive(.evidenceInference))
    #expect(blue.primitive(.selectionFill) != rose.primitive(.selectionFill))
    #expect(blue.primitive(.recording) == rose.primitive(.recording))
    #expect(blue.primitive(.warning) == rose.primitive(.warning))
    #expect(blue.primitive(.failure) == rose.primitive(.failure))
  }

  @Test("Accessibility adaptation strengthens contrast and makes raised surfaces solid")
  func candidateAdaptsToAccessibilityEnvironment() {
    let regular = DaydayTheme.mineralCandidate(
      for: .init(appearance: .dark, contrast: .standard, reduceTransparency: false))
    let adapted = DaydayTheme.mineralCandidate(
      for: .init(appearance: .dark, contrast: .increased, reduceTransparency: true))
    #expect(regular.primitive(.separator) != adapted.primitive(.separator))
    #expect(
      adapted.primitive(.surfaceRaised)
        == DaydayTheme.mineralCandidate(
          for: .init(appearance: .dark, contrast: .standard, reduceTransparency: true)
        ).primitive(.surfaceRaised))
  }

  @Test("Small text roles meet contrast requirements on every candidate surface")
  func smallTextContrastIsAuditable() {
    let textRoles: [DaydayThemeRole] = [
      .textPrimary, .textSecondary, .textTertiary, .recording, .warning, .failure,
      .evidenceCorrection,
    ]
    let surfaces: [DaydayThemeRole] = [.surfaceCanvas, .surfaceRaised, .surfaceInset]

    for appearance in [DaydayThemeAppearance.light, .dark] {
      let theme = DaydayTheme.mineralCandidate(
        for: .init(appearance: appearance, contrast: .standard, reduceTransparency: false))
      for role in textRoles {
        for surface in surfaces {
          #expect(
            theme.primitive(role).contrastRatio(against: theme.primitive(surface)) >= 4.5,
            "\(appearance) \(role) on \(surface)")
        }
      }
    }
  }

  @Test("Evidence boundaries meet non-text contrast requirements")
  func evidenceBoundariesMeetMinimumContrast() {
    let graphicalRoles: [DaydayThemeRole] = [
      .evidenceObjective, .evidenceInference, .selectionBorder, .focus,
    ]
    for appearance in [DaydayThemeAppearance.light, .dark] {
      let theme = DaydayTheme.mineralCandidate(
        for: .init(appearance: appearance, contrast: .standard, reduceTransparency: false))
      for role in graphicalRoles {
        #expect(
          theme.primitive(role).contrastRatio(against: theme.primitive(.surfaceInset)) >= 3,
          "\(appearance) \(role) on inset surface")
      }
    }
  }

  @Test("Motion policy removes spatial movement for Reduce Motion")
  func motionPolicyIsEnvironmentAware() {
    let regular = DaydayMotionPolicy.forAccessibility(reduceMotion: false)
    let reduced = DaydayMotionPolicy.forAccessibility(reduceMotion: true)
    #expect(regular.compact == .compact)
    #expect(regular.spatial == .spatial)
    #expect(reduced.compact == .crossfade)
    #expect(reduced.spatial == .staticChange)
  }

  @Test("Live input metrics share the Today snappy motion policy")
  func liveInputMetricMotionIsConsistentAndAccessible() {
    #expect(DaydayLiveMetricMotion.style(reduceMotion: false) == .snappy)
    #expect(DaydayLiveMetricMotion.style(reduceMotion: true) == .reducedCrossfade)
    #expect(DaydayLiveMetricMotion.snappyDuration == 0.24)
    #expect(DaydayLiveMetricMotion.reducedMotionDuration == 0.12)
  }

  @Test("Every temporal specimen state supplies text and a non-color symbol")
  func temporalStatesHaveEquivalentTextualMeaning() {
    #expect(TemporalState.allCases.count == 6)
    #expect(TemporalState.degraded.role == .warning)
    #expect(TemporalState.failure.role == .failure)
    for state in TemporalState.allCases {
      #expect(!state.title.isEmpty)
      #expect(!state.detail.isEmpty)
      #expect(!state.symbol.isEmpty)
    }
  }

}
