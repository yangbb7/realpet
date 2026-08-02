import Foundation

/// Durable record for a provider task. It deliberately contains only IDs and
/// a persistent cloud-reference path: API credentials and signed URLs are
/// never persisted.
struct MotionGenerationJob: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case preparingReference
        case submitted
        case downloading
        case cancelledLocally
        case failed
    }

    let id: UUID
    let petID: UUID
    let action: FixedPetAction
    let provider: MotionVideoProvider
    var remoteJobID: String?
    var referenceObjectPath: String?
    var state: State
    var createdAt: Date
    var updatedAt: Date
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        petID: UUID,
        action: FixedPetAction,
        provider: MotionVideoProvider,
        remoteJobID: String? = nil,
        referenceObjectPath: String? = nil,
        state: State,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        failureMessage: String? = nil
    ) {
        self.id = id
        self.petID = petID
        self.action = action
        self.provider = provider
        self.remoteJobID = remoteJobID
        self.referenceObjectPath = referenceObjectPath
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.failureMessage = failureMessage
    }
}

enum MotionGenerationJobStoreError: LocalizedError {
    case unavailableDirectory

    var errorDescription: String? {
        switch self {
        case .unavailableDirectory: return "无法创建视频生成任务存储目录"
        }
    }
}

/// Append-replacement persistence for outstanding provider tasks. Atomic writes
/// keep a crash from replacing the prior journal with a partial file.
final class MotionGenerationJobStore {
    static let shared = MotionGenerationJobStore()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
            self.fileURL = (support ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("RealPet", isDirectory: true)
                .appendingPathComponent("motion-generation-jobs.json")
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [MotionGenerationJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([MotionGenerationJob].self, from: Data(contentsOf: fileURL))
    }

    func save(_ jobs: [MotionGenerationJob]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }

    func upsert(_ job: MotionGenerationJob) throws {
        var jobs = try load()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        try save(jobs)
    }

    func remove(id: UUID) throws {
        try save(try load().filter { $0.id != id })
    }
}
