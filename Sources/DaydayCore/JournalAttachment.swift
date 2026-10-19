import Foundation

// MARK: - Journal attachments

public struct JournalRelativeFileKey: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidValue
    }

    public let rawValue: String

    /// Storage-generated POSIX-style key. It is intentionally stricter than a
    /// user filename so it remains relative on macOS and future Windows builds.
    public init(rawValue: String) throws {
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 512,
              !rawValue.hasPrefix("/"),
              !rawValue.contains("\\"),
              !rawValue.contains(":"),
              rawValue.utf8.allSatisfy(\.isSafeRelativeKeyByte),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError.invalidValue
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum JournalImageMediaType: String, Codable, CaseIterable, Hashable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case webp = "image/webp"
}

public struct JournalImageAttachment: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidPixelSize
        case invalidByteCount(Int)
    }

    public let relativeFileKey: JournalRelativeFileKey
    public let mediaType: JournalImageMediaType
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int

    public init(
        relativeFileKey: JournalRelativeFileKey,
        mediaType: JournalImageMediaType,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int
    ) throws {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ValidationError.invalidPixelSize
        }
        guard byteCount > 0 else {
            throw ValidationError.invalidByteCount(byteCount)
        }

        self.relativeFileKey = relativeFileKey
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case relativeFileKey, mediaType, pixelWidth, pixelHeight, byteCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativeFileKey: values.decode(JournalRelativeFileKey.self, forKey: .relativeFileKey),
            mediaType: values.decode(JournalImageMediaType.self, forKey: .mediaType),
            pixelWidth: values.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: values.decode(Int.self, forKey: .pixelHeight),
            byteCount: values.decode(Int.self, forKey: .byteCount)
        )
    }
}

public struct JournalLinkAttachment: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedURL
    }

    public let url: URL
    public let title: String?

    public init(url: URL, title: String? = nil) throws {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw ValidationError.unsupportedURL
        }
        self.url = url
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case url, title }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            url: values.decode(URL.self, forKey: .url),
            title: values.decodeIfPresent(String.self, forKey: .title)
        )
    }
}

public enum JournalAttachmentPayload: Codable, Hashable, Sendable {
    case image(JournalImageAttachment)
    case link(JournalLinkAttachment)
}

public struct JournalAttachment: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case nonFiniteCreationDate
    }

    public let id: JournalAttachmentID
    public let journalEntryID: JournalEntryID
    public let dayID: DayID
    public let payload: JournalAttachmentPayload
    public let createdAt: Date

    public init(
        id: JournalAttachmentID = JournalAttachmentID(),
        journalEntryID: JournalEntryID,
        dayID: DayID,
        payload: JournalAttachmentPayload,
        createdAt: Date
    ) throws {
        guard createdAt.isFinite else {
            throw ValidationError.nonFiniteCreationDate
        }
        self.id = id
        self.journalEntryID = journalEntryID
        self.dayID = dayID
        self.payload = payload
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, journalEntryID, dayID, payload, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(JournalAttachmentID.self, forKey: .id),
            journalEntryID: values.decode(JournalEntryID.self, forKey: .journalEntryID),
            dayID: values.decode(DayID.self, forKey: .dayID),
            payload: values.decode(JournalAttachmentPayload.self, forKey: .payload),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }

    var isSafeRelativeKeyByte: Bool {
        isASCIIAlphaNumeric || self == 45 || self == 46 || self == 47 || self == 95
    }

}
