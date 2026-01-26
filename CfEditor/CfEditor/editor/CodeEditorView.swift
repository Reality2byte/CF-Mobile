import SwiftUI
import CryptoKit
import WebKit
import Combine
import UniformTypeIdentifiers

struct EditorSession: Identifiable, Equatable {
    let id: UUID
    var url: URL?
    var code: String
    var language: String
    var isDirty: Bool
    var lastSavedCode: String

    static func empty() -> EditorSession {
        EditorSession(id: UUID(), url: nil, code: "", language: "plaintext", isDirty: false, lastSavedCode: "")
    }
}

struct CodeEditorView: View {
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("cfHandle") private var cfHandle: String = ""

    @State private var code: String = ""
    @State private var language: String = "plaintext"
    // 主题跟随系统，无需用户选择
    @State private var readOnly: Bool = false
    @State private var fontSize: Int = 14
    // 行号默认开启，去掉开关
    @State private var minimap: Bool = false

    // 文件管理
    @State private var isFilesPresented: Bool = false
    @State private var currentFileURL: URL? = nil
    @State private var isSaveAsPresented: Bool = false
    @State private var saveAsFileName: String = ""
    @State private var isActionsPresented: Bool = false
    @State private var isExportPresented: Bool = false
    @State private var undoRequestToken: Int = 0
    @State private var redoRequestToken: Int = 0
    @State private var canUndo: Bool = false
    @State private var canRedo: Bool = false

    // 脏标记 & 保存提示
    @State private var isDirty: Bool = false
    @State private var lastSavedCode: String = ""
    @State private var toastText: String = ""
    @State private var showToast: Bool = false

    private let lastFilePathKey: String = "CodeEditorView.lastFilePath"
    private let showFilesOnLaunchKey: String = "CodeEditorView.showFilesOnLaunch"
    private let autosaveFileName: String = "__autosave__.json"
    private let autosaveEnabledKey: String = "CodeEditorView.autosaveEnabled"

    private let languages = [
        (key: "cpp", name: "C++"),
        (key: "python", name: "Python"),
        (key: "java", name: "Java"),
        (key: "plaintext", name: "Text")
    ]
    
    // 运行面板
    @State private var isRunPresented: Bool = false
    @State private var testCases: [TestCase] = [TestCase(input: "", expected: "", received: "")]
    @State private var isEditorReady: Bool = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var cookieHandle: String? = nil
    
    
    private var languageDisplayKey: String {
        switch language {
        case "plaintext": return "txt"
        default: return language
        }
    }

    var resolvedTheme: String { (colorScheme == .dark) ? "vs-dark" : "vs" }

    private var navigationTitleText: String {
        if shouldShowEmptyState {
            return ""
        }
        let base = currentFileURL?.lastPathComponent ?? "未命名"
        return isDirty ? "*\(base)" : base
    }

    private var hasCFLogin: Bool {
        let t = (cookieHandle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty
    }
    

    // 自动保存开关与防抖
    @State private var autosaveEnabled: Bool = false
    @State private var autosaveDebounceItem: DispatchWorkItem? = nil
    @State private var sessions: [EditorSession] = []
    @State private var activeSessionID: UUID? = nil

    var body: some View {
        let base: AnyView = AnyView(
            makeEditorContent()
                .background(Color(uiColor: .systemBackground))
                .navigationTitle(navigationTitleText)
                .navigationBarTitleDisplayMode(.inline)
                // 工具栏背景适配夜间模式
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                // 主题自动根据系统切换（依赖 colorScheme，计算属性 resolvedTheme 会变更）
                .toolbar { navigationToolbar }
                // 键盘工具栏：全局收起键盘
                .toolbar { keyboardToolbar }
        )

        return base
            // 文件管理弹窗
            .sheet(isPresented: $isFilesPresented) { filesSheetContent() }
            // 另存为
            .sheet(isPresented: $isSaveAsPresented) { saveAsSheetContent() }
            .onAppear { onAppearSetup(); refreshCFHandle() }
            // 跨 Tab 通知：直接打开指定文件
            .onReceive(NotificationCenter.default.publisher(for: .openEditorFileRequested)) { note in
                if let url = note.object as? URL, FileManager.default.fileExists(atPath: url.path) {
                    openFile(at: url)
                }
            }
            .onChange(of: isFilesPresented) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: showFilesOnLaunchKey)
            }
            // 代码变化：更新脏标记并自动保存草稿
            .onChange(of: code) { _, _ in
                updateDirtyStateAndAutosave()
                syncActiveSession()
            }
            .onChange(of: language) { _, _ in
                writeAutosave()
                syncActiveSession()
            }
            .onChange(of: autosaveEnabled) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: autosaveEnabledKey)
                if newValue { scheduleAutosaveFile() } else { autosaveDebounceItem?.cancel() }
            }
            // 测试样例变化：按文件持久化
            .onChange(of: testCases) { _, _ in
                persistCurrentTestCases()
            }
            // Cookie 变化时刷新视图，以便 hasCFLogin 即时更新
            .onReceive(NotificationCenter.default.publisher(for: .NSHTTPCookieManagerCookiesChanged)) { _ in
                refreshCFHandle()
            }
            // 运行面板（上下滑动的抽屉）
            .sheet(isPresented: $isRunPresented) {
                RunSheetView(testCases: $testCases, language: language, code: $code)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // 右上角动作面板（上下滑动的抽屉）
            .sheet(isPresented: $isActionsPresented) { actionsSheetContent() }
            // 文件导出选择器
            .sheet(isPresented: $isExportPresented) { exportSheetContent() }
            // 顶部轻提示
            .overlay(alignment: .top) {
                if showToast {
                    Text(toastText)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }

    // 顶部控制条已并入标题栏
}

// MARK: - 拆分的 Toolbar 与 Sheet 内容
extension CodeEditorView {
    private func refreshCFHandle() {
        Task {
            let h = await CFCookieBridge.shared.readCurrentCFHandleFromWK()
            await MainActor.run { self.cookieHandle = h }
        }
    }
    // 导航栏工具条
    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                isFilesPresented = true
            } label: {
                Image(systemName: "folder")
                    .imageScale(keyboardHeight > 0 ? .small : .medium)
            }
            .accessibilityLabel("File Browser")

            if !shouldShowEmptyState && keyboardHeight == 0 {
                Text("Lang：\(languageDisplayKey)")
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isExportPresented = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .imageScale(keyboardHeight > 0 ? .small : .medium)
            }
            .disabled(shouldShowEmptyState)
            .accessibilityLabel("导出")
            
            Button {
                #if canImport(UIKit)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
                isRunPresented = true
            } label: {
                Image(systemName: "play.fill")
                    .imageScale(keyboardHeight > 0 ? .small : .medium)
            }
            .disabled(shouldShowEmptyState)
            .accessibilityLabel("Run")

            Button {
                isActionsPresented = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .imageScale(keyboardHeight > 0 ? .small : .medium)
            }
            .disabled(shouldShowEmptyState)
            .accessibilityLabel("更多操作")
        }
    }


    // 键盘工具条
    @ToolbarContentBuilder
    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button {
                #if canImport(UIKit)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
            } label: {
                Label("完成", systemImage: "keyboard.chevron.compact.down")
                    .font(.caption)
                    .imageScale(.small)
            }
            .accessibilityLabel("收起键盘")
        }
    }

    // 文件浏览 Sheet 内容
    @ViewBuilder
    private func filesSheetContent() -> some View {
        FilesBrowserView(onOpenFile: { url in
            openFile(at: url)
            isFilesPresented = false
        }, onDelete: { deletedURL in
            handleDeletedURL(deletedURL)
        })
    }

    // 另存为 Sheet 内容
    @ViewBuilder
    private func saveAsSheetContent() -> some View {
        SaveFileSheetView(initialFileName: saveAsFileName, isCreatingFolder: false) { name in
            saveAsFile(named: name)
        }
    }

    // 设置面板 Sheet 内容
    @ViewBuilder
    private func actionsSheetContent() -> some View {
        SettingsSheetView(
            fontSize: $fontSize,
            minimap: $minimap,
            readOnly: $readOnly,
            autosaveEnabled: $autosaveEnabled,
            code: $code,
            onUndo: { undoRequestToken &+= 1 },
            onRedo: { redoRequestToken &+= 1 },
            canUndo: canUndo,
            canRedo: canRedo,
            onSave: { saveCurrentFile() }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    // 导出 Sheet 内容
    @ViewBuilder
    private func exportSheetContent() -> some View {
        ExportFileView(
            fileName: suggestedFileName(),
            fileContent: code,
            language: language,
            fileURL: currentFileURL,
            onExportComplete: { success, message in
                if success {
                    presentToast(message ?? "文件导出成功")
                } else {
                    presentToast(message ?? "文件导出失败")
                }
                isExportPresented = false
            }
        )
    }

    // onAppear 初始化
    private func onAppearSetup() {
        ensureSession()
        if let lastPath = UserDefaults.standard.string(forKey: lastFilePathKey) {
            let url = URL(fileURLWithPath: lastPath)
            if FileManager.default.fileExists(atPath: url.path) {
                openFile(at: url)
            }
        }
        let showFiles = UserDefaults.standard.bool(forKey: showFilesOnLaunchKey)
        isFilesPresented = showFiles
        migrateLegacyAutosaveIfNeeded()
        tryRestoreAutosaveIfNeeded()
        autosaveEnabled = UserDefaults.standard.bool(forKey: autosaveEnabledKey)
        if currentFileURL == nil {
            testCases = loadPersistedTestCases(for: nil)
        }
        _ = hasCFLogin
        
        // 监听键盘事件
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [self] notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
               let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                // 获取键盘高度，减去底部安全区域和额外的偏移
                // 因为底部工具栏已经有自己的高度，我们只需要补偿键盘遮挡工具栏的部分
                let bottomSafeArea = window.safeAreaInsets.bottom
                // 只保留键盘高度的一小部分，因为底部已经有工具栏和safe area
                let adjustedHeight = max(0, (keyboardFrame.height - bottomSafeArea) * 0.1)
                
                withAnimation(.easeOut(duration: 0.25)) {
                    self.keyboardHeight = adjustedHeight
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [self] _ in
            withAnimation(.easeOut(duration: 0.25)) {
                self.keyboardHeight = 0
            }
        }
        #endif
    }
}

// MARK: - 辅助：类型擦除以减轻编译器负担
private extension View {
    func asAnyView() -> AnyView { AnyView(self) }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 文件操作
extension CodeEditorView {
    @ViewBuilder
    private func makeEditorContent() -> some View {
        VStack(spacing: 0) {
            tabBarView
            ZStack {
                if shouldShowEmptyState {
                    ContentUnavailableView {
                        Label("No File Open", systemImage: "doc.text")
                    } description: {
                        Text("Create a new file or open an existing one to start coding")
                    } actions: {
                        Button("Create New File") {
                            saveAsFileName = suggestedFileName()
                            isSaveAsPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Open File") {
                            isFilesPresented = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(40)
                } else {
                    ZStack {
                        MonacoEditorView(
                            text: $code,
                            language: language,
                            theme: resolvedTheme,
                            readOnly: readOnly,
                            fontSize: fontSize,
                            lineNumbers: "on",
                            minimap: minimap,
                            onContentChange: nil,
                            undoRequestToken: undoRequestToken,
                            redoRequestToken: redoRequestToken,
                            onUndoStateChange: { u, r in
                                canUndo = u
                                canRedo = r
                            },
                            onReady: {
                                isEditorReady = true
                            }
                        )
                        .padding(.bottom, keyboardHeight)

                        if !isEditorReady {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Loading...")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground))
                            )
                        }
                    }
                }
            }
        }
    }
    private func updateCFLoginState() {}
    private var tabBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    let isActive = session.id == activeSessionID
                    Button {
                        activateSession(session.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(session.url?.lastPathComponent ?? "Untitled")
                                .lineLimit(1)
                                .font(.caption)
                            if session.isDirty {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                            Button {
                                closeSession(session.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isActive ? Color(uiColor: .secondarySystemBackground) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func closeSession(_ id: UUID) {
        persistActiveSession()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (activeSessionID == id)
        let fallbackID: UUID? = {
            if sessions.count <= 1 { return nil }
            if index > 0 { return sessions[index - 1].id }
            return sessions[safe: index + 1]?.id
        }()
        sessions.remove(at: index)
        if sessions.isEmpty {
            let session = EditorSession.empty()
            sessions = [session]
            activeSessionID = session.id
            applySession(session)
            return
        }
        if wasActive, let nextID = fallbackID {
            activateSession(nextID)
        }
    }
    private var shouldShowEmptyState: Bool {
        currentFileURL == nil && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var appFolder = base.appendingPathComponent("CfEditor", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appFolder.path) {
            try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true, attributes: nil)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? appFolder.setResourceValues(values)
        }
        return appFolder
    }

    private func testCasesDirectory() -> URL {
        var dir = applicationSupportDirectory().appendingPathComponent("TestCases", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    private func testCasesFileURL(for fileURL: URL?) -> URL {
        // 未命名/无文件的上下文使用固定键
        if fileURL == nil {
            return testCasesDirectory().appendingPathComponent("__unsaved__.json")
        }
        let path = fileURL!.standardizedFileURL.path
        let hashed = Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return testCasesDirectory().appendingPathComponent("\(hashed).json")
    }

    private func persistCurrentTestCases() {
        let url = testCasesFileURL(for: currentFileURL)
        do {
            let data = try JSONEncoder().encode(testCases)
            try data.write(to: url, options: .atomic)
        } catch {
            // 忽略持久化失败
        }
    }

    private func loadPersistedTestCases(for fileURL: URL?) -> [TestCase] {
        let url = testCasesFileURL(for: fileURL)
        guard let data = try? Data(contentsOf: url) else { return [TestCase(input: "", expected: "", received: "")] }
        if let arr = try? JSONDecoder().decode([TestCase].self, from: data) {
            // 确保至少有一个样例
            return arr.isEmpty ? [TestCase(input: "", expected: "", received: "")] : arr
        } else {
            return [TestCase(input: "", expected: "", received: "")]
        }
    }

    private func removePersistedTestCases(for fileURL: URL) {
        let url = testCasesFileURL(for: fileURL)
        try? FileManager.default.removeItem(at: url)
    }

    private func sortedUserFiles(excluding url: URL? = nil) -> [URL] {
        let dir = documentsDirectory()
        let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let filtered = (contents ?? []).filter { candidate in
            guard let url = url else { return true }
            return candidate.standardizedFileURL != url.standardizedFileURL
        }
        return filtered.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
    }

    private func ensureSession() {
        if sessions.isEmpty {
            let session = EditorSession.empty()
            sessions = [session]
            activeSessionID = session.id
            applySession(session)
        }
    }

    private func persistActiveSession() {
        guard let id = activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].url = currentFileURL
        sessions[index].code = code
        sessions[index].language = language
        sessions[index].isDirty = isDirty
        sessions[index].lastSavedCode = lastSavedCode
    }

    private func syncActiveSession() {
        persistActiveSession()
    }

    private func applySession(_ session: EditorSession) {
        code = session.code
        language = session.language
        currentFileURL = session.url
        lastSavedCode = session.lastSavedCode
        isDirty = session.isDirty
        isEditorReady = false
        testCases = loadPersistedTestCases(for: session.url)
    }

    private func activateSession(_ id: UUID) {
        persistActiveSession()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        activeSessionID = id
        applySession(session)
        if let url = session.url {
            UserDefaults.standard.set(url.path, forKey: lastFilePathKey)
        }
    }

    private func handleDeletedURL(_ url: URL) {
        removePersistedTestCases(for: url)
        let path = url.standardizedFileURL.path
        sessions.removeAll { $0.url?.standardizedFileURL.path == path }
        if sessions.isEmpty {
            if let next = sortedUserFiles().first {
                openFile(at: next)
                return
            } else {
                let session = EditorSession.empty()
                sessions = [session]
                activeSessionID = session.id
                applySession(session)
                UserDefaults.standard.removeObject(forKey: lastFilePathKey)
                return
            }
        }
        if let active = activeSessionID, sessions.contains(where: { $0.id == active }) == false {
            activeSessionID = sessions.first?.id
            if let id = activeSessionID {
                activateSession(id)
            }
        }
    }

    private func openFile(at url: URL) {
        ensureSession()
        if let existing = sessions.first(where: { $0.url?.standardizedFileURL.path == url.standardizedFileURL.path }) {
            activateSession(existing.id)
            UserDefaults.standard.set(url.path, forKey: lastFilePathKey)
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        persistActiveSession()
        let session = EditorSession(id: UUID(), url: url, code: text, language: languageKey(for: url.pathExtension), isDirty: false, lastSavedCode: text)
        sessions.append(session)
        activateSession(session.id)
        UserDefaults.standard.set(url.path, forKey: lastFilePathKey)
    }

    private func saveCurrentFile() {
        if let url = currentFileURL {
            save(to: url)
        } else {
            saveAsFileName = suggestedFileName()
            isSaveAsPresented = true
        }
    }

    private func saveAsFile(named name: String) {
        var fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty { fileName = suggestedFileName() }
        if URL(fileURLWithPath: fileName).pathExtension.isEmpty {
            fileName += "." + defaultExtension(for: language)
        }
        let url = documentsDirectory().appendingPathComponent(fileName)
        // 新建后根据扩展名锁定语言展示
        language = languageKey(for: url.pathExtension)
        save(to: url)
        currentFileURL = url
        isSaveAsPresented = false
        // 将当前测试样例与新文件绑定并持久化
        persistCurrentTestCases()
    }

    private func save(to url: URL) {
        do {
            try code.data(using: .utf8)?.write(to: url)
            UserDefaults.standard.set(url.path, forKey: lastFilePathKey)
            lastSavedCode = code
            isDirty = false
            clearAutosave()
            syncActiveSession()
            if !autosaveEnabled {
                presentToast("已保存")
            }
        } catch {
            // 简化处理：忽略错误
        }
    }

    private func suggestedFileName() -> String {
        // 如果有当前文件，使用文件名；否则根据语言生成默认名称
        if let currentFile = currentFileURL {
            return currentFile.lastPathComponent
        } else {
            let ext = defaultExtension(for: language)
            return "untitled.\(ext)"
        }
    }

    private func defaultExtension(for language: String) -> String {
        switch language {
        case "cpp": return "cpp"
        case "python": return "py"
        case "java": return "java"
        case "plaintext": return "txt"
        default: return "txt"
        }
    }

    private func languageKey(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "c", "cc", "cpp", "cxx", "hpp", "h": return "cpp"
        case "py": return "python"
        case "java": return "java"
        case "js", "mjs", "cjs": return "plaintext"
        case "ts": return "plaintext"
        default: return "plaintext"
        }
    }

    private struct ParsedProblem {
        let contestId: Int
        let index: String
    }

    // 从当前文件名中解析 Codeforces 题号（形如 1234A.cpp / 1234_A.py / 1234A2.cpp）
    private func parseProblemFromCurrentFile() -> ParsedProblem? {
        guard let name = currentFileURL?.lastPathComponent else { return nil }
        let base = name.components(separatedBy: ".").dropLast().joined(separator: ".")
        // 正则：contestId=digits，后跟 index=[A-Za-z][0-9A-Za-z]* 可含下划线
        // 例：1873A、1873_A、1873A2
        let pattern = "^([0-9]{3,6})[_-]?([A-Za-z][0-9A-Za-z]*)$"
        if let r = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(location: 0, length: base.utf16.count)
            if let m = r.firstMatch(in: base, options: [], range: range), m.numberOfRanges >= 3 {
                if let g1 = Range(m.range(at: 1), in: base), let g2 = Range(m.range(at: 2), in: base) {
                    let cidStr = String(base[g1])
                    let idx = String(base[g2]).uppercased()
                    if let cid = Int(cidStr) { return ParsedProblem(contestId: cid, index: idx) }
                }
            }
        }
        return nil
    }




}

#if DEBUG
struct CodeEditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { CodeEditorView() }
    }
}
#endif

// MARK: - 轻提示 & 草稿持久化
extension CodeEditorView {
    private func presentToast(_ text: String) {
        toastText = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut) { showToast = false }
        }
    }

    private struct AutoSavePayload: Codable {
        var path: String?
        var code: String
        var language: String
    }

    private func autosaveURL() -> URL {
        applicationSupportDirectory().appendingPathComponent(autosaveFileName)
    }

    private func writeAutosave() {
        let payload = AutoSavePayload(path: currentFileURL?.standardizedFileURL.path,
                                      code: code,
                                      language: language)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: autosaveURL(), options: .atomic)
        } catch { /* 忽略草稿写入错误 */ }
    }

    private func clearAutosave() {
        try? FileManager.default.removeItem(at: autosaveURL())
    }

    private func tryRestoreAutosaveIfNeeded() {
        let url = autosaveURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(AutoSavePayload.self, from: data) else { return }

        // 若当前没有打开文件且编辑区为空，则恢复草稿
        if currentFileURL == nil && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            code = payload.code
            language = payload.language
            lastSavedCode = ""
            isDirty = !payload.code.isEmpty
            return
        }

        // 若当前打开文件与草稿指向同一路径，且草稿与磁盘不一致，则恢复草稿
        if let cur = currentFileURL?.standardizedFileURL.path,
           let savedPath = payload.path,
           cur == savedPath,
           payload.code != lastSavedCode {
            code = payload.code
            isDirty = true
        }
    }

    private func updateDirtyStateAndAutosave() {
        isDirty = (code != lastSavedCode)
        writeAutosave()
        scheduleAutosaveFile()
    }

    private func scheduleAutosaveFile() {
        guard autosaveEnabled else { return }
        autosaveDebounceItem?.cancel()
        let item = DispatchWorkItem { [code, currentFileURL] in
            // 仅当已有目标文件时执行自动保存，未命名文件不触发磁盘写入
            guard let url = currentFileURL else { return }
            do {
                try code.data(using: .utf8)?.write(to: url)
                lastSavedCode = code
                isDirty = false
                clearAutosave()
                syncActiveSession()
            } catch { /* 忽略自动保存失败 */ }
        }
        autosaveDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func migrateLegacyAutosaveIfNeeded() {
        let legacyURL = documentsDirectory().appendingPathComponent(autosaveFileName)
        let newURL = autosaveURL()
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        // 若新位置已有文件则优先保留新文件，删除旧文件
        if FileManager.default.fileExists(atPath: newURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
            return
        }
        do {
            try FileManager.default.moveItem(at: legacyURL, to: newURL)
        } catch {
            // 如果移动失败，尝试复制后删除旧文件
            _ = try? FileManager.default.copyItem(at: legacyURL, to: newURL)
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }
}
