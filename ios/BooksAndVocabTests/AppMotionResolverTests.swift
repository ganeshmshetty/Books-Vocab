import Testing
@testable import BooksAndVocab

/// #3128 — review motion sites must honour Reduce Motion. Position / scale motion
/// (fling, snap-back, drag tracking) becomes instant; reveal, navigation and
/// completion keep only an opacity cross-fade. Off, every site keeps its spring.
@MainActor
struct AppMotionResolverTests {
    private static let positional: [AppMotionResolver.ReviewKind] = [
        .fling(duration: 0.2), .snapBack, .tracking,
    ]
    private static let fading: [AppMotionResolver.ReviewKind] = [
        .reveal, .navigation, .celebration,
    ]

    @Test("Reduce Motion turns positional review motion instant")
    func positionalMotionIsInstantUnderReduceMotion() {
        for kind in Self.positional {
            #expect(AppMotionResolver.resolve(kind, reduceMotion: true) == .instant)
            #expect(AppMotionResolver.animation(kind, reduceMotion: true) == nil)
        }
    }

    @Test("Reduce Motion reduces reveal, navigation and completion to a cross-fade")
    func fadingMotionIsCrossFadeUnderReduceMotion() {
        for kind in Self.fading {
            #expect(AppMotionResolver.resolve(kind, reduceMotion: true) == .crossFade)
            #expect(AppMotionResolver.animation(kind, reduceMotion: true) != nil)
        }
    }

    @Test("Swipe-linked feedback buttons are instant under Reduce Motion and keep their spring otherwise")
    func feedbackButtonMotionHonoursReduceMotion() {
        #expect(TodayReviewFeedbackMotion.animation(reduceMotion: true) == nil)
        #expect(TodayReviewFeedbackMotion.animation(reduceMotion: false) != nil)
    }

    @Test("Reduce Motion off keeps every review spring")
    func springsAreKeptWhenReduceMotionIsOff() {
        for kind in Self.positional + Self.fading {
            #expect(AppMotionResolver.resolve(kind, reduceMotion: false) == .spring(kind))
            #expect(AppMotionResolver.animation(kind, reduceMotion: false) != nil)
        }
    }
}
