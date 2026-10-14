#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

/// #3905：離線開過清單後，sync 面板必須重探 server，「開始同步」才會反映當下連線。
@MainActor
@Suite("SyncView reconnect probe")
struct SyncViewReconnectProbeTests {
    /// 模擬 server 可達性：`healthCheck()` 才會把 `isConnected` 寫成 true（同 KGService+Health）。
    private final class StubHealth: HealthChecking {
        private(set) var healthCheckCalls = 0
        private(set) var isConnected = false
        let serverReachable: Bool

        init(serverReachable: Bool) { self.serverReachable = serverReachable }

        func healthCheck() async {
            healthCheckCalls += 1
            isConnected = serverReachable
        }
    }

    @Test func presentingSheetReprobesServerHealth() async {
        let stub = StubHealth(serverReachable: true)
        #expect(stub.isConnected == false)  // 離線開過清單後的狀態

        await SyncReconnectProbe.onPresent(stub)

        #expect(stub.healthCheckCalls == 1)
        #expect(stub.isConnected == true)
    }

    @Test func networkRestoredWhileSheetOpenReprobesServerHealth() async {
        let stub = StubHealth(serverReachable: true)
        #expect(stub.isConnected == false)

        await SyncReconnectProbe.onConnectivityChange(from: false, to: true, stub)

        #expect(stub.healthCheckCalls == 1)
        #expect(stub.isConnected == true)
    }

    @Test func connectivityDropOrSteadyStateDoesNotProbe() async {
        let stub = StubHealth(serverReachable: true)

        await SyncReconnectProbe.onConnectivityChange(from: true, to: false, stub)
        await SyncReconnectProbe.onConnectivityChange(from: true, to: true, stub)
        await SyncReconnectProbe.onConnectivityChange(from: false, to: false, stub)

        #expect(stub.healthCheckCalls == 0)
    }
}
#endif
