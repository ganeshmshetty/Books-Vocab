import Foundation

/// Notebook overrides are deliberately limited to SRS policy and card layout.
/// Pause clock, autoplay, and other review chrome remain user-global.
struct ReviewPolicy: Codable, Equatable, Hashable, Sendable {
    var mode: ReviewSettingsMode
    var customInitialIntervalHours: Double
    var customRememberedMultiplier: Double
    var customForgotMultiplier: Double
    var customMinimumIntervalHours: Double
    var customMaximumIntervalHours: Double

    static let `default` = ReviewPolicy(ReviewSettings.default)

    init(
        mode: ReviewSettingsMode,
        customInitialIntervalHours: Double,
        customRememberedMultiplier: Double,
        customForgotMultiplier: Double,
        customMinimumIntervalHours: Double,
        customMaximumIntervalHours: Double
    ) {
        self.mode = mode
        self.customInitialIntervalHours = customInitialIntervalHours
        self.customRememberedMultiplier = customRememberedMultiplier
        self.customForgotMultiplier = customForgotMultiplier
        self.customMinimumIntervalHours = customMinimumIntervalHours
        self.customMaximumIntervalHours = customMaximumIntervalHours
    }

    init(_ settings: ReviewSettings) {
        self.init(
            mode: settings.mode,
            customInitialIntervalHours: settings.customInitialIntervalHours,
            customRememberedMultiplier: settings.customRememberedMultiplier,
            customForgotMultiplier: settings.customForgotMultiplier,
            customMinimumIntervalHours: settings.customMinimumIntervalHours,
            customMaximumIntervalHours: settings.customMaximumIntervalHours
        )
    }

    /// Overlay only notebook policy fields, preserving user-global clock and autoplay.
    func applying(to global: ReviewSettings) -> ReviewSettings {
        var result = global
        result.mode = mode
        result.customInitialIntervalHours = customInitialIntervalHours
        result.customRememberedMultiplier = customRememberedMultiplier
        result.customForgotMultiplier = customForgotMultiplier
        result.customMinimumIntervalHours = customMinimumIntervalHours
        result.customMaximumIntervalHours = customMaximumIntervalHours
        return result
    }
}

struct NotebookSettingsOverride: Equatable, Sendable {
    var reviewPolicy: ReviewPolicy?
    var cardLayout: ReviewCardLayoutProfile?

    static let empty = NotebookSettingsOverride(reviewPolicy: nil, cardLayout: nil)
}

enum NotebookSettingsSource: String, Codable, Sendable {
    case notebook
    case user
}

/// #3124：版面編輯器的寫入目標。`.notebook` = 該單字本的 override，`.global` = 全域 store。
enum ReviewCardLayoutEditScope: Equatable, Sendable {
    case global
    case notebook
}

struct NotebookSettingsResolution: Equatable, Sendable {
    let reviewPolicy: ReviewPolicy
    let cardLayout: ReviewCardLayoutProfile
    let reviewPolicySource: NotebookSettingsSource
    let cardLayoutSource: NotebookSettingsSource
}

/// Immutable per-session settings capture. Background persistence resolves each
/// card by notebook ID without reading observable stores or SwiftData models.
struct NotebookSettingsSnapshot: Equatable, Sendable {
    let globalReviewSettings: ReviewSettings
    let globalCardLayout: ReviewCardLayoutProfile
    let notebookReviewPolicies: [String: ReviewPolicy]
    let notebookCardLayouts: [String: ReviewCardLayoutProfile]

    func reviewSettings(for notebookId: String) -> ReviewSettings {
        notebookReviewPolicies[notebookId]?.applying(to: globalReviewSettings)
            ?? globalReviewSettings
    }

    func cardLayout(for notebookId: String) -> ReviewCardLayoutProfile {
        notebookCardLayouts[notebookId] ?? globalCardLayout
    }
}

/// Pure notebook → user fallback resolver.
struct NotebookSettingsResolver: Sendable {
    let globalReviewSettings: ReviewSettings
    let globalCardLayout: ReviewCardLayoutProfile
    let overrides: [String: NotebookSettingsOverride]

    init(
        globalReviewSettings: ReviewSettings,
        globalCardLayout: ReviewCardLayoutProfile,
        overrides: [String: NotebookSettingsOverride] = [:]
    ) {
        self.globalReviewSettings = globalReviewSettings
        self.globalCardLayout = globalCardLayout
        self.overrides = overrides
    }

    init(
        globalReviewStore: ReviewSettingsStore,
        globalCardLayoutStore: ReviewCardLayoutStore,
        projections: [NotebookSettingsProjection]
    ) {
        self.init(
            globalReviewSettings: globalReviewStore.settings,
            globalCardLayout: globalCardLayoutStore.profile,
            overrides: Dictionary(
                uniqueKeysWithValues: projections.map {
                    ($0.notebookId, NotebookSettingsOverride(
                        reviewPolicy: $0.reviewPolicyOverride,
                        cardLayout: $0.cardLayoutOverride
                    ))
                }
            )
        )
    }

    func resolve(notebookId: String) -> NotebookSettingsResolution {
        let override = overrides[notebookId] ?? .empty
        return NotebookSettingsResolution(
            reviewPolicy: override.reviewPolicy ?? ReviewPolicy(globalReviewSettings),
            cardLayout: override.cardLayout ?? globalCardLayout,
            reviewPolicySource: override.reviewPolicy == nil ? .user : .notebook,
            cardLayoutSource: override.cardLayout == nil ? .user : .notebook
        )
    }

    /// #3124：複習頁工具列的版面編輯器要改哪一份設定。卡片實際畫的是 notebook override（若有），
    /// 所以有 override 的單字本編輯它；沒有則編輯全域 profile。
    func cardLayoutEditScope(notebookId: String) -> ReviewCardLayoutEditScope {
        resolve(notebookId: notebookId).cardLayoutSource == .notebook ? .notebook : .global
    }

    func snapshot(for notebookIds: some Sequence<String>) -> NotebookSettingsSnapshot {
        var policies: [String: ReviewPolicy] = [:]
        var layouts: [String: ReviewCardLayoutProfile] = [:]
        for notebookId in notebookIds {
            let resolution = resolve(notebookId: notebookId)
            if resolution.reviewPolicySource == .notebook {
                policies[notebookId] = resolution.reviewPolicy
            }
            if resolution.cardLayoutSource == .notebook {
                layouts[notebookId] = resolution.cardLayout
            }
        }
        return NotebookSettingsSnapshot(
            globalReviewSettings: globalReviewSettings,
            globalCardLayout: globalCardLayout,
            notebookReviewPolicies: policies,
            notebookCardLayouts: layouts
        )
    }
}

// MARK: - Notebook settings wire contract

struct KGNotebookReviewPolicy: Codable, Equatable, Sendable {
    let mode: ReviewSettingsMode
    let customInitialIntervalHours: Double
    let customRememberedMultiplier: Double
    let customForgotMultiplier: Double
    let customMinimumIntervalHours: Double
    let customMaximumIntervalHours: Double

    init(_ policy: ReviewPolicy) {
        mode = policy.mode
        customInitialIntervalHours = policy.customInitialIntervalHours
        customRememberedMultiplier = policy.customRememberedMultiplier
        customForgotMultiplier = policy.customForgotMultiplier
        customMinimumIntervalHours = policy.customMinimumIntervalHours
        customMaximumIntervalHours = policy.customMaximumIntervalHours
    }

    var reviewPolicy: ReviewPolicy {
        ReviewPolicy(
            mode: mode,
            customInitialIntervalHours: customInitialIntervalHours,
            customRememberedMultiplier: customRememberedMultiplier,
            customForgotMultiplier: customForgotMultiplier,
            customMinimumIntervalHours: customMinimumIntervalHours,
            customMaximumIntervalHours: customMaximumIntervalHours
        )
    }
}

struct KGNotebookCardLayout: Codable, Equatable, Sendable {
    let recognition: ReviewCardLayoutPreset
    let production: ReviewCardLayoutPreset

    init(_ profile: ReviewCardLayoutProfile) {
        recognition = profile.recognition
        production = profile.production
    }

    var profile: ReviewCardLayoutProfile {
        ReviewCardLayoutProfile(recognition: recognition, production: production)
    }
}

struct KGNotebookSettingsGroup<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let value: Value?
    let updatedAt: Double?
}

struct KGNotebookSettings: Codable, Equatable, Sendable {
    let reviewPolicy: KGNotebookSettingsGroup<KGNotebookReviewPolicy>
    let cardLayout: KGNotebookSettingsGroup<KGNotebookCardLayout>
}

struct KGNotebookSettingsPatchGroup<Value: Codable & Equatable & Sendable>: Encodable, Sendable {
    let value: Value?
    let updatedAt: Double
}

struct KGNotebookSettingsPatch: Encodable, Sendable {
    let reviewPolicy: KGNotebookSettingsPatchGroup<KGNotebookReviewPolicy>?
    let cardLayout: KGNotebookSettingsPatchGroup<KGNotebookCardLayout>?
}
