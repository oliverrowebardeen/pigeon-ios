import SwiftData
import SwiftUI

@main
struct PigeonApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: AppCoordinator

    init() {
        do {
            let store = try PigeonStore()
            let coord = try AppCoordinator(store: store)
            coord.bootstrap()
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
                .onChange(of: scenePhase) {
                    switch scenePhase {
                    case .active:
                        coordinator.applicationDidBecomeActive()
                    case .background:
                        coordinator.applicationDidEnterBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
