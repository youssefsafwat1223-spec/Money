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

    // COUPONS Phase 5 — route by ITEM TYPE, URLs first.
    //
    // A shared merchant link must never reach the capture queue: the SMS parser
    // would read a product page as a transaction, and the URL would be
    // persisted in the store built for bank messages. URL items therefore go to
    // a SEPARATE App Group store and this method reports nothing to capture.
    //
    // URLs are checked BEFORE text because Safari offers a page as both — it
    // attaches the title as plain text alongside the public.url item — and
    // taking the text branch would put the page title into the parser.
    let urlType = UTType.url.identifier
    for provider in attachments where provider.hasItemConformingToTypeIdentifier(urlType) {
      provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, _ in
        if let url = item as? URL {
          // Sanitized inside the store: scheme, host and path only. A shared
          // shopping URL routinely carries a session id, a cart id and the
          // sharer's own referral code, none of which is needed to know which
          // merchant this is.
          SharedOfferIntentStore.enqueue(url: url)
        }
        // Nothing goes to the capture path for a URL share.
        completion(nil)
      }
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
