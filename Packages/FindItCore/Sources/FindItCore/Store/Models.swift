import Foundation
import GRDB

/// Where a screenshot is in the indexing pipeline. Saved after every step so indexing can resume.
public enum Status: String, Codable, Sendable, DatabaseValueConvertible {
    case pending
    case ocrDone = "ocr_done"
    case described
    case indexed
    case failed
}

/// One row of the `screenshots` table.
public struct Screenshot: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "screenshots"

    public var id: Int64?
    /// Always Unicode NFC, matching scripts/build_golden.py. macOS can hand back NFD filenames,
    /// and SQLite compares text byte by byte, so an unnormalized "é" would never match.
    public var path: String {
        didSet { path = Self.normalizedPath(path) }
    }
    public var fileHash: String
    public var createdAt: Date
    public var status: Status
    public var failReason: String?
    public var failCount: Int
    public var ocrText: String?
    public var description: String?
    public var category: String?
    public var language: String?
    /// Stored as a JSON array.
    public var labels: [String]?
    /// Raw JSON from the describer. Kept as text until its shape is settled.
    public var entities: String?
    public var describerModel: String?
    public var indexedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case fileHash = "file_hash"
        case createdAt = "created_at"
        case status
        case failReason = "fail_reason"
        case failCount = "fail_count"
        case ocrText = "ocr_text"
        case description
        case category
        case language
        case labels
        case entities
        case describerModel = "describer_model"
        case indexedAt = "indexed_at"
    }

    public init(
        id: Int64? = nil,
        path: String,
        fileHash: String,
        createdAt: Date,
        status: Status = .pending,
        failReason: String? = nil,
        failCount: Int = 0,
        ocrText: String? = nil,
        description: String? = nil,
        category: String? = nil,
        language: String? = nil,
        labels: [String]? = nil,
        entities: String? = nil,
        describerModel: String? = nil,
        indexedAt: Date? = nil
    ) {
        self.id = id
        self.path = Self.normalizedPath(path)
        self.fileHash = fileHash
        self.createdAt = createdAt
        self.status = status
        self.failReason = failReason
        self.failCount = failCount
        self.ocrText = ocrText
        self.description = description
        self.category = category
        self.language = language
        self.labels = labels
        self.entities = entities
        self.describerModel = describerModel
        self.indexedAt = indexedAt
    }

    // Written out so rows read from the database are normalized too: a decoded value skips
    // didSet, and saving it back would otherwise keep an NFD path from raw SQL or older rows.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id),
            path: try container.decode(String.self, forKey: .path),
            fileHash: try container.decode(String.self, forKey: .fileHash),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            status: try container.decode(Status.self, forKey: .status),
            failReason: try container.decodeIfPresent(String.self, forKey: .failReason),
            failCount: try container.decode(Int.self, forKey: .failCount),
            ocrText: try container.decodeIfPresent(String.self, forKey: .ocrText),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            category: try container.decodeIfPresent(String.self, forKey: .category),
            language: try container.decodeIfPresent(String.self, forKey: .language),
            labels: try container.decodeIfPresent([String].self, forKey: .labels),
            entities: try container.decodeIfPresent(String.self, forKey: .entities),
            describerModel: try container.decodeIfPresent(String.self, forKey: .describerModel),
            indexedAt: try container.decodeIfPresent(Date.self, forKey: .indexedAt)
        )
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Use this on any path before comparing it with stored paths in SQL.
    public static func normalizedPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }
}

extension Screenshot {
    static let maxFailReasonLength = 1000
}
