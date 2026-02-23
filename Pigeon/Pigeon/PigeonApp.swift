import SwiftData
import SwiftUI

@main
struct PigeonApp: App {
    @State private var coordinator: AppCoordinator

    init() {
        do {
            let store = try PigeonStore()
            let coord = try AppCoordinator(store: store)
            _coordinator = State(initialValue: coord)
        } catch {
            fatalError("Failed to initialize Pigeon: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(coordinator)
                .modelContainer(coordinator.store.modelContainer)
                .task {
                    await coordinator.start()
                }
        }
    }
}
