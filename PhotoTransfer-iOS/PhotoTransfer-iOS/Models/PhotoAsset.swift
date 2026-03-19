import Photos
import UIKit

struct PhotoAsset: Identifiable {
    let id: String           // PHAsset.localIdentifier
    let asset: PHAsset
    let filename: String
    let fileSize: Int64
    var isSelected: Bool = false
    var thumbnail: UIImage? = nil
}
