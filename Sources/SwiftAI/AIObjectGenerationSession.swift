import Foundation
import Combine
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public enum AIObjectGenerationSessionStatus: String, Equatable, Hashable, Sendable {
    case ready
    case submitted
    case streaming
    case error
}

public struct AIObjectGenerationSessionFinishEvent<Output: Sendable>: Sendable {
    public var object: Output?
    public var result: AIOutputGenerationResult<Output>?
    public var error: Error?

    public init(
        object: Output?,
        result: AIOutputGenerationResult<Output>?,
        error: Error? = nil
    ) {
        self.object = object
        self.result = result
        self.error = error
    }
}

public struct AIObjectGenerationSessionRequestOptions: Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var seed: Int?
    public var maxOutputTokens: Int?
    public var stopSequences: [String]
    public var reasoning: String?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var timeoutNanoseconds: UInt64?
    public var retryPolicy: AIRetryPolicy
    public var telemetry: Telemetry.Options?
    public var jsonInstruction: AIJSONInstruction?
    public var repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        reasoning: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.reasoning = reasoning
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryPolicy = retryPolicy
        self.telemetry = telemetry
        self.jsonInstruction = jsonInstruction
        self.repairText = repairText
    }

    public func languageModelRequest(
        messages: [AIMessage],
        abortSignal: AIAbortSignal? = nil
    ) -> LanguageModelRequest {
        LanguageModelRequest(
            messages: messages,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            reasoning: reasoning,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal
        )
    }
}

@MainActor
public final class AIObjectGenerationSession<Output: Sendable, Partial: Sendable>: ObservableObject {
    @Published public private(set) var partialObject: Partial?
    @Published public private(set) var object: Output?
    @Published public private(set) var result: AIOutputGenerationResult<Output>?
    @Published public private(set) var status: AIObjectGenerationSessionStatus
    @Published public private(set) var error: Error?
    @Published public private(set) var text: String
    @Published public private(set) var warnings: [AIWarning]
    @Published public private(set) var sources: [AISource]
    @Published public private(set) var metadata: [String: JSONValue]
    @Published public private(set) var responseMetadata: AIResponseMetadata?
    @Published public private(set) var finishReason: String?
    @Published public private(set) var usage: TokenUsage?

    public var model: any LanguageModel
    public var output: AIOutput<Output, Partial>
    public var onError: (@MainActor @Sendable (Error) -> Void)?
    public var onFinish: (@MainActor @Sendable (AIObjectGenerationSessionFinishEvent<Output>) -> Void)?

    private var currentTask: Task<Void, Never>?
    private var currentAbortController: AIAbortController?
    private var activeRunID: UUID?

    public init(
        model: any LanguageModel,
        output: AIOutput<Output, Partial>,
        initialPartialObject: Partial? = nil,
        initialObject: Output? = nil,
        onError: (@MainActor @Sendable (Error) -> Void)? = nil,
        onFinish: (@MainActor @Sendable (AIObjectGenerationSessionFinishEvent<Output>) -> Void)? = nil
    ) {
        self.model = model
        self.output = output
        self.partialObject = initialPartialObject
        self.object = initialObject
        self.result = nil
        self.status = .ready
        self.error = nil
        self.text = ""
        self.warnings = []
        self.sources = []
        self.metadata = [:]
        self.responseMetadata = nil
        self.finishReason = nil
        self.usage = nil
        self.onError = onError
        self.onFinish = onFinish
    }

    public var isLoading: Bool {
        status == .submitted || status == .streaming
    }

    @discardableResult
    public func submit(
        _ prompt: String,
        options: AIObjectGenerationSessionRequestOptions = AIObjectGenerationSessionRequestOptions()
    ) -> Task<Void, Never> {
        submit(messages: [.user(prompt)], options: options)
    }

    @discardableResult
    public func submit(
        messages: [AIMessage],
        options: AIObjectGenerationSessionRequestOptions = AIObjectGenerationSessionRequestOptions()
    ) -> Task<Void, Never> {
        let controller = AIAbortController()
        return submit(
            request: options.languageModelRequest(messages: messages, abortSignal: controller.signal),
            timeoutNanoseconds: options.timeoutNanoseconds,
            retryPolicy: options.retryPolicy,
            telemetry: options.telemetry,
            jsonInstruction: options.jsonInstruction,
            repairText: options.repairText,
            abortController: controller
        )
    }

    @discardableResult
    public func submit(
        request: LanguageModelRequest,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> Task<Void, Never> {
        let controller = AIAbortController()
        var request = request
        request.abortSignal = controller.signal
        return submit(
            request: request,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText,
            abortController: controller
        )
    }

    public func stop(reason: String? = "stopped") {
        currentAbortController?.abort(reason: reason)
        currentTask?.cancel()
        currentAbortController = nil
        currentTask = nil
        activeRunID = nil
        if isLoading {
            status = .ready
        }
    }

    public func clear() {
        stop()
        clearGeneratedOutput()
    }

    public func clearError() {
        error = nil
        if status == .error {
            status = .ready
        }
    }

    private func submit(
        request: LanguageModelRequest,
        timeoutNanoseconds: UInt64?,
        retryPolicy: AIRetryPolicy,
        telemetry: Telemetry.Options?,
        jsonInstruction: AIJSONInstruction?,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)?,
        abortController: AIAbortController
    ) -> Task<Void, Never> {
        stop()
        clearGeneratedOutput()

        let runID = UUID()
        activeRunID = runID
        currentAbortController = abortController
        status = .submitted
        error = nil

        let task = Task { [weak self] in
            guard let self else { return }
            let stream = AI.streamText(
                model: model,
                request: request,
                output: output,
                timeoutNanoseconds: timeoutNanoseconds,
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                jsonInstruction: jsonInstruction,
                repairText: repairText
            )
            await consume(stream, runID: runID)
        }
        currentTask = task
        return task
    }

    private func consume(_ stream: AsyncThrowingStream<AIOutputStreamPart<Output, Partial>, Error>, runID: UUID) async {
        do {
            for try await part in stream {
                guard activeRunID == runID else { return }
                consume(part)
                if status == .submitted {
                    status = .streaming
                }
            }
            finish(runID: runID, error: nil)
        } catch is CancellationError {
            clearRunWithoutFinish(runID: runID)
        } catch is AIAbortError {
            clearRunWithoutFinish(runID: runID)
        } catch {
            finish(runID: runID, error: error)
        }
    }

    private func consume(_ part: AIOutputStreamPart<Output, Partial>) {
        switch part {
        case let .textDelta(delta):
            text += delta
        case let .partialOutput(partial):
            partialObject = partial
        case let .output(outputResult):
            result = outputResult
            object = outputResult.output
        case let .warning(warning):
            warnings.append(warning)
        case let .source(source):
            sources.append(source)
        case let .metadata(partMetadata):
            metadata.merge(partMetadata) { _, new in new }
        case let .responseMetadata(partResponseMetadata):
            responseMetadata = partResponseMetadata
        case .raw:
            break
        case let .finish(reason, partUsage):
            finishReason = reason
            usage = partUsage
        }
    }

    private func finish(runID: UUID, error: Error?) {
        guard activeRunID == runID else { return }
        currentTask = nil
        currentAbortController = nil
        activeRunID = nil

        if let error {
            if isFinalOutputError(error) {
                status = .ready
                onFinish?(AIObjectGenerationSessionFinishEvent(
                    object: nil,
                    result: nil,
                    error: error
                ))
            } else {
                self.error = error
                status = .error
                onError?(error)
            }
            return
        }

        status = .ready
        onFinish?(AIObjectGenerationSessionFinishEvent(
            object: object,
            result: result,
            error: nil
        ))
    }

    private func clearRunWithoutFinish(runID: UUID) {
        guard activeRunID == runID else { return }
        currentTask = nil
        currentAbortController = nil
        activeRunID = nil
        status = .ready
    }

    private func clearGeneratedOutput() {
        partialObject = nil
        object = nil
        result = nil
        error = nil
        text = ""
        warnings = []
        sources = []
        metadata = [:]
        responseMetadata = nil
        finishReason = nil
        usage = nil
        if status == .error {
            status = .ready
        }
    }

    private func isFinalOutputError(_ error: Error) -> Bool {
        error is AIObjectGenerationError || error is AINoOutputError
    }
}