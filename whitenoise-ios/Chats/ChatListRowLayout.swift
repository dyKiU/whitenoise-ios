import SwiftUI

enum ChatListRowMetrics {
    static let insets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
}

/// Shared geometry for native and linked-device conversation rows.
struct ChatListRowLayout<Avatar: View, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let avatar: Avatar
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            avatar.frame(width: 56, height: 56)
            content
        }
        .padding(.vertical, 2)
    }
}
