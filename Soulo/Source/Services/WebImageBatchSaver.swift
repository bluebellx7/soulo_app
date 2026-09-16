import Combine
import Foundation

/// Serial imports keep full-resolution images on disk instead of retaining a batch in memory.
@MainActor
final class WebImageBatchSaver: ObservableObject {
    struct Result {
        var savedIDs = Set<String>()
        var failedIDs = Set<String>()
        var wasCancelled = false
        var permissionDenied = false
    }

    @Published private(set) var isSaving = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    private var task: Task<Void, Never>?

    func start(
        images: [WebImageResource],
        save: @escaping @MainActor (WebImageResource) async throws -> Void,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        guard !isSaving else { return }
        var seen = Set<String>()
        let images = images.filter { seen.insert($0.id).inserted }
        guard !images.isEmpty else { return }
        completed = 0
        total = images.count
        isSaving = true
        task = Task { [weak self] in
            guard let self else { return }
            var result = Result()
            for image in images {
                if Task.isCancelled { result.wasCancelled = true; break }
                do {
                    try await save(image)
                    result.savedIDs.insert(image.id)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        result.wasCancelled = true
                        break
                    }
                    result.failedIDs.insert(image.id)
                    if let error = error as? WebResourceDownloadError, case .photoAccessDenied = error {
                        result.permissionDenied = true
                    }
                }
                self.completed += 1
                if result.permissionDenied { break }
            }
            self.isSaving = false
            self.task = nil
            completion(result)
        }
    }

    func cancel() { task?.cancel() }
}
