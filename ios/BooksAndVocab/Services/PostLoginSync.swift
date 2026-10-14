import Foundation
import SwiftData

/// 登入後的背景同步觸發（#3807）。
///
/// 登入是帳號邊界：上一個帳號的同步輪可能仍持有 process-wide 的 sync lane。
/// 一般的 `backgroundSync` 遇到佔用即回 `.didNotRun`，會把新帳號的第一輪同步
/// 直接丟掉。帳號邊界必須排隊等待前一輪結束，與 Settings 的帳號切換路徑一致。
enum PostLoginSync {
    @discardableResult
    static func run(
        on service: any BackgroundSyncing,
        container: ModelContainer,
        progress: SyncProgressReporting?
    ) async -> SyncRoundOutcome {
        await service.backgroundSyncWhenAvailable(container: container, progress: progress)
    }
}
