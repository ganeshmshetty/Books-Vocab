import Foundation

extension KGService: AddLinkOperationServing {}

extension KGService {
    func startAddLinkOperation(
        request: KGAddLinkOperationRequest,
        notebookId: String,
        idempotencyKey: String
    ) async throws -> KGAddLinkOperationStatus {
        try await authenticatedDecode(
            KGAddLinkOperationStatus.self,
            path: "api/graph/links/ensure-target",
            method: "POST",
            queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
            body: try JSONEncoder().encode(request),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func fetchAddLinkOperation(operationId: String) async throws -> KGAddLinkOperationStatus {
        // No transport retry: the coordinator owns poll pacing and treats 429 as "poll again
        // next tick". The default policy would sleep up to 60 s on Retry-After inside one poll,
        // past the coordinator's deadline (#3811).
        try await authenticatedDecode(
            KGAddLinkOperationStatus.self,
            path: "api/operations/\(operationId)",
            retryPolicy: .none
        )
    }
}
