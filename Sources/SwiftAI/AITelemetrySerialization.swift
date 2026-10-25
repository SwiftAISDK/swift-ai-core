import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func languageRequestTelemetryInput(_ request: LanguageModelRequest) -> JSONValue {
    .object([
        "messages": .array(request.messages.map(messageTelemetryJSON)),
        "temperature": request.temperature.map(JSONValue.number),
        "topP": request.topP.map(JSONValue.number),
        "topK": request.topK.map { .number(Double($0)) },
        "presencePenalty": request.presencePenalty.map(JSONValue.number),
        "frequencyPenalty": request.frequencyPenalty.map(JSONValue.number),
        "seed": request.seed.map { .number(Double($0)) },
        "maxOutputTokens": request.maxOutputTokens.map { .number(Double($0)) },
        "stopSequences": .array(request.stopSequences.map(JSONValue.string)),
        "reasoning": request.reasoning.map(JSONValue.string),
        "tools": request.tools.isEmpty ? nil : .object(request.tools),
        "toolChoice": request.toolChoice,
        "includeRawChunks": .bool(request.includeRawChunks),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func languageRequestMetadataBody(_ request: LanguageModelRequest) -> JSONValue {
    .object([
        "messages": .array(request.messages.map(messageTelemetryJSON)),
        "temperature": request.temperature.map(JSONValue.number),
        "topP": request.topP.map(JSONValue.number),
        "topK": request.topK.map { .number(Double($0)) },
        "presencePenalty": request.presencePenalty.map(JSONValue.number),
        "frequencyPenalty": request.frequencyPenalty.map(JSONValue.number),
        "seed": request.seed.map { .number(Double($0)) },
        "maxOutputTokens": request.maxOutputTokens.map { .number(Double($0)) },
        "stopSequences": request.stopSequences.isEmpty ? nil : .array(request.stopSequences.map(JSONValue.string)),
        "responseFormat": request.responseFormat.map(responseFormatTelemetryJSON),
        "reasoning": request.reasoning.map(JSONValue.string),
        "tools": request.tools.isEmpty ? nil : .object(request.tools),
        "toolChoice": request.toolChoice,
        "includeRawChunks": request.includeRawChunks ? .bool(true) : nil,
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func responseFormatTelemetryJSON(_ responseFormat: AIResponseFormat) -> JSONValue {
    switch responseFormat {
    case .text:
        return .object(["type": .string("text")])
    case let .json(schema, name, description):
        return .object([
            "type": .string("json"),
            "schema": schema,
            "name": name.map(JSONValue.string),
            "description": description.map(JSONValue.string)
        ])
    }
}

func objectGenerationTelemetryInput(
    _ request: LanguageModelRequest,
    outputKind: String,
    schema: JSONValue?,
    schemaName: String?,
    schemaDescription: String?
) -> JSONValue {
    var object = languageRequestTelemetryInput(request).objectValue ?? [:]
    object["output"] = .string(outputKind)
    object["schema"] = schema
    object["schemaName"] = schemaName.map(JSONValue.string)
    object["schemaDescription"] = schemaDescription.map(JSONValue.string)
    return .object(object)
}

func messageTelemetryJSON(_ message: AIMessage) -> JSONValue {
    .object([
        "role": .string(message.role.rawValue),
        "content": .array(message.content.map(contentPartTelemetryJSON))
    ])
}

func contentPartTelemetryJSON(_ part: AIContentPart) -> JSONValue {
    switch part {
    case let .text(text, _):
        return .object(["type": .string("text"), "text": .string(text)])
    case let .reasoning(text, _):
        return .object(["type": .string("reasoning"), "text": .string(text)])
    case let .imageURL(url, _):
        return .object(["type": .string("image-url"), "url": .string(url)])
    case let .data(mimeType, data, _):
        return .object(["type": .string("data"), "mimeType": .string(mimeType), "byteLength": .number(Double(data.count))])
    case let .file(mimeType, data, filename, _):
        return .object(["type": .string("file"), "mimeType": .string(mimeType), "byteLength": .number(Double(data.count)), "filename": filename.map(JSONValue.string)])
    case let .reasoningFile(file):
        return .object([
            "type": .string("reasoning-file"),
            "id": file.id.map(JSONValue.string),
            "mediaType": .string(file.mediaType),
            "filename": file.filename.map(JSONValue.string)
        ])
    case let .custom(value, _):
        return .object(["type": .string("custom"), "value": value])
    case let .providerReference(mimeType, reference, filename, _):
        return .object([
            "type": .string("provider-reference"),
            "mimeType": .string(mimeType),
            "reference": .object(reference.mapValues(JSONValue.string)),
            "filename": filename.map(JSONValue.string)
        ])
    case let .toolCall(call):
        return .object(["type": .string("tool-call"), "id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments)])
    case let .toolResult(result):
        return .object([
            "type": .string("tool-result"),
            "toolCallID": .string(result.toolCallID),
            "toolName": .string(result.toolName),
            "result": result.result,
            "modelOutput": result.modelOutput
        ])
    case let .toolApprovalRequest(request):
        return .object([
            "type": .string("tool-approval-request"),
            "id": .string(request.id),
            "toolName": .string(request.toolName),
            "arguments": .string(request.arguments),
            "descriptor": request.descriptor
        ])
    case let .toolApprovalResponse(response):
        return .object(["type": .string("tool-approval-response"), "id": .string(response.id), "approved": .bool(response.approved)])
    }
}

func embeddingRequestTelemetryInput(_ request: EmbeddingRequest) -> JSONValue {
    .object([
        "values": .array(request.values.map(JSONValue.string)),
        "dimensions": request.dimensions.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func embeddingRequestMetadataBody(_ request: EmbeddingRequest) -> JSONValue {
    .object([
        "values": .array(request.values.map(JSONValue.string)),
        "dimensions": request.dimensions.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func imageRequestTelemetryInput(_ request: ImageGenerationRequest) -> JSONValue {
    .object([
        "prompt": .string(request.prompt),
        "size": request.size.map(JSONValue.string),
        "aspectRatio": request.aspectRatio.map(JSONValue.string),
        "seed": request.seed.map { .number(Double($0)) },
        "count": request.count.map { .number(Double($0)) },
        "files": .array(request.files.map(imageFileTelemetryJSON)),
        "mask": request.mask.map(imageFileTelemetryJSON),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func imageFileTelemetryJSON(_ file: ImageInputFile) -> JSONValue {
    .object([
        "type": file.url == nil ? .string("data") : .string("url"),
        "url": file.url.map(JSONValue.string),
        "mediaType": file.mediaType.map(JSONValue.string),
        "fileName": file.fileName.map(JSONValue.string),
        "byteLength": file.data.map { .number(Double($0.count)) }
    ])
}

func transcriptionRequestTelemetryInput(_ request: AudioTranscriptionRequest) -> JSONValue {
    .object([
        "fileName": .string(request.fileName),
        "mimeType": .string(request.mimeType),
        "byteLength": .number(Double(request.audio.count)),
        "language": request.language.map(JSONValue.string),
        "prompt": request.prompt.map(JSONValue.string),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func transcriptionRequestMetadataBody(_ request: AudioTranscriptionRequest) -> JSONValue {
    .object([
        "fileName": .string(request.fileName),
        "mimeType": .string(request.mimeType),
        "byteLength": .number(Double(request.audio.count)),
        "language": request.language.map(JSONValue.string),
        "prompt": request.prompt.map(JSONValue.string),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func speechRequestTelemetryInput(_ request: SpeechRequest) -> JSONValue {
    .object([
        "text": .string(request.text),
        "voice": request.voice.map(JSONValue.string),
        "format": request.format.map(JSONValue.string),
        "speed": request.speed.map(JSONValue.number),
        "language": request.language.map(JSONValue.string),
        "instructions": request.instructions.map(JSONValue.string),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func speechRequestMetadataBody(_ request: SpeechRequest) -> JSONValue {
    .object([
        "text": .string(request.text),
        "voice": request.voice.map(JSONValue.string),
        "format": request.format.map(JSONValue.string),
        "speed": request.speed.map(JSONValue.number),
        "language": request.language.map(JSONValue.string),
        "instructions": request.instructions.map(JSONValue.string),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func audioGenerationRequestTelemetryInput(_ request: AudioGenerationRequest) -> JSONValue {
    .object([
        "prompt": .string(request.prompt),
        "durationSeconds": request.durationSeconds.map(JSONValue.number),
        "format": request.format.map(JSONValue.string),
        "seed": request.seed.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func audioGenerationRequestMetadataBody(_ request: AudioGenerationRequest) -> JSONValue {
    .object([
        "prompt": .string(request.prompt),
        "durationSeconds": request.durationSeconds.map(JSONValue.number),
        "format": request.format.map(JSONValue.string),
        "seed": request.seed.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func audioTransformationRequestTelemetryInput(_ request: AudioTransformationRequest) -> JSONValue {
    .object([
        "fileName": .string(request.fileName),
        "mimeType": .string(request.mimeType),
        "byteLength": .number(Double(request.audio.count)),
        "voice": request.voice.map(JSONValue.string),
        "format": request.format.map(JSONValue.string),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func audioTransformationRequestMetadataBody(_ request: AudioTransformationRequest) -> JSONValue {
    .object([
        "fileName": .string(request.fileName),
        "mimeType": .string(request.mimeType),
        "byteLength": .number(Double(request.audio.count)),
        "voice": request.voice.map(JSONValue.string),
        "format": request.format.map(JSONValue.string),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func videoRequestTelemetryInput(_ request: VideoGenerationRequest) -> JSONValue {
    .object([
        "prompt": .string(request.prompt),
        "aspectRatio": request.aspectRatio.map(JSONValue.string),
        "durationSeconds": request.durationSeconds.map(JSONValue.number),
        "image": request.image.map(imageInputFileRequestMetadata),
        "frameImages": request.frameImages.isEmpty ? nil : .array(request.frameImages.map(videoFrameImageRequestMetadata)),
        "inputReferences": request.inputReferences.isEmpty ? nil : .array(request.inputReferences.map(imageInputFileRequestMetadata)),
        "resolution": request.resolution.map(JSONValue.string),
        "fps": request.fps.map(JSONValue.number),
        "generateAudio": request.generateAudio.map(JSONValue.bool),
        "seed": request.seed.map { .number(Double($0)) },
        "count": request.count.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func rerankingRequestTelemetryInput(_ request: RerankingRequest) -> JSONValue {
    .object([
        "query": .string(request.query),
        "documents": .array(request.documentsJSON),
        "topK": request.topK.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func rerankingRequestMetadataBody(_ request: RerankingRequest) -> JSONValue {
    .object([
        "query": .string(request.query),
        "documents": .array(request.documentsJSON),
        "topK": request.topK.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func fileUploadRequestTelemetryInput(_ request: FileUploadRequest) -> JSONValue {
    .object([
        "mediaType": .string(request.mediaType),
        "filename": request.filename.map(JSONValue.string),
        "purpose": request.purpose.map(JSONValue.string),
        "displayName": request.displayName.map(JSONValue.string),
        "byteLength": .number(Double(request.data.count)),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func fileUploadRequestMetadataBody(_ request: FileUploadRequest) -> JSONValue {
    .object([
        "mediaType": .string(request.mediaType),
        "filename": request.filename.map(JSONValue.string),
        "purpose": request.purpose.map(JSONValue.string),
        "displayName": request.displayName.map(JSONValue.string),
        "byteLength": .number(Double(request.data.count)),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

func skillUploadRequestTelemetryInput(_ request: SkillUploadRequest) -> JSONValue {
    .object([
        "displayTitle": request.displayTitle.map(JSONValue.string),
        "files": .array(request.files.map { file in
            .object([
                "path": .string(file.path),
                "mediaType": .string(file.mediaType),
                "byteLength": .number(Double(file.data.count))
            ])
        }),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "headers": headersTelemetryJSON(request.headers)
    ])
}

func skillUploadRequestMetadataBody(_ request: SkillUploadRequest) -> JSONValue {
    .object([
        "displayTitle": request.displayTitle.map(JSONValue.string),
        "files": .array(request.files.map { file in
            .object([
                "path": .string(file.path),
                "mediaType": .string(file.mediaType),
                "byteLength": .number(Double(file.data.count))
            ])
        }),
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions)
    ])
}

func headersTelemetryJSON(_ headers: [String: String]) -> JSONValue? {
    headers.isEmpty ? nil : .object(headers.mapValues(JSONValue.string))
}

func stepTelemetryInput(
    index: Int,
    maxSteps: Int,
    request: LanguageModelRequest,
    tools: [AITool]
) -> JSONValue {
    .object([
        "stepNumber": .number(Double(index)),
        "maxSteps": .number(Double(maxSteps)),
        "request": languageRequestTelemetryInput(request),
        "tools": .array(tools.map(toolTelemetryJSON))
    ])
}

func toolStepTelemetryOutput(_ step: AIToolStep) -> JSONValue {
    .object([
        "stepNumber": .number(Double(step.index)),
        "text": .string(step.text),
        "reasoning": step.reasoning.isEmpty ? nil : .string(step.reasoning),
        "finishReason": step.finishReason.map(JSONValue.string),
        "toolCalls": .array(step.toolCalls.map(toolCallTelemetryJSON)),
        "toolResults": .array(step.toolResults.map(toolResultTelemetryJSON)),
        "toolApprovalRequests": .array(step.toolApprovalRequests.map(toolApprovalRequestTelemetryJSON)),
        "toolApprovalResponses": .array(step.toolApprovalResponses.map(toolApprovalResponseTelemetryJSON))
    ])
}

func toolTelemetryJSON(_ tool: AITool) -> JSONValue {
    .object([
        "name": .string(tool.name),
        "description": tool.description.map(JSONValue.string),
        "parameters": tool.parameters,
        "dynamic": .bool(tool.dynamic),
        "providerMetadata": tool.providerMetadata.isEmpty ? nil : .object(tool.providerMetadata)
    ])
}

func toolCallTelemetryJSON(_ call: AIToolCall) -> JSONValue {
    .object([
        "id": .string(call.id),
        "name": .string(call.name),
        "arguments": .string(call.arguments),
        "providerExecuted": .bool(call.providerExecuted),
        "dynamic": .bool(call.dynamic),
        "title": call.title.map(JSONValue.string),
        "providerMetadata": call.providerMetadata.isEmpty ? nil : .object(call.providerMetadata),
        "rawValue": call.rawValue
    ])
}

func toolResultTelemetryJSON(_ result: AIToolResult) -> JSONValue {
    .object([
        "toolCallID": .string(result.toolCallID),
        "toolName": .string(result.toolName),
        "result": result.result,
        "modelOutput": result.modelOutput,
        "isError": .bool(result.isError),
        "preliminary": .bool(result.preliminary),
        "dynamic": .bool(result.dynamic),
        "providerExecuted": .bool(result.providerExecuted),
        "providerMetadata": result.providerMetadata.isEmpty ? nil : .object(result.providerMetadata)
    ])
}

func toolApprovalRequestTelemetryJSON(_ request: AIToolApprovalRequest) -> JSONValue {
    .object([
        "id": .string(request.id),
        "toolCallID": request.toolCallID.map(JSONValue.string),
        "toolName": .string(request.toolName),
        "arguments": .string(request.arguments),
        "inputSchemaInput": request.inputSchemaInput,
        "descriptor": request.descriptor,
        "reason": request.reason.map(JSONValue.string),
        "isAutomatic": .bool(request.isAutomatic),
        "providerMetadata": request.providerMetadata.isEmpty ? nil : .object(request.providerMetadata)
    ])
}

func toolApprovalResponseTelemetryJSON(_ response: AIToolApprovalResponse) -> JSONValue {
    .object([
        "id": .string(response.id),
        "approved": .bool(response.approved),
        "reason": response.reason.map(JSONValue.string),
        "providerExecuted": .bool(response.providerExecuted),
        "providerMetadata": response.providerMetadata.isEmpty ? nil : .object(response.providerMetadata)
    ])
}

func toolExecutionTelemetryInput(stepIndex: Int, call: AIToolCall, tool: AITool) -> JSONValue {
    .object([
        "stepNumber": .number(Double(stepIndex)),
        "toolCall": toolCallTelemetryJSON(call),
        "tool": toolTelemetryJSON(tool)
    ])
}

func toolExecutionTelemetryOutput(
    stepIndex: Int,
    call: AIToolCall,
    status: String,
    arguments: JSONValue?,
    result: AIToolResult?,
    approvalRequest: AIToolApprovalRequest?,
    approvalResponse: AIToolApprovalResponse?
) -> JSONValue {
    .object([
        "stepNumber": .number(Double(stepIndex)),
        "toolCall": toolCallTelemetryJSON(call),
        "status": .string(status),
        "arguments": arguments,
        "result": result.map(toolResultTelemetryJSON),
        "approvalRequest": approvalRequest.map(toolApprovalRequestTelemetryJSON),
        "approvalResponse": approvalResponse.map(toolApprovalResponseTelemetryJSON)
    ])
}

func textGenerationTelemetryOutput(_ result: TextGenerationResult) -> JSONValue {
    .object([
        "text": .string(result.text),
        "reasoning": result.reasoning.isEmpty ? nil : .string(result.reasoning),
        "finishReason": result.finishReason.map(JSONValue.string),
        "toolCallCount": .number(Double(result.toolCalls.count)),
        "toolResultCount": .number(Double(result.toolResults.count)),
        "sourceCount": .number(Double(result.sources.count)),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func objectGenerationTelemetryOutput<Object>(_ result: ObjectGenerationResult<Object>) -> JSONValue {
    .object([
        "text": .string(result.text),
        "rawObject": result.rawObject,
        "reasoning": result.reasoning.isEmpty ? nil : .string(result.reasoning),
        "finishReason": result.finishReason.map(JSONValue.string),
        "rawValue": result.textResult.rawValue
    ])
}

func objectStreamTelemetryOutput(
    text: String,
    rawObject: JSONValue?,
    partialCount: Int,
    finishReason: String?
) -> JSONValue {
    .object([
        "text": .string(text),
        "rawObject": rawObject,
        "partialObjectCount": .number(Double(partialCount)),
        "finishReason": finishReason.map(JSONValue.string)
    ])
}

func embeddingTelemetryOutput(_ result: EmbeddingResult) -> JSONValue {
    .object([
        "embeddings": .array(result.embeddings.map { .array($0.map(JSONValue.number)) }),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func imageTelemetryOutput(_ result: ImageGenerationResult) -> JSONValue {
    .object([
        "urls": .array(result.urls.map(JSONValue.string)),
        "base64ImageCount": .number(Double(result.base64Images.count)),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func transcriptionTelemetryOutput(_ result: TranscriptionResult) -> JSONValue {
    .object([
        "text": .string(result.text),
        "language": result.language.map(JSONValue.string),
        "durationInSeconds": result.durationInSeconds.map(JSONValue.number),
        "segmentCount": .number(Double(result.segments.count)),
        "usage": result.usage.map(JSONValue.object),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func speechTelemetryOutput(_ result: SpeechResult) -> JSONValue {
    .object([
        "byteLength": .number(Double(result.audio.count)),
        "contentType": result.contentType.map(JSONValue.string),
        "usage": result.usage.map(JSONValue.object),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata)
    ])
}

func audioGenerationTelemetryOutput(_ result: AudioGenerationResult) -> JSONValue {
    .object([
        "byteLength": .number(Double(result.audio.count)),
        "contentType": result.contentType.map(JSONValue.string),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func audioTransformationTelemetryOutput(_ result: AudioTransformationResult) -> JSONValue {
    .object([
        "byteLength": .number(Double(result.audio.count)),
        "contentType": result.contentType.map(JSONValue.string),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func videoTelemetryOutput(_ result: VideoGenerationResult) -> JSONValue {
    .object([
        "urls": .array(result.urls.map(JSONValue.string)),
        "base64VideoCount": .number(Double(result.base64Videos.count)),
        "operationID": result.operationID.map(JSONValue.string),
        "mediaType": result.mediaType.map(JSONValue.string),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func rerankingTelemetryOutput(_ result: RerankingResult) -> JSONValue {
    .object([
        "results": .array(result.results.map { ranked in
            .object([
                "index": .number(Double(ranked.index)),
                "score": .number(ranked.score),
                "document": ranked.document.map(JSONValue.string)
            ])
        }),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func fileUploadTelemetryOutput(_ result: FileUploadResult) -> JSONValue {
    .object([
        "providerReference": .object(result.providerReference.mapValues(JSONValue.string)),
        "filename": result.filename.map(JSONValue.string),
        "mediaType": result.mediaType.map(JSONValue.string),
        "metadata": result.metadata.isEmpty ? nil : .object(result.metadata),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "warnings": result.warnings.isEmpty ? nil : .array(result.warnings.map(aiWarningJSON)),
        "rawValue": result.rawValue
    ])
}

func skillUploadTelemetryOutput(_ result: SkillUploadResult) -> JSONValue {
    .object([
        "providerReference": .object(result.providerReference.mapValues(JSONValue.string)),
        "displayTitle": result.displayTitle.map(JSONValue.string),
        "name": result.name.map(JSONValue.string),
        "description": result.description.map(JSONValue.string),
        "latestVersion": result.latestVersion.map(JSONValue.string),
        "requestMetadata": aiRequestMetadataJSON(result.requestMetadata),
        "rawValue": result.rawValue
    ])
}

func aiRequestMetadataJSON(_ metadata: AIRequestMetadata) -> JSONValue? {
    guard metadata.body != nil || !metadata.headers.isEmpty else {
        return nil
    }
    return .object([
        "body": metadata.body,
        "headers": metadata.headers.isEmpty ? nil : .object(metadata.headers.mapValues(JSONValue.string))
    ])
}