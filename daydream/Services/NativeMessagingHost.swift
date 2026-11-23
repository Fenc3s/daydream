import Foundation
import UniformTypeIdentifiers

enum NativeMessagingHost {
    private static let maximumMessageSize = 1 * 1024 * 1024

    static func run(photoLibraryService: PhotoLibraryService, logger: AppLogger) async {
        let response: NativeMessageResponse

        do {
            let request = try readRequest()
            guard request.action == "saveImageToPhotos" else {
                throw NativeMessagingError.unsupportedAction
            }

            try await photoLibraryService.saveImage(from: request.url)
            await logger.log("photos", "Saved browser context-menu image to Photos", metadata: ["source": "browser_extension"])
            response = NativeMessageResponse(ok: true, error: nil)
        } catch {
            await logger.log(
                "photos",
                "Failed to save browser context-menu image",
                metadata: ["error": error.localizedDescription]
            )
            response = NativeMessageResponse(ok: false, error: error.localizedDescription)
            await MainActor.run {
                DiaImageExtensionService.shared.presentAlert(
                    title: "Could Not Save Image to Photos",
                    message: error.localizedDescription
                )
            }
        }

        try? writeResponse(response)
    }

    private static func readRequest() throws -> NativeMessageRequest {
        let input = FileHandle.standardInput
        let lengthData = input.readData(ofLength: MemoryLayout<UInt32>.size)
        guard lengthData.count == MemoryLayout<UInt32>.size else {
            throw NativeMessagingError.invalidMessage
        }

        let messageLength = Int(lengthData.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        })
        guard messageLength > 0, messageLength <= maximumMessageSize else {
            throw NativeMessagingError.invalidMessage
        }

        let messageData = input.readData(ofLength: messageLength)
        guard messageData.count == messageLength else {
            throw NativeMessagingError.invalidMessage
        }

        return try JSONDecoder().decode(NativeMessageRequest.self, from: messageData)
    }

    private static func writeResponse(_ response: NativeMessageResponse) throws {
        let data = try JSONEncoder().encode(response)
        var length = UInt32(data.count).littleEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)

        let output = FileHandle.standardOutput
        try output.write(contentsOf: lengthData)
        try output.write(contentsOf: data)
    }
}

private struct NativeMessageRequest: Decodable {
    let action: String
    let url: String
}

private struct NativeMessageResponse: Encodable {
    let ok: Bool
    let error: String?
}

private enum NativeMessagingError: LocalizedError {
    case invalidMessage
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            "Daydream received an invalid message from the browser extension."
        case .unsupportedAction:
            "The browser extension requested an unsupported Daydream action."
        }
    }
}
