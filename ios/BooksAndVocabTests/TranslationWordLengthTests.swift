//
//  TranslationWordLengthTests.swift
//  Books & Vocab Tests
//
//  Pins the client-side word length gate of TranslationService (#3802) and hosts the
//  shared URLProtocol stub used by TranslationService request-path tests.
//

import Foundation
import Testing
@testable import BooksAndVocab

/// 錄下送進 `TranslationService` 的 request，並依 session marker 回傳指定 response。
/// 只掛在 local `URLSessionConfiguration.ephemeral` 上、不呼叫 `URLProtocol.registerClass`，
/// 不污染其他測試。每個 session 帶唯一 marker header，記錄以 marker 分桶，所以不同 suite 並行也互不干擾。
final class TranslationStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Session {
        let session: URLSession
        private let marker: String

        fileprivate init(session: URLSession, marker: String) {
            self.session = session
            self.marker = marker
        }

        var requests: [URLRequest] { TranslationStubURLProtocol.requests(for: marker) }
    }

    private static let markerHeader = "X-Translation-Stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [(marker: String, request: URLRequest)] = []
    nonisolated(unsafe) private static var responses: [String: (statusCode: Int, body: Data)] = [:]

    static func makeSession(statusCode: Int = 200, responseBody: Data = Data()) -> Session {
        let marker = UUID().uuidString
        lock.withLock { responses[marker] = (statusCode, responseBody) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [markerHeader: marker]
        return Session(session: URLSession(configuration: configuration), marker: marker)
    }

    fileprivate static func requests(for marker: String) -> [URLRequest] {
        lock.withLock { entries.filter { $0.marker == marker }.map(\.request) }
    }

    /// URLSession 交給 URLProtocol 的 POST body 放在 `httpBodyStream`，`httpBody` 為 nil。
    /// 先讀進 `httpBody` 再記錄，測試才能解析實際送出的 JSON。
    private static func materializingBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var copy = request
        copy.httpBody = drain(stream)
        copy.httpBodyStream = nil
        return copy
    }

    private static func drain(_ stream: InputStream) -> Data {
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        var data = Data()
        stream.open()
        defer { stream.close() }
        while true {
            let count = stream.read(&buffer, maxLength: capacity)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = Self.materializingBody(of: self.request)
        let marker = request.value(forHTTPHeaderField: Self.markerHeader) ?? ""
        let reply = Self.lock.withLock { () -> (statusCode: Int, body: Data) in
            Self.entries.append((marker, request))
            return Self.responses[marker] ?? (500, Data())
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: reply.statusCode, httpVersion: nil, headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `QuotaProviding` 替身。放在 @MainActor enum 之外：production `QuotaStore` 同為 nonisolated，
/// 巢狀於 @MainActor enum 內可能繼承 isolation，與 nonisolated protocol 要求產生不必要的衝突。
private final class StubQuotaStore: QuotaProviding {
    var fraction: Double { 0 }
    var isExhausted: Bool { false }
    var level: QuotaStore.Level { .normal }
    var resetText: String { "" }

    func update(from response: HTTPURLResponse) {}
}

/// `TranslationService` 測試共用的 auth／quota 替身與 JWT 產生器。
@MainActor
enum TranslationTestSupport {
    final class StubAuthSession: AuthSessionProviding {
        let isLoggedIn = true
        let token: String?

        init(token: String?) { self.token = token }
    }

    /// 只需 `exp` claim；`JWTExpiry` 只解 payload。
    static func jwt(expiresAt: Date) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": expiresAt.timeIntervalSince1970])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).sig"
    }

    static func service(session: URLSession, token: String?) -> TranslationService {
        TranslationService(
            authSession: StubAuthSession(token: token),
            quotaStore: StubQuotaStore(),
            session: session
        )
    }
}

@MainActor
@Suite(.serialized)
struct TranslationWordLengthTests {
    /// 與 backend `MAX_WORD_LENGTH = 200`（pydantic max_length，以 code point 計）一致。
    private static let maxWordLength = 200

    private static let validToken = TranslationTestSupport.jwt(expiresAt: Date().addingTimeInterval(3600))

    private static func overLimit() -> String {
        String(repeating: "a", count: maxWordLength + 1)
    }

    /// 斷言 `operation` 丟出 `.userRecoverable`，且不是 raw error。
    private static func expectUserRecoverable(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected userRecoverable, got success")
        } catch let error as TranslationError {
            guard case .userRecoverable = error else {
                Issue.record("expected userRecoverable, got \(error)")
                return
            }
        } catch {
            Issue.record("raw error leaked: \(error)")
        }
    }

    @Test func overLimitPhraseIsRejectedBeforeAnyRequest() async {
        let stub = TranslationStubURLProtocol.makeSession(
            statusCode: 422, responseBody: Data(#"{"detail":"too long"}"#.utf8)
        )
        let service = TranslationTestSupport.service(session: stub.session, token: Self.validToken)

        await Self.expectUserRecoverable {
            _ = try await service.translatePhrase(phrase: Self.overLimit(), context: "")
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func overLimitExplanationIsRejectedBeforeAnyRequest() async {
        let stub = TranslationStubURLProtocol.makeSession(
            statusCode: 422, responseBody: Data(#"{"detail":"too long"}"#.utf8)
        )
        let service = TranslationTestSupport.service(session: stub.session, token: Self.validToken)

        await Self.expectUserRecoverable {
            _ = try await service.fetchExplanation(word: Self.overLimit(), context: "")
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func exactlyMaxLengthIsSentUnchanged() async throws {
        let stub = TranslationStubURLProtocol.makeSession(responseBody: Data(#"{"t":"x"}"#.utf8))
        let service = TranslationTestSupport.service(session: stub.session, token: Self.validToken)
        let boundary = String(repeating: "a", count: Self.maxWordLength)

        let translation = try await service.translatePhrase(phrase: boundary, context: "")

        #expect(translation == "x")
        let requests = stub.requests
        #expect(requests.count == 1)
        let body = try JSONSerialization.jsonObject(with: requests.first?.httpBody ?? Data()) as? [String: String]
        #expect(body?["word"] == boundary)
    }
}
