import Foundation
import SwiftAIProvider
public func skillUploadRequestMetadata(_ request: SkillUploadRequest, includeDisplayTitle: Bool) -> AIRequestMetadata {
    var body: [String: JSONValue] = [
        "files": .array(request.files.map { file in
            .object([
                "path": .string(file.path),
                "mediaType": .string(file.mediaType),
                "byteLength": .number(Double(file.data.count))
            ])
        })
    ]
    if includeDisplayTitle, let displayTitle = request.displayTitle {
        body["displayTitle"] = .string(displayTitle)
    }
    if !request.providerOptions.isEmpty {
        body["providerOptions"] = .object(request.providerOptions)
    }
    return AIRequestMetadata(body: .object(body), headers: request.headers)
}
