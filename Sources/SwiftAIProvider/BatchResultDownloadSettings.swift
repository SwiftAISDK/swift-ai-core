public struct AIBatchResultDownloadSettings: Equatable, Sendable {
    /// Maximum UTF-8 bytes in a downloaded JSON Lines row, excluding LF.
    /// The default limit is 64 MiB.
    public var maxLineBytes: Int?

    public init(maxLineBytes: Int? = nil) {
        self.maxLineBytes = maxLineBytes
    }
}
