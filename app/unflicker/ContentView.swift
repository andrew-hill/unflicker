import SwiftUI
import AppCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    /// Text outside the form lines up with the text inside a row, not with the
    /// edge of the boxes: 20 to the box edge, then the row's own inset.
    private let textInset: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Outside the Form: inside it, grouped style boxes it up as a
            // section of its own. Sized to stay on one line at 380 wide.
            Text("Set it once. unflicker reapplies it on every reconnect.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, textInset)
                .zIndex(1)

            Form {
                HStack {
                    Picker("Anti-flicker", selection: Binding(
                        get: { model.choice },
                        set: { model.choose($0) }
                    )) {
                        Text("50 Hz").tag(PowerLineChoice.hz50)
                        Text("60 Hz").tag(PowerLineChoice.hz60)
                    }
                    HelpButton {
                        Text("50 Hz across the UK, Europe, Africa, most of Asia, "
                             + "Australia and most of South America. 60 Hz in North "
                             + "America and Japan.\n\nCameras ship set to 60 Hz, so "
                             + "on a 50 Hz supply they band out of the box. If you "
                             + "are unsure, try both: the wrong one bands under "
                             + "mains-powered lighting.")
                    }
                }

                HStack {
                    Toggle("Reapply when a camera is plugged in", isOn: Binding(
                        get: { model.reapplyOnAttach },
                        set: { model.setReapply($0) }
                    ))
                    HelpButton {
                        Text("Cameras forget the setting whenever they reconnect, "
                             + "which includes a monitor with a built-in camera "
                             + "power-cycling.\n\nWith this on, macOS runs unflicker "
                             + "for a moment whenever a camera attaches, and again at "
                             + "login. It sets the value and quits: nothing stays "
                             + "running, and you need not open this window again.")
                    }
                }
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
            // Grouped forms scroll. The window sizes to its content, so the
            // content must report a real height rather than a scrollable one.
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            // Grouped style pads for a full-window form; this is a small panel.
            // The text above carries a zIndex to survive the negative top inset,
            // which otherwise paints the form's backdrop over it.
            .padding(.vertical, -10)

            // Only USB cameras are enumerated, so this sets expectations rather
            // than annotating a camera that cannot appear in the list.
            HStack(spacing: 4) {
                Text("Where's my built-in camera?")
                    .font(.callout).foregroundStyle(.secondary)
                HelpButton {
                    Text("Apple silicon built-in cameras are not USB. They hang off the "
                         + "image signal processor and expose no anti-flicker control, so "
                         + "nothing can change them: not unflicker, not any similar tool.")
                }
            }
            .padding(.horizontal, textInset)
        }
        .frame(width: 380)
        .padding(.bottom, 14)
        .background(FixedSizeWindow())
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

private struct HelpButton<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .popover(isPresented: $showing) {
                content
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260)
                    .padding()
            }
    }
}

/// Fixed size, and close is the only title-bar button: this window is setup,
/// not something to keep open. `.windowResizability(.contentSize)` pins the
/// size but leaves `.resizable` in the style mask, which tiling window
/// managers (Amethyst, AeroSpace, yabai) resize on.
private struct FixedSizeWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.styleMask.subtract([.resizable, .miniaturizable])
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
