import Foundation
import SwiftAIProvider
import SwiftAITransport


public func validateDecisionInput(state: AIDecisionState, questions: [String: AIDecisionQuestion]) throws {
    switch state {
    case let .text(text):
        try validateEvaluationInput(state: .string(text), questions: questions, decision: true)
    case let .object(value):
        try validateEvaluationInput(state: .object(value), questions: questions, decision: true)
    case let .parts(parts):
        try validateEvaluationInput(state: .string(""), questions: questions, decision: true)
        for part in parts {
            switch part {
            case .text: break
            case let .json(value):
                guard isFiniteJSON(value) else {
                    throw AIError.invalidArgument(argument: "state", message: "JSON state parts must contain finite JSON.")
                }
            case let .file(mediaType, data, _, providerOptions):
                guard !mediaType.isEmpty, providerOptions.values.allSatisfy(isFiniteJSON) else {
                    throw AIError.invalidArgument(argument: "state", message: "File state parts require a media type and finite provider options.")
                }
                if case let .url(url) = data {
                    guard ["https", "http", "data"].contains(url.scheme?.lowercased() ?? "") else {
                        throw AIError.invalidArgument(argument: "state", message: "File URLs must use HTTP, HTTPS, or data.")
                    }
                }
            }
        }
    }
}

package func prepareDecisionState(
    _ state: AIDecisionState,
    abortSignal: AIAbortSignal?,
    transport: any AITransport = URLSessionTransport.shared
) async throws -> [AIDecisionStatePart] {
    let parts: [AIDecisionStatePart]
    switch state {
    case let .text(text): return [.text(text)]
    case let .object(value): return [.json(.object(value))]
    case let .parts(value): parts = value
    }
    var prepared: [AIDecisionStatePart] = []
    prepared.reserveCapacity(parts.count)
    for part in parts {
        try abortSignal?.throwIfAborted()
        guard case let .file(mediaType, data, filename, providerOptions) = part else {
            prepared.append(part)
            continue
        }
        let resolvedData: AIDecisionFileData
        let resolvedMediaType: String
        switch data {
        case let .data(bytes):
            resolvedData = data
            resolvedMediaType = try resolveFullMediaType(mediaType: mediaType, data: bytes)
        case let .base64(base64):
            guard let bytes = Data(base64Encoded: base64) else {
                throw AIError.invalidArgument(argument: "state", message: "File data must be valid base64.")
            }
            resolvedData = data
            resolvedMediaType = try resolveFullMediaType(mediaType: mediaType, data: bytes)
        case let .url(url):
            let response: AIHTTPResponse
            do {
                response = try await downloadURL(url.absoluteString, transport: transport, abortSignal: abortSignal)
            } catch {
                if error is AIAbortError || error is CancellationError || error is AIDownloadError { throw error }
                throw AIDownloadError(url: url.absoluteString, message: String(describing: error))
            }
            guard (200..<300).contains(response.statusCode) else {
                throw AIDownloadError(url: url.absoluteString, message: "Download failed with HTTP status \(response.statusCode).")
            }
            try abortSignal?.throwIfAborted()
            let downloadedMediaType = response.headerValue("content-type")?.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let type = isFullMediaType(mediaType) ? mediaType : (downloadedMediaType ?? mediaType)
            resolvedMediaType = try resolveFullMediaType(mediaType: type, data: response.body)
            if url.scheme?.lowercased() == "data", let comma = url.absoluteString.firstIndex(of: ","), url.absoluteString[..<comma].hasSuffix(";base64") {
                resolvedData = .base64(String(url.absoluteString[url.absoluteString.index(after: comma)...]))
            } else {
                resolvedData = .data(response.body)
            }
        case .reference:
            resolvedData = data
            resolvedMediaType = mediaType
        }
        prepared.append(.file(mediaType: resolvedMediaType, data: resolvedData, filename: filename, providerOptions: providerOptions))
    }
    return prepared
}

package func validateDecisionAnswers(
    questions: [String: AIDecisionQuestion],
    answers: [String: AIDecisionAnswer],
    rounding: AIDecisionRounding?,
    providerID: String
) throws {
    let probabilityError = try decisionRoundingError(
        rounding?.probabilityDecimals,
        providerID: providerID
    )
    let scoreError = try decisionRoundingError(
        rounding?.scoreDecimals,
        providerID: providerID
    )

    guard answers.count == questions.count,
          Set(answers.keys) == Set(questions.keys) else {
        throw invalidDecisionResponse(
            providerID: providerID,
            "Decision must return exactly one answer for every question."
        )
    }

    for (id, question) in questions {
        if answers[id] == .refusal { continue }
        guard let answer = answers[id], answer.questionType == question.type else {
            throw invalidDecisionResponse(
                providerID: providerID,
                "Question \"\(id)\" returned an answer with the wrong type."
            )
        }

        switch (question, answer) {
        case let (.choice(_, criteria), .choice(choice, probabilities)):
            guard criteria.keys.contains(choice) else {
                throw invalidDecisionResponse(
                    providerID: providerID,
                    "Question \"\(id)\" selected an unknown option."
                )
            }
            if let probabilities {
                try validateDecisionDistribution(
                    probabilities,
                    keys: Array(criteria.keys),
                    questionID: id,
                    roundingError: probabilityError,
                    providerID: providerID
                )
                guard let selected = probabilities[choice],
                      !probabilities.values.contains(where: { $0 > selected + decisionTolerance + 2 * probabilityError }) else {
                    throw invalidDecisionResponse(
                        providerID: providerID,
                        "Question \"\(id)\" did not select a highest-probability option."
                    )
                }
            }
        case let (.score(_, criteria), .score(score, probabilities)):
            guard score.isFinite, score >= 0, score <= Double(criteria.count - 1) else {
                throw invalidDecisionResponse(
                    providerID: providerID,
                    "Question \"\(id)\" score must be in [0, \(criteria.count - 1)]."
                )
            }
            if let probabilities {
                let keys = criteria.indices.map(String.init)
                try validateDecisionDistribution(
                    probabilities,
                    keys: keys,
                    questionID: id,
                    roundingError: probabilityError,
                    providerID: providerID
                )
                let mean = probabilities.reduce(0.0) { total, entry in
                    total + (Double(entry.key) ?? 0) * entry.value
                }
                let meanRoundingError = keys.reduce(0.0) { total, key in
                    total + (Double(key) ?? 0) * probabilityError
                }
                guard abs(mean - score) <= decisionTolerance + meanRoundingError + scoreError else {
                    throw invalidDecisionResponse(
                        providerID: providerID,
                        "Question \"\(id)\" score must equal the probability-weighted mean within the declared rounding precision."
                    )
                }
            }
        case let (.box, .box(box)):
            guard box.isValid else {
                throw invalidDecisionResponse(providerID: providerID, "Question \"\(id)\" must return box edges in [0, 1] with left < right and top < bottom.")
            }
        case let (.boolean, .boolean(probability)):
            guard isDecisionProbability(probability) else {
                throw invalidDecisionResponse(
                    providerID: providerID,
                    "Question \"\(id)\" must return P(true) as a finite probability in [0, 1]."
                )
            }
        default:
            throw invalidDecisionResponse(
                providerID: providerID,
                "Question \"\(id)\" returned an answer with the wrong type."
            )
        }
    }
}

private let decisionTolerance = 1e-6

private func decisionRoundingError(
    _ decimals: Int?,
    providerID: String
) throws -> Double {
    guard let decimals else { return 0 }
    guard (0...15).contains(decimals) else {
        throw invalidDecisionResponse(
            providerID: providerID,
            "Decision rounding decimals must be integers between 0 and 15."
        )
    }
    return 0.5 * pow(10, -Double(decimals))
}

private func validateDecisionDistribution(
    _ probabilities: [String: Double],
    keys: [String],
    questionID: String,
    roundingError: Double,
    providerID: String
) throws {
    guard probabilities.count == keys.count,
          Set(probabilities.keys) == Set(keys),
          probabilities.values.allSatisfy(isDecisionProbability) else {
        throw invalidDecisionResponse(
            providerID: providerID,
            "Question \"\(questionID)\" must have a complete distribution of finite probabilities in [0, 1]."
        )
    }
    let sum = probabilities.values.reduce(0, +)
    guard abs(sum - 1) <= decisionTolerance + Double(keys.count) * roundingError else {
        throw invalidDecisionResponse(
            providerID: providerID,
            "Question \"\(questionID)\" probabilities must sum to 1 within the declared rounding precision."
        )
    }
}

private func isDecisionProbability(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value <= 1
}

private func invalidDecisionResponse(providerID: String, _ message: String) -> AIError {
    .invalidResponse(provider: providerID, message: message)
}