import Intents
import UIKit
import UserNotifications

/// Turns the relay's plain push into a communication notification: the Reason's own avatar and name,
/// grouped per conversation, like a message from a person.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        original = request.content
        let content = request.content
        let info = content.userInfo
        let reason = info["reason"] as? [String: Any]
        let reasonId = reason?["id"] as? String ?? info["reason_id"] as? String
        let sessionId = info["session_id"] as? String
        let name = (reason?["name"] as? String) ?? (content.title.isEmpty ? "Reason" : content.title)
        let appearance = Appearance(color: reason?["color"] as? String ?? "blue", eyes: reason?["eyes"] as? String ?? "pills", shape: nil)

        let photo = AvatarView.snapshot(appearance)
        let handle = reasonId ?? sessionId ?? "reason"
        let sender = INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil,
                              displayName: name, image: photo.pngData().map { INImage(imageData: $0) },
                              contactIdentifier: nil, customIdentifier: handle)
        // A child's question keeps its Session's name as the first line.
        var body = content.body
        if !content.subtitle.isEmpty { body = "\(content.subtitle): \(body)" }
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: body,
                                         speakableGroupName: nil, conversationIdentifier: content.threadIdentifier.isEmpty ? handle : content.threadIdentifier,
                                         serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(sender.image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { [weak self] _ in
            guard let self else { return }
            let updated = (try? content.updating(from: intent)) ?? content
            self.finish(updated)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let original { finish(original) }
    }

    private func finish(_ c: UNNotificationContent) {
        handler?(c)
        handler = nil
    }
}
