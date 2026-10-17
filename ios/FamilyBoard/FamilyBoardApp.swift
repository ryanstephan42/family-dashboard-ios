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
        content
            .alert("Sign-in notice", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if session.serverURL == nil {
            ServerSetupView()
        } else if !session.isLoggedIn {
            LoginView()
        } else {
            MainTabView()
        }
    }
}

private enum AppTab: Hashable {
    case tasks
    case settings
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .tasks

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(AppTab.tasks)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppTab.settings)
        }
    }
}
