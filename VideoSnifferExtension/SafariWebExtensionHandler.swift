import SafariServices

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]

        let response: [String: Any] = [
            "type": "appInfo",
            "scheme": "videosniffer",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "received": message["type"] as? String ?? ""
        ]

        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [reply])
    }
}
