import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: GroupStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Dashboard", systemImage: "waveform.path.ecg")
                }
                .tag(0)

            ConfigureView()
                .tabItem {
                    Label("Configure", systemImage: "slider.horizontal.3")
                }
                .tag(1)
        }
        .tint(Color("AccentColor"))
    }
}
