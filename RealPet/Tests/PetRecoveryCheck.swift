import Foundation

@main
struct PetRecoveryCheck {
    static func main() {
        testTransientStatusesRecoverAsInterrupted()
        testCompletedAndTerminalStatusesRemainStable()
        testShowingStateAlwaysBecomesReady()
        testLegacyPetDecodesWithoutPersonality()
        testWindowLayoutExposesClipSelection()
        print("Pet recovery checks passed")
    }

    private static func testTransientStatusesRecoverAsInterrupted() {
        let statuses: [Pet.Status] = [.detecting, .detected, .processing]
        let saved = statuses.map { makePet(status: $0) }
        let recovery = Pet.recoveringAfterLaunch(saved)

        precondition(recovery.changed)
        precondition(recovery.pets.map(\.status)
                     == [.interrupted, .interrupted, .interrupted])
        precondition(recovery.pets.map(\.sourcePath) == saved.map(\.sourcePath))
    }

    private static func testCompletedAndTerminalStatusesRemainStable() {
        let draft = makePet(status: .draft)
        let ready = makePet(status: .ready, framesDir: "/tmp/frames")
        let failed = makePet(status: .failed)
        let interrupted = makePet(status: .interrupted)
        let showing = makePet(status: .showing, framesDir: "/tmp/frames")
        let recovery = Pet.recoveringAfterLaunch(
            [draft, ready, failed, interrupted, showing])

        precondition(recovery.changed)
        precondition(recovery.pets.map(\.status)
                     == [.draft, .ready, .failed, .interrupted, .ready])
        precondition(recovery.pets[4].framesDir == "/tmp/frames")
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
    }

    private static func testWindowLayoutExposesClipSelection() {
        let regular = MainWindowLayout.contentSize(
            hasClipSelection: true, hasDetection: false,
            isProcessing: false, visibleHeight: 900)
        precondition(regular.width == 640 && regular.height == 650)

        let smallScreen = MainWindowLayout.contentSize(
            hasClipSelection: true, hasDetection: false,
            isProcessing: false, visibleHeight: 600)
        precondition(smallScreen.width == 640 && smallScreen.height == 520)

        let idle = MainWindowLayout.contentSize(
            hasClipSelection: false, hasDetection: false,
            isProcessing: false, visibleHeight: 900)
        precondition(idle.width == 320 && idle.height == 300)
    }

    private static func makePet(status: Pet.Status,
                                framesDir: String? = nil) -> Pet {
        Pet(id: UUID(), name: "Test Pet", sourcePath: "/tmp/source.mp4",
            framesDir: framesDir, frameCount: framesDir == nil ? 0 : 10,
            fps: 10, createdAt: Date(timeIntervalSince1970: 0), status: status)
    }
}
