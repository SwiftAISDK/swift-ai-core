import Foundation


public typealias AIIdGenerator = @Sendable () -> String
public typealias AICallback<Event> = @Sendable (Event) async throws -> Void