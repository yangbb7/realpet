import Foundation

@MainActor
protocol PetRuntimeController: InteractionAdapter {
    var petId: UUID { get }
    var isRunning: Bool { get }
    var onTermination: (() -> Void)? { get set }

    func send(_ command: PetCommand)
    func terminate()
}
