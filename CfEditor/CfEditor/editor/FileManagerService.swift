import Foundation
import UniformTypeIdentifiers

struct FileLocation: Identifiable, Equatable {
    let id: UUID
    let name: String
    let url: URL
    let isExternal: Bool
    let bookmarkData: Data?
}

struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let modificationDate: Date?
    let size: Int64?
    let fileType: FileType

    var formattedSize: String {
        guard !isDirectory, let size else { return "Unknown Size" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

@MainActor
final class FileManagerService: ObservableObject {
    @Published var locations: [FileLocation] = []
    @Published var currentLocation: FileLocation?
    @Published var currentDirectory: URL?
    @Published var items: [FileItem] = []
    @Published var searchQuery: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private var activeSecurityScopedURL: URL?
    private let bookmarksKey = "FileManagerService.bookmarks"
    private let recentFilesKey = "FileManagerService.recentFiles"

    init() {
        loadLocations()
    }

    func loadLocations() {
        var result: [FileLocation] = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        result.append(FileLocation(id: UUID(), name: "On My iPhone", url: docs, isExternal: false, bookmarkData: nil))

        for bookmark in loadBookmarks() {
            if let url = resolveBookmark(bookmark) {
                let name = url.lastPathComponent
                result.append(FileLocation(id: UUID(), name: name, url: url, isExternal: true, bookmarkData: bookmark))
            }
        }
        locations = result
        if currentLocation == nil, let first = result.first {
            selectLocation(first)
        }
    }

    func selectLocation(_ location: FileLocation) {
        stopSecurityScopeIfNeeded()
        currentLocation = location
        currentDirectory = location.url
        if location.isExternal {
            startSecurityScope(for: location.url)
        }
        refresh()
    }

    func refresh() {
        guard let dir = currentDirectory else { return }
        isLoading = true
        errorMessage = nil
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let filtered = contents.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { return true }
            return isSupportedTextFile(url)
        }

        let mapped = filtered.map { url -> FileItem in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            let size = values?.fileSize.map { Int64($0) }
            let mod = values?.contentModificationDate
            let type = isDir ? .other : FileType.from(fileExtension: url.pathExtension)
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: isDir, modificationDate: mod, size: size, fileType: type)
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched = query.isEmpty ? mapped : mapped.filter { $0.name.lowercased().contains(query) }

        items = searched.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let l = lhs.modificationDate ?? .distantPast
            let r = rhs.modificationDate ?? .distantPast
            return l > r
        }
        isLoading = false
    }

    func enterDirectory(_ url: URL) {
        guard isDirectory(url) else { return }
        currentDirectory = url
        refresh()
    }

    func goUp() {
        guard let dir = currentDirectory, let location = currentLocation else { return }
        if dir.standardizedFileURL.path == location.url.standardizedFileURL.path { return }
        let parent = dir.deletingLastPathComponent()
        currentDirectory = parent
        refresh()
    }

    func createFile(named name: String) throws -> URL {
        guard let dir = currentDirectory else { throw NSError(domain: "FileManagerService", code: 1) }
        var fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty { fileName = "untitled.txt" }
        if URL(fileURLWithPath: fileName).pathExtension.isEmpty {
            fileName += ".txt"
        }
        let dest = uniqueURL(for: dir.appendingPathComponent(fileName))
        FileManager.default.createFile(atPath: dest.path, contents: Data())
        refresh()
        return dest
    }

    func createFolder(named name: String) throws {
        guard let dir = currentDirectory else { throw NSError(domain: "FileManagerService", code: 2) }
        let folder = uniqueDirectoryURL(for: dir.appendingPathComponent(name.isEmpty ? "Folder" : name))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        refresh()
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NSError(domain: "FileManagerService", code: 3) }
        let parent = url.deletingLastPathComponent()
        let dest = uniqueURL(for: parent.appendingPathComponent(name))
        try FileManager.default.moveItem(at: url, to: dest)
        refresh()
        return dest
    }

    func move(_ url: URL, to destinationFolder: URL) throws -> URL {
        let dest = uniqueURL(for: destinationFolder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.moveItem(at: url, to: dest)
        refresh()
        return dest
    }

    func addExternalFolder(_ url: URL) {
        guard let data = createBookmark(for: url) else { return }
        var bookmarks = loadBookmarks()
        if bookmarks.contains(data) { return }
        bookmarks.append(data)
        saveBookmarks(bookmarks)
        loadLocations()
    }

    func addRecentFile(_ url: URL) {
        var recents = loadRecentFiles()
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(20))
        saveRecentFiles(recents)
    }

    func recentFiles() -> [URL] {
        loadRecentFiles()
    }

    func resolveExternalFileBookmark(_ data: Data) -> URL? {
        resolveBookmark(data)
    }

    // MARK: - Helpers

    private func isSupportedTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        let allowed = ["txt", "md", "cpp", "cc", "cxx", "h", "hpp", "py", "java", "js", "ts", "json", "swift", "kt", "go", "rs", "rb", "php", "cs", "c", "m", "mm"]
        return allowed.contains(ext)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func uniqueURL(for url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func uniqueDirectoryURL(for url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let base = url.lastPathComponent
        var index = 1
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(index))")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData()
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func loadBookmarks() -> [Data] {
        (UserDefaults.standard.array(forKey: bookmarksKey) as? [Data]) ?? []
    }

    private func saveBookmarks(_ bookmarks: [Data]) {
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }

    private func loadRecentFiles() -> [URL] {
        let dataArr = (UserDefaults.standard.array(forKey: recentFilesKey) as? [Data]) ?? []
        return dataArr.compactMap { resolveBookmark($0) }
    }

    private func saveRecentFiles(_ urls: [URL]) {
        let data = urls.compactMap { createBookmark(for: $0) }
        UserDefaults.standard.set(data, forKey: recentFilesKey)
    }

    private func startSecurityScope(for url: URL) {
        activeSecurityScopedURL = url
        _ = url.startAccessingSecurityScopedResource()
    }

    private func stopSecurityScopeIfNeeded() {
        if let url = activeSecurityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURL = nil
    }
}
