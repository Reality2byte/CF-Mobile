import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct FilesBrowserView: View {
    let onOpenFile: (URL) -> Void
    let onDelete: (URL) -> Void

    init(onOpenFile: @escaping (URL) -> Void, onDelete: @escaping (URL) -> Void = { _ in }) {
        self.onOpenFile = onOpenFile
        self.onDelete = onDelete
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = FileManagerService()
    @State private var isCreateFileSheetPresented = false
    @State private var isCreateFolderSheetPresented = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    @State private var renameTarget: FileItem?
    @State private var renameText: String = ""
    @State private var moveTarget: FileItem?
    @State private var isFolderPickerPresented = false
    @State private var isFilePickerPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("Locations") {
                    ForEach(manager.locations) { location in
                        Button {
                            manager.selectLocation(location)
                        } label: {
                            HStack {
                                Image(systemName: location.isExternal ? "externaldrive" : "folder")
                                Text(location.name)
                                Spacer()
                                if manager.currentLocation?.id == location.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button {
                        isFolderPickerPresented = true
                    } label: {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                    }
                }

                Section("Files") {
                    if manager.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if manager.items.isEmpty {
                        HStack {
                            Spacer()
                            Text("No Files")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        ForEach(manager.items) { item in
                            Button {
                                if item.isDirectory {
                                    manager.enterDirectory(item.url)
                                } else {
                                    manager.addRecentFile(item.url)
                                    onOpenFile(item.url)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.isDirectory ? "folder.fill" : item.fileType.iconName)
                                        .foregroundStyle(item.isDirectory ? Color.accentColor : .primary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .lineLimit(1)
                                        if let date = item.modificationDate {
                                            Text(Self.shortDateFormatter.string(from: date))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if !item.isDirectory {
                                        Text(item.formattedSize)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Rename") {
                                    renameTarget = item
                                    renameText = item.name
                                }
                                if item.isDirectory == false {
                                    Button("Move…") {
                                        moveTarget = item
                                        isFolderPickerPresented = true
                                    }
                                }
                                Button(role: .destructive) {
                                    performDelete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    performDelete(item)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }

                if !manager.recentFiles().isEmpty {
                    Section("Recent") {
                        ForEach(manager.recentFiles(), id: \.path) { url in
                            Button {
                                onOpenFile(url)
                            } label: {
                                HStack {
                                    Image(systemName: "clock")
                                    Text(url.lastPathComponent)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $manager.searchQuery, prompt: "Search files")
            .onChange(of: manager.searchQuery) { _, _ in
                manager.refresh()
            }
            .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        manager.goUp()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(manager.currentDirectory == manager.currentLocation?.url)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New File…") { isCreateFileSheetPresented = true }
                        Button("New Folder…") { isCreateFolderSheetPresented = true }
                        Button("Open File…") { isFilePickerPresented = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .appListStyle()
            .onAppear { manager.refresh() }
            .alert("Failed to delete", isPresented: $showDeleteError) {
                Button("OK") {}
            } message: {
                Text(deleteErrorMessage)
            }
            .sheet(isPresented: $isCreateFileSheetPresented) {
                SaveFileSheetView(initialFileName: "untitled.txt", isCreatingFolder: false) { name in
                    do {
                        let url = try manager.createFile(named: name)
                        manager.addRecentFile(url)
                        onOpenFile(url)
                    } catch {}
                    isCreateFileSheetPresented = false
                }
            }
            .sheet(isPresented: $isCreateFolderSheetPresented) {
                SaveFileSheetView(initialFileName: "Folder", isCreatingFolder: true) { name in
                    try? manager.createFolder(named: name)
                    isCreateFolderSheetPresented = false
                }
            }
            .sheet(item: $renameTarget) { item in
                SaveFileSheetView(initialFileName: renameText, isCreatingFolder: item.isDirectory, isRenaming: true) { name in
                    do {
                        let newURL = try manager.rename(item.url, to: name)
                        if !item.isDirectory {
                            onOpenFile(newURL)
                        }
                    } catch {}
                    renameTarget = nil
                }
            }
            .sheet(isPresented: $isFolderPickerPresented) {
                FolderPickerRepresentable { url in
                    if let url, let target = moveTarget {
                        do {
                            let newURL = try manager.move(target.url, to: url)
                            onOpenFile(newURL)
                        } catch {}
                        moveTarget = nil
                    } else if let url {
                        manager.addExternalFolder(url)
                    }
                    isFolderPickerPresented = false
                }
            }
            .sheet(isPresented: $isFilePickerPresented) {
                FilePickerRepresentable { url in
                    if let url {
                        manager.addRecentFile(url)
                        onOpenFile(url)
                    }
                    isFilePickerPresented = false
                }
            }
        }
    }

    private func performDelete(_ item: FileItem) {
        do {
            try manager.delete(item.url)
            onDelete(item.url)
        } catch {
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

struct FolderPickerRepresentable: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPickerRepresentable
        init(_ parent: FolderPickerRepresentable) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick(nil)
        }
    }
}

struct FilePickerRepresentable: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.text, .plainText, .utf8PlainText, .sourceCode]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FilePickerRepresentable
        init(_ parent: FilePickerRepresentable) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick(nil)
        }
    }
}
