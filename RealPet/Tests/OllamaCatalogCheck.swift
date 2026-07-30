import Foundation

@main
struct OllamaCatalogCheck {
    static func main() async throws {
        let catalog = try OllamaModelCatalog()
        let models = try await catalog.visionModels()
        if models.isEmpty {
            print("Ollama is reachable; no installed vision model")
        } else {
            for model in models {
                print("\(model.name)\t\(model.parameterSize ?? "?")\t\(model.size)")
            }
        }
    }
}
