import SwiftUI

@main
struct CameraMindApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
        }
    }
}
