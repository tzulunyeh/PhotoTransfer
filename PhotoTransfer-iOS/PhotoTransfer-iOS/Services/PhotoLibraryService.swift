import Foundation
import Photos

final class PhotoLibraryService {
    enum AuthError: Error {
        case denied
        case restricted
    }

    // Request photo library access. Throws if denied.
    func requestAuthorization() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited: return
        case .denied: throw AuthError.denied
        case .restricted: throw AuthError.restricted
        default: throw AuthError.denied
        }
    }

    // Fetch all photo/video assets sorted by creation date descending.
    func fetchAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // Stream raw file data for an asset chunk by chunk.
    // Each chunk is delivered to handler; completion is called when done.
    func streamAssetData(
        for asset: PHAsset,
        handler: @escaping (Data) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto }) else {
            completion(NSError(domain: "PhotoLibraryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No resource found"]))
            return
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false  // USB only, no iCloud download

        PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in handler(data) },
            completionHandler: { error in completion(error) }
        )
    }

    // Get the original filename and file size for an asset.
    func info(for asset: PHAsset) -> (filename: String, fileSize: Int64) {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto }) else {
            return ("unknown_\(asset.localIdentifier).bin", 0)
        }
        let filename = resource.originalFilename
        let fileSize = (resource.value(forKey: "fileSize") as? Int64) ?? 0
        return (filename, fileSize)
    }
}
