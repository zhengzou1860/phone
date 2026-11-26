import SwiftUI

@main
struct HiRestoreApp: App {
    @StateObject private var store: RestoreStore
    @StateObject private var processor: RestoreProcessor

    init() {
        let store = RestoreStore()
        _store = StateObject(wrappedValue: store)
        _processor = StateObject(wrappedValue: RestoreProcessor(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RestoreRootView()
                .environmentObject(store)
                .environmentObject(processor)
                .preferredColorScheme(.dark)
        }
    }
}
