import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct AutomaticConversationDestination: View {
        let owner: AutomaticChatAccountOwner
        let groupIdHex: String
        @State private var model: AccountConversationViewModel?

        var body: some View {
            AutomaticConversationView(model: model)
                .task(id: groupIdHex) {
                    model = owner.selectConversation(groupIdHex: groupIdHex)
                }
                .onDisappear {
                    if let model { owner.releaseConversation(model) }
                }
        }
    }

    #Preview {
        AutomaticConversationView(model: nil)
    }
#endif
