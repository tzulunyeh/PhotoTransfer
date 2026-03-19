import SwiftUI
import PhotosUI

// UIViewControllerRepresentable wrapper around PHPickerViewController.
// Returns [PHPickerResult] which contain assetIdentifier for PHAsset lookup.
struct PhotoPickerView: UIViewControllerRepresentable {
    let onSelected: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0          // 0 = unlimited
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current  // preserve original format
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSelected: onSelected) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelected: ([PHPickerResult]) -> Void

        init(onSelected: @escaping ([PHPickerResult]) -> Void) {
            self.onSelected = onSelected
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onSelected(results)
        }
    }
}
