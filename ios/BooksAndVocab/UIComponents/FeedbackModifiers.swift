import SwiftUI

enum AppFeedbackEvent: Equatable {
    case selection
    case impactLight
    case success
    case warning
    case error
    /// 複習評分「記得」的甩出回饋：success 類觸感，聲音沿用複習音效（#3127）。
    case gradeRemembered
    /// 複習評分「忘記」的甩出回饋：warning 類觸感，聲音沿用複習音效（#3127）。
    case gradeForgot

    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .selection:
            return .selection
        case .impactLight:
            return .impact(weight: .light)
        case .success, .gradeRemembered:
            return .success
        case .warning, .gradeForgot:
            return .warning
        case .error:
            return .error
        }
    }

    var sound: FeedbackSound {
        switch self {
        case .selection:
            return .tap
        case .impactLight, .gradeRemembered, .gradeForgot:
            return .review
        case .success:
            return .success
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    /// 評分甩出的回饋事件：記得 / 忘記 的觸感類別不同，聲音不變（#3127）。
    static func reviewGrade(remember: Bool) -> AppFeedbackEvent {
        remember ? .gradeRemembered : .gradeForgot
    }
}

private struct AppFeedbackModifier<Trigger: Equatable>: ViewModifier {
    @Environment(\.feedbackSettingsStore) private var settings
    @Environment(\.feedbackAudioService) private var audioService

    let event: AppFeedbackEvent
    let trigger: Trigger
    let condition: (Trigger, Trigger) -> Bool

    func body(content: Content) -> some View {
        Group {
            if settings.hapticFeedbackEnabled {
                content.sensoryFeedback(
                    event.sensoryFeedback,
                    trigger: trigger,
                    condition: condition
                )
            } else {
                content
            }
        }
        .onChange(of: trigger) { oldValue, newValue in
            guard settings.soundFeedbackEnabled, condition(oldValue, newValue) else { return }
            audioService.play(event.sound)
        }
    }
}

extension View {
    func appFeedback<Trigger: Equatable>(
        _ event: AppFeedbackEvent,
        trigger: Trigger,
        condition: @escaping (Trigger, Trigger) -> Bool = { _, _ in true }
    ) -> some View {
        modifier(AppFeedbackModifier(event: event, trigger: trigger, condition: condition))
    }
}
