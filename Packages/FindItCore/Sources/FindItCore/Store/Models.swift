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
    public var path: String
    public var fileHash: String
    public var createdAt: Date
    public var status: Status
    public var failReason: String?
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
        self.path = path
        self.fileHash = fileHash
        self.createdAt = createdAt
        self.status = status
        self.failReason = failReason
        self.ocrText = ocrText
        self.description = description
        self.category = category
        self.language = language
        self.labels = labels
        self.entities = entities
        self.describerModel = describerModel
        self.indexedAt = indexedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
