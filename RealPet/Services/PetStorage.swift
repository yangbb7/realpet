import Foundation

enum PetStorageError: LocalizedError {
    case unreadableCatalog(Error)
    case unwritableCatalog(Error)
    case undeletablePet(Error)

    var errorDescription: String? {
        switch self {
        case .unreadableCatalog(let error):
            return "无法读取宠物数据：\(error.localizedDescription)"
        case .unwritableCatalog(let error):
            return "无法保存宠物数据：\(error.localizedDescription)"
        case .undeletablePet(let error):
            return "无法删除宠物文件：\(error.localizedDescription)"
        }
    }
}

class PetStorage {
    static let shared = PetStorage()

    let appSupportURL: URL
    let petsDir: URL
    let petsFile: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportURL = base.appendingPathComponent("RealPet")
        petsDir = appSupportURL.appendingPathComponent("pets")
        petsFile = appSupportURL.appendingPathComponent("pets.json")

    }

    func petDirectory(for id: UUID) -> URL {
        petsDir.appendingPathComponent(id.uuidString)
    }

    private func petsFile(for ownerID: UUID) -> URL {
        appSupportURL.appendingPathComponent(
            "pets-\(ownerID.uuidString.lowercased()).json")
    }

    func load() throws -> [Pet] {
        try load(from: petsFile)
    }

    func load(ownerID: UUID) throws -> [Pet] {
        try load(from: petsFile(for: ownerID))
    }

    private func load(from url: URL) throws -> [Pet] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([Pet].self, from: Data(contentsOf: url))
        } catch {
            throw PetStorageError.unreadableCatalog(error)
        }
    }

    func save(_ pets: [Pet]) throws {
        try save(pets, to: petsFile)
    }

    func save(_ pets: [Pet], ownerID: UUID) throws {
        try save(pets, to: petsFile(for: ownerID))
    }

    private func save(_ pets: [Pet], to destination: URL) throws {
        // Persist exactly one active pet. Older pet folders are intentionally
        // retained so changing the selected pet never destroys owner media.
        let singleton = pets.max { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }.map { [$0] } ?? []
        do {
            try FileManager.default.createDirectory(
                at: petsDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(singleton)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw PetStorageError.unwritableCatalog(error)
        }
    }

    func deletePet(_ pet: Pet) throws {
        let dir = petDirectory(for: pet.id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            throw PetStorageError.undeletablePet(error)
        }
    }
}
