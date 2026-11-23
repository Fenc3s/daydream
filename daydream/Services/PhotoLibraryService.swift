import AppKit
import Foundation
import Photos
import UniformTypeIdentifiers

@MainActor
final class PhotoLibraryService: NSObject {
    static let shared = PhotoLibraryService()

    private var logger: AppLogger?

    func configure(logger: AppLogger) {
        self.logger = logger
    }

    func saveImageFromClipboard() {
        guard let payload = imagePayload(from: .general) else {
            presentAlert(
                title: "No Image to Save",
                message: "Copy an image first, then choose Save Clipboard Image to Photos."
            )
            return
        }

        save(payload, source: "clipboard")
    }

    func saveImage(from urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw PhotoLibraryServiceError.invalidImageURL
        }

        let payload: ImagePayload
        if url.scheme == "data" {
            payload = try imagePayload(fromDataURL: urlString)
        } else {
            guard url.scheme == "https" || url.scheme == "http" else {
                throw PhotoLibraryServiceError.unsupportedImageURL
            }

            let (data, response) = try await URLSession.shared.data(from: url)
            guard data.count <= ImagePayload.maximumDataSize else {
                throw PhotoLibraryServiceError.imageTooLarge
            }

            let contentType = response.mimeType.flatMap { UTType(mimeType: $0) }
                ?? UTType(filenameExtension: url.pathExtension)
                ?? .image
            guard contentType.conforms(to: .image), !data.isEmpty else {
                throw PhotoLibraryServiceError.invalidImageData
            }

            payload = ImagePayload(
                data: data,
                contentType: contentType,
                originalFilename: url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
            )
        }

        try await saveToPhotoLibrary(payload)
    }

    private func save(_ payload: ImagePayload, source: String) {
        Task { [weak self] in
            guard let self else { return }

            do {
                try await saveToPhotoLibrary(payload)
                await logger?.log(
                    "photos",
                    "Saved image to Photos",
                    metadata: [
                        "source": source,
                        "content_type": payload.contentType.identifier,
                        "bytes": "\(payload.data.count)",
                    ]
                )
            } catch {
                await logger?.log(
                    "photos",
                    "Failed to save image to Photos",
                    metadata: [
                        "source": source,
                        "error": error.localizedDescription,
                    ]
                )
                presentAlert(title: "Could Not Save Image to Photos", message: error.localizedDescription)
            }
        }
    }

    private func saveToPhotoLibrary(_ payload: ImagePayload) async throws {
        let accessLevel: PHAccessLevel = .addOnly
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: accessLevel)
        let status = currentStatus == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: accessLevel)
            : currentStatus

        guard status == .authorized || status == .limited else {
            throw PhotoLibraryServiceError.accessDenied(status)
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.contentType = payload.contentType
            options.originalFilename = payload.originalFilename ?? "Dia Image.\(payload.fileExtension)"
            request.addResource(with: .photo, data: payload.data, options: options)
        }
    }

    private func imagePayload(from pasteboard: NSPasteboard) -> ImagePayload? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let contentType = UTType(type.rawValue), contentType.conforms(to: .image),
                      let data = item.data(forType: type), !data.isEmpty else {
                    continue
                }

                return ImagePayload(data: data, contentType: contentType, originalFilename: nil)
            }
        }

        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        for fileURL in fileURLs where fileURL.isFileURL {
            let contentType = UTType(filenameExtension: fileURL.pathExtension) ?? .image
            guard contentType.conforms(to: .image), let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                continue
            }

            return ImagePayload(data: data, contentType: contentType, originalFilename: fileURL.lastPathComponent)
        }

        return nil
    }

    private func imagePayload(fromDataURL dataURL: String) throws -> ImagePayload {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            throw PhotoLibraryServiceError.invalidImageData
        }

        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<commaIndex])
        let encodedData = String(dataURL[dataURL.index(after: commaIndex)...])
        let mediaType = metadata.split(separator: ";").first.map(String.init) ?? ""
        let contentType = UTType(mimeType: mediaType) ?? .image
        let data = metadata.contains(";base64")
            ? Data(base64Encoded: encodedData)
            : encodedData.removingPercentEncoding?.data(using: .utf8)

        guard contentType.conforms(to: .image), let data, !data.isEmpty else {
            throw PhotoLibraryServiceError.invalidImageData
        }
        guard data.count <= ImagePayload.maximumDataSize else {
            throw PhotoLibraryServiceError.imageTooLarge
        }

        return ImagePayload(data: data, contentType: contentType, originalFilename: nil)
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct ImagePayload: Sendable {
    static let maximumDataSize = 50 * 1024 * 1024

    let data: Data
    let contentType: UTType
    let originalFilename: String?

    var fileExtension: String {
        contentType.preferredFilenameExtension ?? "jpg"
    }
}

private enum PhotoLibraryServiceError: LocalizedError {
    case accessDenied(PHAuthorizationStatus)
    case imageTooLarge
    case invalidImageData
    case invalidImageURL
    case unsupportedImageURL

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Allow Daydream to add items to Photos in System Settings > Privacy & Security > Photos, then try again."
        case .imageTooLarge:
            "The selected image is larger than Daydream's 50 MB limit."
        case .invalidImageData:
            "The selected URL did not return valid image data."
        case .invalidImageURL:
            "Dia supplied an invalid image URL."
        case .unsupportedImageURL:
            "This image uses a browser-only URL that Daydream cannot download. Copy the image and use Save Clipboard Image to Photos instead."
        }
    }
}
