import SwiftUI
import AppCore
import IOUSBLibTransport

@main
struct UnflickerApp: App {
    // nil only if the group suite name itself will not open, which no
    // fallback here could repair.
    @StateObject private var model = AppModel(transport: IOUSBLibTransport(),
                                              settings: GroupSettings.standard()!,
                                              registrar: ServiceRegistrar())

    var body: some Scene {
        Window("unflicker", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
