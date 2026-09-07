import SwiftUI
import AppCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Anti-flicker", selection: Binding(
                get: { model.choice },
                set: { if let choice = $0 { model.choose(choice) } }
            )) {
                if model.choice == nil {
                    Text("Not set").tag(PowerLineChoice?.none)
                }
                Text("50 Hz").tag(PowerLineChoice?.some(.hz50))
                Text("60 Hz").tag(PowerLineChoice?.some(.hz60))
            }

            Toggle("Reapply when a camera is plugged in", isOn: Binding(
                get: { model.reapplyOnAttach },
                set: { model.setReapply($0) }
            ))
            if let obstacle = model.obstacle {
                Text(obstacle).font(.callout).foregroundStyle(.secondary)
            }

            Section("Cameras") {
                if model.cameras.isEmpty {
                    Text("No USB cameras attached").foregroundStyle(.secondary)
                }
                ForEach(model.cameras) { camera in
                    LabeledContent(camera.name, value: camera.detail)
                }
            }

            // By position: two identical cameras failing identically produce
            // the same string twice, and duplicate ForEach ids drop a row.
            ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
