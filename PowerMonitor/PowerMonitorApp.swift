import SwiftUI

// SwiftUI entry point. The actual lifecycle is AppKit-driven because the app is centered
// around a status item, popovers, and floating utility panels.
@main
struct PowerMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate
    
    var body: some Scene {
    }
}
