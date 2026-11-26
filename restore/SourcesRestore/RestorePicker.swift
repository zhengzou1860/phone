import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct RestorePicker: UIViewControllerRepresentable {
    let kind: MediaKind
    let onPicked: (URL?) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.filter = kind == .image ? .images : .videos
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: kind, onPicked: onPicked, onFailure: onFailure)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let kind: MediaKind
        let onPicked: (URL?) -> Void
        let onFailure: (String) -> Void

        init(kind: MediaKind, onPicked: @escaping (URL?) -> Void, onFailure: @escaping (String) -> Void) {
            self.kind = kind
            self.onPicked = onPicked
            self.onFailure = onFailure
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                dispatch(nil, nil)
                return
            }
            let type = UTType(kind == .image ? .jpeg : .movie)
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    self.dispatch(url, error?.localizedDescription)
                }
                return
            }
            let fallback = UTType(kind == .image ? .image : .movie)
            provider.loadFileRepresentation(forTypeIdentifier: fallback.identifier) { url, error in
                self.dispatch(url, error?.localizedDescription)
            }
        }

        private func dispatch(_ url: URL?, _ error: String?) {
            guard let url else {
                deliver(nil, error)
                return
            }
            let extensionName = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("hirestore_pick_\(UUID().uuidString).\(extensionName)")
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                deliver(destination, nil)
            } catch {
                deliver(nil, "复制所选文件失败：\(error.localizedDescription)")
            }
        }

        private func deliver(_ url: URL?, _ error: String?) {
            Task { @MainActor in
                if let url = url {
                    onPicked(url)
                } else if let error {
                    onFailure(error)
                } else {
                    onPicked(nil)
                }
            }
        }
    }
}
