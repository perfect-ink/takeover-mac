import SwiftUI

/// One binary, two roles: the app, or (when launchd passes
/// `--defaults-agent`) the background agent that keeps chosen Mac defaults
/// applied. See DefaultsAgent.
@main
enum TakeoverMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains(DefaultsAgent.launchArgument) {
            DefaultsAgent.run()
        } else {
            TakeoverApp.main()
        }
    }
}
