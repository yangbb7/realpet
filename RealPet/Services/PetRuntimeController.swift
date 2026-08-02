import Foundation

@MainActor
protocol PetRuntimeController: InteractionAdapter {
    var petId: UUID { get }
    var isRunning: Bool { get }
    var windowOrigin: CGPoint? { get }
    var onTermination: (() -> Void)? { get set }

    func send(_ command: PetCommand)
    func setDisplayScale(_ scale: Double)
    func terminate()
}
