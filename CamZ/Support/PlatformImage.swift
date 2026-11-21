import Foundation

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Makes the small preview shown on the shutter button. The photo is decoded off the main actor.
enum Thumbnail {
    nonisolated static func make(from data: Data, shortSide: CGFloat) async -> PlatformImage? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = shortSide / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return await image.byPreparingThumbnail(ofSize: size)
        #else
        return NSImage(data: data)
        #endif
    }
}
