import Foundation

@main
struct PetRecoveryCheck {
    static func main() {
        testTransientStatusesRecoverAsInterrupted()
        testCompletedAndTerminalStatusesRemainStable()
        testShowingStateAlwaysBecomesReady()
        testLegacyPetDecodesWithoutPersonality()
        print("Pet recovery checks passed")
    }

    private static func testTransientStatusesRecoverAsInterrupted() {
        let statuses: [Pet.Status] = [.detecting, .detected, .processing]
        let saved = statuses.enumerated().map {
            makePet(status: $0.element, createdAt: TimeInterval($0.offset))
        }
        let recovery = Pet.recoveringAfterLaunch(saved)

        precondition(recovery.changed)
        precondition(recovery.pets.count == 1)
        precondition(recovery.pets[0].status == .interrupted)
        precondition(recovery.pets[0].id == saved[2].id)
    }

    private static func testCompletedAndTerminalStatusesRemainStable() {
        let draft = makePet(status: .draft, createdAt: 0)
        let ready = makePet(status: .ready, framesDir: "/tmp/frames", createdAt: 1)
        let failed = makePet(status: .failed, createdAt: 2)
        let interrupted = makePet(status: .interrupted, createdAt: 3)
        let showing = makePet(status: .showing, framesDir: "/tmp/frames", createdAt: 4)
        let recovery = Pet.recoveringAfterLaunch(
            [draft, ready, failed, interrupted, showing])

        precondition(recovery.changed)
        precondition(recovery.pets.count == 1)
        precondition(recovery.pets[0].status == .ready)
        precondition(recovery.pets[0].framesDir == "/tmp/frames")
    }

    private static func testShowingStateAlwaysBecomesReady() {
        let recovery = Pet.recoveringAfterLaunch([makePet(status: .showing)])
        precondition(recovery.changed)
        precondition(recovery.pets[0].status == .ready)
    }

    private static func testLegacyPetDecodesWithoutPersonality() {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy",\
        "frameCount":0,"fps":10,"createdAt":0,"status":"ready"}
        """
        let decoded = try? JSONDecoder().decode(Pet.self, from: Data(json.utf8))
        precondition(decoded?.name == "Legacy")
        precondition(decoded?.personality == nil)
        precondition(decoded?.referenceImages.isEmpty == true)
        precondition(decoded?.cloudReferences.isEmpty == true)
        precondition(decoded?.cloudOwnerID == nil)
    }

    private static func makePet(status: Pet.Status,
                                framesDir: String? = nil,
                                createdAt: TimeInterval = 0) -> Pet {
        Pet(id: UUID(), name: "Test Pet", sourcePath: "/tmp/source.mp4",
            framesDir: framesDir, frameCount: framesDir == nil ? 0 : 10,
            fps: 10, createdAt: Date(timeIntervalSince1970: createdAt), status: status)
    }
}
