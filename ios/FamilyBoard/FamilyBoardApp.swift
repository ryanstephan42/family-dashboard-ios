import SwiftUI

@main
struct FamilyBoardApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(session)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        if session.serverURL == nil {
            ServerSetupView()
        } else if !session.isLoggedIn {
            LoginView()
        } else {
            TabView {
                TaskListView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
    }
}
