import Foundation

@MainActor
final class BehaviorPlanningCoordinator {
    var onActivityChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let model: any BehaviorPlanningModel
    private let now: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var activeRequestId: UUID?

    init(
        model: any BehaviorPlanningModel,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.model = model
        self.now = now
    }

    @discardableResult
    func submit(
        _ request: BehaviorPlanningRequest,
        completion: @escaping (Result<BehaviorPlanningResult, Error>) -> Void
    ) -> Bool {
        guard task == nil, request.isFresh(at: now()) else { return false }
        let requestId = request.id
        activeRequestId = requestId
        onActivityChange?(true)
        let model = self.model
        task = Task { [weak self] in
            let result: Result<BehaviorPlanningResult, Error>
            do {
                let plan = try await Self.perform(model: model, request: request)
                result = plan.isValid
                    ? .success(plan)
                    : .failure(BehaviorPlanningCoordinatorError.invalidResult)
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self,
                  self.activeRequestId == requestId else { return }
            self.task = nil
            self.activeRequestId = nil
            self.onActivityChange?(false)

            guard request.isFresh(at: self.now()) else {
                completion(.failure(BehaviorPlanningCoordinatorError.expired))
                return
            }
            if case .failure(let error) = result,
               !(error is CancellationError),
               (error as? BehaviorPlanningCoordinatorError) != .expired {
                self.onError?(error.localizedDescription)
            }
            completion(result)
        }
        return true
    }

    func cancelCurrent() {
        guard task != nil else { return }
        activeRequestId = nil
        task?.cancel()
        task = nil
        onActivityChange?(false)
    }

    nonisolated private static func perform(
        model: any BehaviorPlanningModel,
        request: BehaviorPlanningRequest
    ) async throws -> BehaviorPlanningResult {
        let timeout = max(0.1, request.expiresAt - request.issuedAt)
        return try await withThrowingTaskGroup(
            of: BehaviorPlanningResult.self
        ) { group in
            group.addTask { try await model.plan(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw BehaviorPlanningCoordinatorError.expired
            }
            guard let first = try await group.next() else {
                throw BehaviorPlanningCoordinatorError.expired
            }
            group.cancelAll()
            return first
        }
    }
}
