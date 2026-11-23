import Foundation

@MainActor
final class ICloudSyncService: NSObject {
    private struct FileVersion: Equatable {
        var exists: Bool
        var fileSize: Int?
        var modificationDate: Date?
    }

    private let fileManager: FileManager
    private let localDirectory: URL
    private let query = NSMetadataQuery()
    private var observerTokens: [NSObjectProtocol] = []
    private var changeHandler: ((Set<ICloudSyncFile>) -> Void)?
    private var pendingChangedFiles = Set<ICloudSyncFile>()
    private var deliveredFileVersions: [ICloudSyncFile: FileVersion] = [:]
    private var pendingDeliveryTask: Task<Void, Never>?

    private(set) var iCloudDirectory: URL?

    var isAvailable: Bool {
        iCloudDirectory != nil
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        localDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
        super.init()
        iCloudDirectory = Self.resolveICloudDirectory(fileManager: fileManager)
    }

    deinit {
        pendingDeliveryTask?.cancel()
        query.stop()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refreshAvailability() {
        iCloudDirectory = Self.resolveICloudDirectory(fileManager: fileManager)
    }

    func localURL(for file: ICloudSyncFile) -> URL {
        localDirectory.appendingPathComponent(file.fileName, isDirectory: false)
    }

    func syncedURL(for file: ICloudSyncFile) -> URL? {
        guard let iCloudDirectory else { return nil }
        return iCloudDirectory.appendingPathComponent(file.fileName, isDirectory: false)
    }

    func migrateLocalFilesIfNeeded() {
        guard let iCloudDirectory else { return }
        try? fileManager.createDirectory(at: iCloudDirectory, withIntermediateDirectories: true)

        for file in ICloudSyncFile.allCases {
            let localURL = localURL(for: file)
            let syncedURL = iCloudDirectory.appendingPathComponent(file.fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: localURL.path),
                  !fileManager.fileExists(atPath: syncedURL.path) else {
                continue
            }
            try? fileManager.copyItem(at: localURL, to: syncedURL)
        }
    }

    func startObserving(changeHandler: @escaping (Set<ICloudSyncFile>) -> Void) {
        self.changeHandler = changeHandler
        guard let iCloudDirectory else { return }
        for file in ICloudSyncFile.allCases {
            deliveredFileVersions[file] = fileVersion(for: file)
        }
        guard observerTokens.isEmpty else {
            query.start()
            return
        }

        query.searchScopes = [iCloudDirectory]
        let filePredicates = ICloudSyncFile.allCases.map { file in
            NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, file.fileName)
        }
        // NSMetadataQuery rejects an OR predicate containing only one condition.
        query.predicate = filePredicates.count == 1
            ? filePredicates[0]
            : NSCompoundPredicate(orPredicateWithSubpredicates: filePredicates)

        let notificationCenter = NotificationCenter.default
        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ] {
            let token = notificationCenter.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handleQueryUpdate(notification)
                }
            }
            observerTokens.append(token)
        }

        query.start()
    }

    func stopObserving() {
        pendingDeliveryTask?.cancel()
        pendingDeliveryTask = nil
        pendingChangedFiles.removeAll()
        query.stop()
    }

    private func handleQueryUpdate(_ notification: Notification) {
        let changedFiles: Set<ICloudSyncFile>
        if notification.name == NSNotification.Name.NSMetadataQueryDidFinishGathering {
            query.disableUpdates()
            changedFiles = files(in: query.results)
            query.enableUpdates()
        } else {
            let updateKeys = [
                NSMetadataQueryUpdateAddedItemsKey,
                NSMetadataQueryUpdateChangedItemsKey,
                NSMetadataQueryUpdateRemovedItemsKey,
            ]
            changedFiles = updateKeys.reduce(into: Set<ICloudSyncFile>()) { result, key in
                result.formUnion(files(in: notification.userInfo?[key]))
            }
        }

        guard !changedFiles.isEmpty else { return }
        pendingChangedFiles.formUnion(changedFiles)
        pendingDeliveryTask?.cancel()
        pendingDeliveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.deliverPendingChanges()
        }
    }

    private func files(in value: Any?) -> Set<ICloudSyncFile> {
        guard let items = value as? [NSMetadataItem] else { return [] }
        return Set(items.compactMap { item in
            guard let fileName = item.value(forAttribute: NSMetadataItemFSNameKey) as? String else {
                return nil
            }
            return ICloudSyncFile(fileName: fileName)
        })
    }

    private func deliverPendingChanges() {
        let candidates = pendingChangedFiles
        pendingChangedFiles.removeAll()
        pendingDeliveryTask = nil

        let changedFiles = Set(candidates.filter { file in
            let currentVersion = fileVersion(for: file)
            guard deliveredFileVersions[file] != currentVersion else { return false }
            deliveredFileVersions[file] = currentVersion
            return true
        })

        guard !changedFiles.isEmpty else { return }
        changeHandler?(changedFiles)
    }

    private func fileVersion(for file: ICloudSyncFile) -> FileVersion {
        guard let url = syncedURL(for: file),
              fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return FileVersion(exists: false, fileSize: nil, modificationDate: nil)
        }
        return FileVersion(
            exists: true,
            fileSize: values.fileSize,
            modificationDate: values.contentModificationDate
        )
    }

    private static func resolveICloudDirectory(fileManager: FileManager) -> URL? {
        if let containerURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            return containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("daydream", isDirectory: true)
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let iCloudDriveDocuments = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)

        guard fileManager.fileExists(atPath: iCloudDriveDocuments.path) else {
            return nil
        }
        return iCloudDriveDocuments.appendingPathComponent("daydream", isDirectory: true)
    }
}

enum ICloudSyncFile: CaseIterable, Hashable {
    case settings

    var fileName: String {
        switch self {
        case .settings:
            return "settings.json"
        }
    }

    init?(fileName: String) {
        switch fileName {
        case Self.settings.fileName:
            self = .settings
        default:
            return nil
        }
    }
}
