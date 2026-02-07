import SwiftUI
import SwiftData
import os
@main
struct ClippyApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Migration failed — attempt a fresh start by destroying the old store
            Logger.services.error("ModelContainer creation failed: \(error.localizedDescription, privacy: .public)")
            Logger.services.info("Attempting fresh ModelContainer (data will be reset)")

            // Delete the existing store file so we can start clean
            let storeURL = modelConfiguration.url
            let related = [
                storeURL,
                storeURL.appendingPathExtension("wal"),
                storeURL.appendingPathExtension("shm")
            ]
            for url in related {
                try? FileManager.default.removeItem(at: url)
            }

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                // Last resort: use an in-memory store so the app at least launches
                Logger.services.error("Fresh ModelContainer also failed: \(error.localizedDescription, privacy: .public). Falling back to in-memory store.")
                let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                do {
                    return try ModelContainer(for: schema, configurations: [inMemoryConfig])
                } catch {
                    fatalError("Could not create even an in-memory ModelContainer: \(error)")
                }
            }
        }
    }()

    @StateObject private var container = AppDependencyContainer()



    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container)
                .fontDesign(.rounded)
                .preferredColorScheme(.dark)
                .onAppear {
                    container.inject(modelContext: sharedModelContainer.mainContext)
                }
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra("Clippy", systemImage: "paperclip") {
            StatusBarMenu()
                .environmentObject(container)
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)
    }
}
