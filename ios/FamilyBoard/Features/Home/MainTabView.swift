import SwiftUI

private enum AppTab: Hashable {
    case tasks, groceries, inventory, meals, more
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .tasks
    @State private var inventoryRevision = UUID()

    var body: some View {
        TabView(selection: $selectedTab) {
            TaskListView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(AppTab.tasks)
            GroceryListView()
                .tabItem { Label("Groceries", systemImage: "cart") }
                .tag(AppTab.groceries)
            NavigationStack {
                InventoryListView()
                    .id(inventoryRevision)
            }
            .tabItem { Label("Inventory", systemImage: "shippingbox") }
            .tag(AppTab.inventory)
            MealsListView()
                .id(inventoryRevision)
                .tabItem { Label("Meals", systemImage: "fork.knife") }
                .tag(AppTab.meals)
            MoreView {
                inventoryRevision = UUID()
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .tag(AppTab.more)
        }
    }
}

private enum MoreDestination: String, Identifiable {
    case calendar, receipt, settings
    var id: String { rawValue }
}

private struct MoreView: View {
    @EnvironmentObject private var session: Session
    @State private var destination: MoreDestination?
    let onInventoryImported: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    destination = .calendar
                } label: {
                    Label("Family Calendar", systemImage: "calendar")
                }
                Button {
                    destination = .receipt
                } label: {
                    Label("Scan Receipt", systemImage: "receipt")
                }
                .disabled(session.client == nil)
                Button {
                    destination = .settings
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            .navigationTitle("More")
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .calendar:
                SharedCalendarView()
                    .safeAreaInset(edge: .bottom) { closeButton }
            case .settings:
                SettingsView()
                    .safeAreaInset(edge: .bottom) { closeButton }
            case .receipt:
                if let client = session.client {
                    NavigationStack {
                        ReceiptScanView(client: client, onImported: onInventoryImported)
                    }
                }
            }
        }
    }

    private var closeButton: some View {
        Button("Close") { destination = nil }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
    }
}
