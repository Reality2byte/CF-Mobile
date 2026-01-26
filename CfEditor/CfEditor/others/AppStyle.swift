import SwiftUI
import UIKit

enum AppStyle {
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemGroupedBackground)
}

extension View {
    func appPageBackground() -> some View {
        background(AppStyle.groupedBackground)
    }

    func appListStyle() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppStyle.groupedBackground)
    }

    func appFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(AppStyle.groupedBackground)
    }
}
