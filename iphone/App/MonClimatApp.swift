import SwiftUI

@main
struct MonClimatApp: App {
    @State private var store = ClimateStore()
    var body: some Scene {
        WindowGroup { ClimateView(store: store).tint(ClimateTheme.blue).preferredColorScheme(.light) }
    }
}
