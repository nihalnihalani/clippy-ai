import SwiftUI
import SwiftData
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
            // If migration fails, print error and attempt fresh start
            print("❌ ModelContainer creation failed: \(error)")
            print("🔄 This might be due to schema changes. Try cleaning build or deleting app data.")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @StateObject private var container = AppDependencyContainer()



    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container)
                .onAppear {
                    // We need to inject the modelContext once the container and context are ready
                    // However, we can't easily access modelContext here outside of a View context usually.
                    // But sharedModelContainer.mainContext is available!
                    container.inject(modelContext: sharedModelContainer.mainContext)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
