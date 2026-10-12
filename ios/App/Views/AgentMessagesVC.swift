import UIKit
import CometChatUIKitSwift
import CometChatSDK

/// The agent thread, UIKit side: header + message list with the full fetch
/// contract (text, media, forms, interactive cards).  No kit composer — the
/// native SwiftUI input bar owns the send path so prompts travel to the Mac
/// sidecar (`POST /clutch/v1/chat`) instead of CometChat's cloud send.
final class AgentMessagesVC: UIViewController {
    private let agent: CometChatSDK.User

    init(agent: CometChatSDK.User) {
        self.agent = agent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private lazy var headerView: CometChatMessageHeader = {
        let header = CometChatMessageHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 50).isActive = true
        header.set(user: agent)
        header.set(controller: self)
        return header
    }()

    private lazy var messageListView: CometChatMessageList = {
        let list = CometChatMessageList(frame: .null)
        list.translatesAutoresizingMaskIntoConstraints = false
        let builder = MessagesRequest.MessageRequestBuilder()
            .set(uid: agent.uid ?? "")
            .hideReplies(hide: true)
            .set(types: [
                MessageTypeConstants.text,
                MessageTypeConstants.image,
                MessageTypeConstants.video,
                MessageTypeConstants.audio,
                MessageTypeConstants.file,
                MessageTypeConstants.groupMember,
                MessageTypeConstants.form,
                MessageTypeConstants.scheduler,
            ])
            // Interactive + card categories must be listed or the fetch
            // silently drops relayed tool-call cards.
            .set(categories: [
                MessageCategoryConstants.message,
                MessageCategoryConstants.action,
                MessageCategoryConstants.custom,
                MessageCategoryConstants.interactive,
                MessageCategoryConstants.card,
            ])
        list.set(user: agent, parentMessage: nil, withParent: false)
        list.set(messagesRequestBuilder: builder)
        list.set(controller: self)
        return list
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CometChatTheme.backgroundColor01
        view.addSubview(headerView)
        view.addSubview(messageListView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageListView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            messageListView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageListView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageListView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
