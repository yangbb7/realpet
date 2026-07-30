import Foundation

@MainActor
protocol InteractionAdapter: AnyObject {
    var onObservation: ((InteractionObservation) -> Void)? { get set }

    func start() throws
    func stop()
}

@MainActor
final class InteractionAdapterBus {
    private let hub: InteractionHub
    private var boundAdapters: Set<ObjectIdentifier> = []

    init(hub: InteractionHub) {
        self.hub = hub
    }

    func bind(_ adapter: InteractionAdapter) {
        let id = ObjectIdentifier(adapter)
        guard boundAdapters.insert(id).inserted else { return }
        adapter.onObservation = { [weak hub] observation in
            hub?.publish(observation)
        }
    }

    func unbind(_ adapter: InteractionAdapter) {
        boundAdapters.remove(ObjectIdentifier(adapter))
        adapter.onObservation = nil
    }
}
