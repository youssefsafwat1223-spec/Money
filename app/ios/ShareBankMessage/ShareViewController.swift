import Social
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
  override func isContentValid() -> Bool {
    true
  }

  override func didSelectPost() {
    extractSharedText { text in
      if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        SharedCaptureStore.enqueue(text: text, sender: nil, source: "share")
      }
      self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
  }

  override func configurationItems() -> [Any]! {
    []
  }

  private func extractSharedText(completion: @escaping (String?) -> Void) {
    guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
          let attachments = item.attachments else {
      completion(contentText)
      return
    }

    let textType = UTType.plainText.identifier
    for provider in attachments where provider.hasItemConformingToTypeIdentifier(textType) {
      provider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
        let text = item as? String ?? self.contentText
        completion(text)
      }
      return
    }

    completion(contentText)
  }
}
