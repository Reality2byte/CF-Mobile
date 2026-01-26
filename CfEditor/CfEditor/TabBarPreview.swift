import SwiftUI

#Preview("System Tab Bar") {
    TabView {
        Text("Practice")
            .tabItem { Label("Practice", systemImage: "list.bullet") }
        Text("Editor")
            .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
        Text("OI Wiki")
            .tabItem { Label("OI Wiki", systemImage: "book.closed") }
        Text("Me")
            .tabItem { Label("Me", systemImage: "person.crop.circle") }
    }
}
