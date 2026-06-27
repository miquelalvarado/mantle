import SwiftUI

@MainActor final class SettingsStore: ObservableObject {
    @AppStorage("awsRegion")      var region:       String = "us-east-1"
    @AppStorage("awsProfile")     var profile:      String = "default"
    @AppStorage("localPort")      var port:         Int    = 8080
    @AppStorage("defaultModelId") var defaultModel: String = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}
