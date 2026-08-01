import QuickLookThumbnailing
import AppKit

final class MilkThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let iconURL = Bundle(for: MilkThumbnailProvider.self).url(forResource: "MilkDocumentIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            handler(nil, nil)
            return
        }

        let reply = QLThumbnailReply(contextSize: request.maximumSize) { context in
            let rect = NSRect(origin: .zero, size: request.maximumSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            icon.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        handler(reply, nil)
    }
}
