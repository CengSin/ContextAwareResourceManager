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
    func evaluate(
        state: JevRequestState,
        apiKey: String,
        requestID: String,
        endpoint: URL,
        model: String
    ) async throws -> JevClientResult

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
    public static let defaultBaseURLString = "https://api.typesafe.ai"
    public static let defaultEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// Resolve a user-configured base URL (or full evaluate URL) to the POST endpoint.
    /// - Host-only (e.g. `https://api.typesafe.ai`) → append `/v1/systemone`
    /// - Full TypeSafe URL ending in `/v1/systemone` → keep
    /// - Full OpenRouter Decisions URL ending in `/api/alpha/decisions` → keep
    public static func resolveEndpoint(baseURLString: String) -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultEndpoint }
        var raw = trimmed
        if !raw.contains("://") {
            raw = "https://" + raw
        }
        guard var components = URLComponents(string: raw) else { return defaultEndpoint }
        // Allow pasting a full evaluate / decisions URL (do not append another path).
        let path = components.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = "/" + path
        if isCompleteEvaluatePath(fullPath) {
            // Normalize trailing slash away for stable equality / logging.
            while components.path.hasSuffix("/") {
                components.path.removeLast()
            }
            if let url = components.url { return url }
            return defaultEndpoint
        }
        // Treat as API host/base: strip trailing slash and append /v1/systemone.
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1/systemone"
        } else {
            components.path += "/v1/systemone"
        }
        return components.url ?? defaultEndpoint
    }

    /// Paths that are already a POST target (not a host/prefix to extend).
    private static func isCompleteEvaluatePath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix("/v1/systemone") || p.hasSuffix("/api/alpha/decisions")
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

    public func evaluate(
        state: JevRequestState,
        apiKey: String,
        requestID: String,
        endpoint: URL,
        model: String
    ) async throws -> JevClientResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JevClientError.missingAPIKey }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = modelID.isEmpty ? JevQuestions.defaultModel : modelID

        let payload = try await evaluatePayload(
            stateJSON: JSONEncoder().encode(state),
            questionsJSON: try JSONSerialization.data(withJSONObject: JevQuestions.payload()),
            apiKey: trimmed,
            requestID: requestID,
            endpoint: endpoint,
            model: resolvedModel
        )
        do {
            return try JevResponseParser.parse(
                data: wrapAnswers(payload),
                requestID: payload.requestID,
                httpStatus: payload.httpStatus,
                latencyMs: payload.latencyMs
            )
        } catch let error as JevClientError {
            throw error
        } catch {
            throw JevClientError.parse(error.localizedDescription)
        }
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
        let resolvedModel = modelID.isEmpty ? JevQuestions.defaultModel : modelID

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

    private func wrapAnswers(_ payload: JevPayloadResult) throws -> Data {
        let answers = try JSONSerialization.jsonObject(with: payload.answersJSON)
        let root: [String: Any] = [
            "model": payload.model,
            "answers": answers,
            "usage": [
                "input_tokens": payload.usage.inputTokens as Any,
                "output_tokens": payload.usage.outputTokens as Any
            ]
        ]
        return try JSONSerialization.data(withJSONObject: root)
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

public enum JevResponseParser: Sendable {
    public static func parse(
        data: Data,
        requestID: String,
        httpStatus: Int,
        latencyMs: Int
    ) throws -> JevClientResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevClientError.parse("root not object")
        }
        let model = root["model"] as? String ?? JevQuestions.defaultModel
        guard let answersObj = root["answers"] as? [String: Any] else {
            throw JevClientError.parse("missing answers")
        }
        let answers = try decodeAnswers(answersObj)
        var usage = JevUsage()
        if let usageObj = root["usage"] as? [String: Any] {
            usage = JevUsage(
                inputTokens: intValue(usageObj["input_tokens"]),
                outputTokens: intValue(usageObj["output_tokens"])
            )
        }
        return JevClientResult(
            requestID: requestID,
            model: model,
            answers: answers,
            usage: usage,
            httpStatus: httpStatus,
            latencyMs: latencyMs,
            fromCache: false
        )
    }

    public static func decodeAnswers(_ answers: [String: Any]) throws -> JevEvaluationAnswers {
        func noul(_ key: String) throws -> Double {
            guard let obj = answers[key] as? [String: Any] else {
                throw JevClientError.incompleteAnswers
            }
            if let value = doubleValue(obj["noul"]) { return clamp01(value) }
            throw JevClientError.incompleteAnswers
        }
        guard let preferredObj = answers["preferred_action"] as? [String: Any],
              let choice = preferredObj["choice"] as? String else {
            throw JevClientError.incompleteAnswers
        }
        let confidence = clamp01(doubleValue(preferredObj["confidence"]) ?? 0)
        var probabilities: [String: Double] = [:]
        if let probs = preferredObj["probabilities"] as? [String: Any] {
            for (key, raw) in probs {
                if let value = doubleValue(raw) {
                    probabilities[key] = value
                }
            }
        }
        return JevEvaluationAnswers(
            looksLikeNetworkOrSync: try noul("looks_like_network_or_sync"),
            looksLikeCommunication: try noul("looks_like_communication"),
            looksLikeInputOrA11y: try noul("looks_like_input_or_a11y"),
            looksLikeAVOrCapture: try noul("looks_like_av_or_capture"),
            userLikelyNeedsSoon: try noul("user_likely_needs_soon"),
            safeToReclaimIdle: try noul("safe_to_reclaim_idle"),
            preferredAction: JevChoiceAnswer(
                choice: choice,
                confidence: confidence,
                probabilities: probabilities
            )
        )
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }
}

/// Test double / injectable client.
public struct JevMockClient: JevClientProtocol, Sendable {
    public var result: Result<JevClientResult, JevClientError>
    public var onEvaluate: (@Sendable (JevRequestState) -> Void)?

    public init(
        result: Result<JevClientResult, JevClientError>,
        onEvaluate: (@Sendable (JevRequestState) -> Void)? = nil
    ) {
        self.result = result
        self.onEvaluate = onEvaluate
    }

    public var payloadResult: Result<JevPayloadResult, JevClientError>?

    public func evaluate(
        state: JevRequestState,
        apiKey: String,
        requestID: String,
        endpoint: URL,
        model: String
    ) async throws -> JevClientResult {
        _ = apiKey
        _ = endpoint
        _ = model
        onEvaluate?(state)
        switch result {
        case .success(var value):
            value = JevClientResult(
                requestID: requestID,
                model: value.model,
                answers: value.answers,
                usage: value.usage,
                httpStatus: value.httpStatus,
                latencyMs: value.latencyMs,
                fromCache: false
            )
            return value
        case .failure(let error):
            throw error
        }
    }

    public func evaluatePayload(
        stateJSON: Data,
        questionsJSON: Data,
        apiKey: String,
        requestID: String,
        endpoint: URL,
        model: String
    ) async throws -> JevPayloadResult {
        _ = stateJSON
        _ = questionsJSON
        _ = apiKey
        _ = endpoint
        _ = model
        guard let payloadResult else {
            throw JevClientError.parse("mock payload not configured")
        }
        switch payloadResult {
        case .success(var value):
            value.requestID = requestID
            return value
        case .failure(let error):
            throw error
        }
    }
}
