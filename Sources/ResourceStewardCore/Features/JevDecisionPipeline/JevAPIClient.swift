import Foundation

public struct JevPayloadResult: Sendable {
    public var requestID: String
    public var model: String
    public var answersJSON: Data
    public var usage: JevUsage
    public var httpStatus: Int
    public var latencyMs: Int

    public init(
        requestID: String,
        model: String,
        answersJSON: Data,
        usage: JevUsage = .init(),
        httpStatus: Int,
        latencyMs: Int
    ) {
        self.requestID = requestID
        self.model = model
        self.answersJSON = answersJSON
        self.usage = usage
        self.httpStatus = httpStatus
        self.latencyMs = latencyMs
    }
}

public protocol JevClientProtocol: Sendable {
    func evaluatePayload(
        stateJSON: Data,
        questionsJSON: Data,
        apiKey: String,
        requestID: String,
        endpoint: URL,
        model: String
    ) async throws -> JevPayloadResult
}

public struct JevURLSessionClient: JevClientProtocol, Sendable {
    public static let defaultModel = "jev-latest"
    public static let defaultBaseURLString = "https://api.typesafe.ai/v1/systemone"
    public static let openRouterBaseURLString = "https://openrouter.ai/api/alpha/decisions"
    public static let openRouterDefaultModel = "~typesafe/jev-latest"
    public static let defaultEndpoint = URL(string: defaultBaseURLString)!

    
    
    public static func resolveEndpoint(baseURLString: String) -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultEndpoint }
        var raw = trimmed
        if !raw.contains("://") {
            raw = "https://" + raw
        }
        return URL(string: raw) ?? defaultEndpoint
    }

    public var session: URLSession
    public var timeoutSeconds: TimeInterval
    public var endpoint: URL

    public init(
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 12,
        endpoint: URL = JevURLSessionClient.defaultEndpoint
    ) {
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.endpoint = endpoint
    }

    public func evaluatePayload(
        stateJSON: Data,
        questionsJSON: Data,
        apiKey: String,
        requestID: String,
        endpoint: URL,
        model: String
    ) async throws -> JevPayloadResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JevClientError.missingAPIKey }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = modelID.isEmpty ? JevURLSessionClient.defaultModel : modelID

        var request = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")

        let stateObj = try JSONSerialization.jsonObject(with: stateJSON)
        let questionsObj = try JSONSerialization.jsonObject(with: questionsJSON)
        let body: [String: Any] = [
            "state": stateObj,
            "model": resolvedModel,
            "questions": questionsObj
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw JevClientError.timeout
        } catch {
            throw JevClientError.transport(error.localizedDescription)
        }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 {
            throw JevClientError.httpStatus(status, "unauthorized")
        }
        guard (200..<300).contains(status) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw JevClientError.httpStatus(status, redactSecrets(snippet))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] else {
            throw JevClientError.parse("missing answers")
        }
        let answersJSON = try JSONSerialization.data(withJSONObject: answers)
        var usage = JevUsage()
        if let usageObj = root["usage"] as? [String: Any] {
            usage = JevUsage(
                inputTokens: intNumber(usageObj["input_tokens"]),
                outputTokens: intNumber(usageObj["output_tokens"])
            )
        }
        return JevPayloadResult(
            requestID: requestID,
            model: (root["model"] as? String) ?? resolvedModel,
            answersJSON: answersJSON,
            usage: usage,
            httpStatus: status,
            latencyMs: latencyMs
        )
    }

    private func intNumber(_ raw: Any?) -> Int? {
        switch raw {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }

    private func redactSecrets(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"Bearer\s+[A-Za-z0-9._\-]+"#,
                with: "Bearer <redacted>",
                options: .regularExpression
            )
    }
}
