//
//  TranslationServiceErrorMappingTests.swift
//  Books & Vocab Tests
//
//  Pins retry classification and decode-failure mapping of TranslationService.
//

import Foundation
import Testing
@testable import BooksAndVocab

@MainActor
struct TranslationServiceErrorMappingTests {
    private struct Payload: Decodable { let t: String }

    @Test func clientErrorStatusesAreNotRetryable() {
        for status in [400, 403, 404, 422] {
            #expect(TranslationService.isPermanentClientStatus(status))
        }
        for status in [500, 502, 503, 504] {
            #expect(!TranslationService.isPermanentClientStatus(status))
        }
    }

    @Test func decodeFailureBecomesParseError() {
        do {
            _ = try TranslationService.decodeResponse(Payload.self, from: Data("{}".utf8))
            Issue.record("expected parseError")
        } catch let error as TranslationError {
            guard case .parseError = error else {
                Issue.record("expected parseError, got \(error)")
                return
            }
        } catch {
            Issue.record("raw error leaked: \(error)")
        }
    }

    @Test func decodeSuccessReturnsValue() throws {
        let value = try TranslationService.decodeResponse(Payload.self, from: Data(#"{"t":"x"}"#.utf8))
        #expect(value.t == "x")
    }

    // MARK: - Local token expiry is not a client precheck (#3805)

    /// 本地 exp 已過期的 token 仍應送出請求（帶 Bearer），由伺服器決定是否 401。
    @Test func locallyExpiredTokenStillSendsRequestAndReturnsServerResult() async throws {
        let stub = TranslationStubURLProtocol.makeSession(responseBody: Data(#"{"t":"譯"}"#.utf8))
        let expired = TranslationTestSupport.jwt(expiresAt: Date().addingTimeInterval(-3600))
        let service = TranslationTestSupport.service(session: stub.session, token: expired)

        let translation = try await service.translatePhrase(phrase: "hello", context: "")

        #expect(translation == "譯")
        let requests = stub.requests
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(expired)")
    }

    @Test func serverRejectingExpiredTokenMapsTo401Message() async {
        let stub = TranslationStubURLProtocol.makeSession(statusCode: 401, responseBody: Data())
        let expired = TranslationTestSupport.jwt(expiresAt: Date().addingTimeInterval(-3600))
        let service = TranslationTestSupport.service(session: stub.session, token: expired)

        do {
            _ = try await service.translatePhrase(phrase: "hello", context: "")
            Issue.record("expected userRecoverable, got success")
        } catch let error as TranslationError {
            guard case .userRecoverable(let message) = error else {
                Issue.record("expected userRecoverable, got \(error)")
                return
            }
            #expect(message == L10n.string("登入憑證已失效，請重新登入"))
        } catch {
            Issue.record("raw error leaked: \(error)")
        }
        #expect(stub.requests.count == 1)
    }
}
