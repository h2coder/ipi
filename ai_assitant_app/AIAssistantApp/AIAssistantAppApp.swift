import SwiftUI
import IPI

@main
struct AIAssistantAppApp: App {
    @State private var session = ChatSession()

    var body: some Scene {
        WindowGroup {
            ChatScreen(session: self.session)
        }
    }
}
