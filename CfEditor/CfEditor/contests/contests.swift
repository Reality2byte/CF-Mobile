import SwiftUI
import UIKit
import CryptoKit

// MARK: - 主Practice界面 - iOS 26原生设计风格

struct ContestsView: View {
    @AppStorage("cfHandle") private var handle: String = ""
    @StateObject var store: ContestsStore
    @StateObject private var problemsetStore = ProblemsetStore()
    
    // 分段控制器状态
    @State private var selectedMode: PracticeMode = .contests
    
    // 展开状态
    @State private var expandedContests: [Int: Bool] = [:]
    private var expanded: Set<Int> {
        Set(expandedContests.filter { $0.value }.map { $0.key })
    }
    
    // 导航到题目
    @State private var selectedProblem: CFProblem?
    
    // 筛选和搜索
    @State private var showingFilterSheet: Bool = false
    @State private var showingContestFilterSheet: Bool = false
    @State private var searchText: String = ""
    
    // 倒计时定时器
    @State private var countdownTimer: Timer?
    @State private var currentTime = Date()
    
    // 收藏
    @StateObject private var favoritesManager = FavoritesManager.shared
    @State private var showingFavorites = false
    
    // 选中的分类标签
    @State private var selectedTag: String? = nil
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 顶部 TabBar 切换器
                modeTabBar
                
                // 主内容区域
                mainContentSection
                
                // 底部占位
                Spacer()
                    .frame(height: 60)
            }
        }
        .appPageBackground()
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                favoritesButtonView
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                filterButtonView
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: selectedMode == .contests ? "Search contests" : "Search problems"
        )
        .onChange(of: selectedMode) { _, newMode in
            if newMode == .contests {
                searchText = store.filter.searchText
            } else {
                searchText = problemsetStore.filter.searchText
            }
        }
        .onChange(of: searchText) { _, newValue in
            if selectedMode == .contests {
                store.filter.searchText = newValue
                store.applyFilters()
            } else {
                problemsetStore.filter.searchText = newValue
                problemsetStore.applyFilters()
            }
        }
        .task {
            await store.ensureLoaded(currentHandle: handle)
            await problemsetStore.ensureLoaded(currentHandle: handle)
        }
        .onChange(of: handle.lowercased()) { _, _ in
            Task {
                await store.handleChanged(to: handle)
                await problemsetStore.handleChanged(to: handle)
                if selectedMode == .contests {
                    let ids = store.vms.map { $0.id }
                    for cid in ids { await store.ensureProblemsLoaded(contestId: cid, force: true) }
                }
            }
        }
        .refreshable {
            switch selectedMode {
            case .contests:
                await store.forceRefresh(currentHandle: handle)
                let ids = store.vms.map { $0.id }
                for cid in ids { await store.ensureProblemsLoaded(contestId: cid, force: true) }
            case .problemset:
                await problemsetStore.forceRefresh(currentHandle: handle)
            }
        }
        .navigationDestination(item: $selectedProblem) { p in
            ProblemViewerWrapper(problem: p)
        }
        .sheet(isPresented: $showingFilterSheet) {
            ProblemsetFilterView(store: problemsetStore)
        }
        .sheet(isPresented: $showingContestFilterSheet) {
            ContestFilterView(store: store)
        }
        .sheet(isPresented: $showingFavorites) {
            FavoritesSheetView(
                favoritesManager: favoritesManager,
                problemsetStore: problemsetStore,
                selectedProblem: $selectedProblem
            )
        }
        .onAppear {
            startCountdownTimer()
        }
        .onDisappear {
            stopCountdownTimer()
        }
    }
    
    // MARK: - 特色内容卡片 - 类似App Store今日推荐
    @ViewBuilder
    private var featuredContestsSection: some View {
        let (upcoming, _, finished) = partitionContests(store.vms)
        let featuredContests = Array((upcoming + finished).prefix(5))
        
        if !featuredContests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // 标题栏
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FEATURED")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Text("Contests")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                // 横向滚动的特色卡片
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(featuredContests.enumerated()), id: \.element.id) { index, contest in
                            featuredContestCard(contest: contest, index: index)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.1),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    private func featuredContestCard(contest: ContestVM, index: Int) -> some View {
        Button {
            performLightHaptic()
            // 展开该比赛
            expandedContests[contest.id] = true
            Task {
                await store.ensureProblemsLoaded(contestId: contest.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // 卡片头部 - 渐变背景
                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: gradientColors(for: contest.phase ?? "", index: index),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        // 状态标签
                        HStack(spacing: 6) {
                            Image(systemName: phaseIcon(for: contest.phase ?? ""))
                                .font(.system(size: 10, weight: .bold))
                            Text(phaseText(for: contest.phase ?? ""))
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.25))
                        )
                        
                        Spacer()
                        
                        // 比赛名称
                        Text(contest.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(16)
                }
                .frame(width: 220, height: 140)
                .cornerRadius(16)
                
                // 卡片底部信息
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let startTime = contest.startTime {
                            Text(startTime, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let duration = contest.durationSeconds {
                            Text(formatDuration(duration))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // 进度指示
                    if contest.phase != "BEFORE" {
                        let solved = store.solvedMap[contest.id] ?? 0
                        let total = store.problemCache[contest.id]?.count ?? 0
                        if total > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                Text("\(solved)/\(total)")
                                    .font(.caption)
                            }
                            .foregroundColor(.green)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 220)
        }
        .buttonStyle(ScaleButtonStyle())
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.05), value: store.vms.count)
    }
    
    // MARK: - 特色题目卡片
    @ViewBuilder
    private var featuredProblemsSection: some View {
        let featuredProblems = Array(problemsetStore.displayedProblems.prefix(5))
        
        if !featuredProblems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FEATURED")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Text("Problems")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(featuredProblems.enumerated()), id: \.element.id) { index, problem in
                            featuredProblemCard(problem: problem, index: index)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.green.opacity(0.1),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    private func featuredProblemCard(problem: CFProblem, index: Int) -> some View {
        Button {
            performLightHaptic()
            selectedProblem = problem
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // 卡片头部
                ZStack(alignment: .topTrailing) {
                    LinearGradient(
                        colors: [
                            colorForProblemRating(problem.rating).opacity(0.8),
                            colorForProblemRating(problem.rating).opacity(0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    
                    // 评分标签
                    if let rating = problem.rating {
                        Text("\(rating)")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .padding(16)
                    }
                    
                    // 状态图标
                    let status = problemsetStore.getProblemStatus(for: problem)
                    VStack {
                        circledStatusIcon(for: status)
                            .scaleEffect(1.2)
                    }
                    .padding(12)
                }
                .frame(width: 160, height: 120)
                .cornerRadius(16)
                
                // 题目信息
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(problem.contestId ?? 0)\(problem.index)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        // 收藏图标
                        Image(systemName: favoritesManager.isFavorite(id: problem.id) ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundColor(favoritesManager.isFavorite(id: problem.id) ? .yellow : .gray.opacity(0.3))
                    }
                    
                    Text(problem.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    // 通过人数
                    if let solvedCount = problemsetStore.problemStatistics[problem.id] {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text(formatSolvedCount(solvedCount))
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 160)
        }
        .buttonStyle(ScaleButtonStyle())
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.05), value: problemsetStore.displayedProblems.count)
    }
    
    // MARK: - 分类标签
    @ViewBuilder
    private var categoryTagsSection: some View {
        let tags: [String] = ["All", "Easy", "Medium", "Hard", "Div.1", "Div.2", "Educational", "Global Round"]
        
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tags, id: \.self) { tag in
                    categoryTagButton(tag: tag)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }
    
    private func categoryTagButton(tag: String) -> some View {
        let isSelected = selectedTag == tag || (selectedTag == nil && tag == "All")
        
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if tag == "All" {
                    selectedTag = nil
                } else {
                    selectedTag = tag
                }
            }
            performLightHaptic()
        } label: {
            Text(tag)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color(.systemGray6))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - 主内容区域
    @ViewBuilder
    private var mainContentSection: some View {
        VStack(spacing: 20) {
            // 未登录提示
            if handle.trimmed.isEmpty {
                loginPromptCard
            }
            
            // 根据模式显示内容
            switch selectedMode {
            case .contests:
                contestsListView
            case .problemset:
                problemsetListView
            }
        }
        .padding(.top, 8)
    }
    
    private var loginPromptCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to track progress")
                    .font(.headline)
                Text("Add your Codeforces handle in the Profile tab")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        )
        .padding(.horizontal, 20)
    }
    
    // MARK: - 比赛列表
    private var contestsListView: some View {
        VStack(spacing: 16) {
            // 加载中且无数据时显示骨架屏
            if store.loading && store.vms.isEmpty {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonListRow()
                }
                .padding(.horizontal, 20)
            }
            // 有数据时显示列表
            else if !store.vms.isEmpty {
                let (upcomingContests, _, finishedContests) = partitionContests(store.vms)
                
                // 即将开始/正在进行
                if !upcomingContests.isEmpty {
                    contestSection(
                        title: "Upcoming & Ongoing",
                        icon: "clock.arrow.circlepath",
                        iconColor: .blue,
                        contests: Array(upcomingContests.prefix(10)),
                        showProgress: true
                    )
                }
                
                // 已结束的比赛
                if !finishedContests.isEmpty {
                    contestSection(
                        title: "Past Contests",
                        icon: "checkmark.circle.fill",
                        iconColor: .secondary,
                        contests: Array(finishedContests.prefix(20)),
                        showProgress: true
                    )
                }
                
                // 加载更多
                if store.hasMore {
                    Button {
                        if store.filter.hasActiveFilters {
                            store.loadMoreFilteredIfNeeded()
                        } else {
                            store.loadMoreIfNeeded()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("Load More")
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding()
                    }
                    .buttonStyle(.bordered)
                }
            }
            // 加载完成但无数据
            else if store.hasLoaded {
                emptyContestsState
            }
            // 初始加载中
            else {
                ProgressView("Loading...")
                    .padding(40)
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - 空状态视图
    private var emptyContestsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trophy")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Contests Found")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Try adjusting your filters")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
            
            if store.filter.hasActiveFilters {
                Button("Clear Filters") {
                    store.filter = ContestFilter()
                    store.applyFilters()
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
    
    private func contestSection(title: String, icon: String, iconColor: Color, contests: [ContestVM], showProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 区块标题
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.headline)
                Spacer()
                
                Text("\(contests.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(.systemGray6))
                    )
            }
            .foregroundColor(iconColor)
            
            // 比赛卡片列表
            VStack(spacing: 10) {
                ForEach(Array(contests.enumerated()), id: \.element.id) { _, contest in
                    contestCard(contest: contest)
                }
            }
        }
    }
    
    private func contestCard(contest: ContestVM) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedContests[contest.id] ?? false },
            set: { isExpanding in
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedContests[contest.id] = isExpanding
                }
                if isExpanding {
                    Task {
                        await store.ensureProblemsLoaded(contestId: contest.id)
                    }
                }
            }
        )) {
            // 展开内容
            contestProblemsContent(contest: contest)
        } label: {
            contestCardHeader(contest: contest)
        }
        .buttonStyle(PlainButtonStyle())
    }
    

    private func contestCardHeader(contest: ContestVM) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // 比赛信息
                VStack(alignment: .leading, spacing: 6) {
                    Text(contest.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    HStack(spacing: 12) {
                        // 时间信息
                        if contest.phase == "BEFORE" {
                            if let startTime = contest.startTime {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 10))
                                    Text(countdownText(to: startTime))
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                .foregroundColor(.orange)
                            }
                        } else if contest.phase == "CODING" || contest.phase == "PENDING_SYSTEM_TEST" || contest.phase == "SYSTEM_TEST" {
                            if let startTime = contest.startTime, let duration = contest.durationSeconds {
                                let endTime = startTime.addingTimeInterval(TimeInterval(duration))
                                HStack(spacing: 4) {
                                    Image(systemName: "hourglass")
                                        .font(.system(size: 10))
                                    Text(timeUntil(endTime, showSeconds: true))
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                .foregroundColor(.green)
                            }
                        } else {
                            if let startTime = contest.startTime {
                                Text(startTime, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // 持续时长
                        if let duration = contest.durationSeconds {
                            Text("• \(formatDuration(duration))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // 进度信息
                if contest.phase != "BEFORE" && contest.phase != "CODING" {
                    let solved = store.solvedMap[contest.id] ?? 0
                    let total = store.problemCache[contest.id]?.count ?? 0
                    if total > 0 {
                        VStack(spacing: 4) {
                            Text("\(solved)/\(total)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                            
                            ProgressView(value: Double(solved), total: Double(total))
                                .progressViewStyle(.linear)
                                .frame(width: 60, height: 4)
                                .tint(phaseColor(for: contest.phase ?? ""))
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
            )
        }
    }
    
    private func contestProblemsContent(contest: ContestVM) -> some View {
        VStack(spacing: 8) {
            if contest.phase == "BEFORE" {
                HStack {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundColor(.secondary)
                    Text("Contest hasn't started yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else if let err = store.problemErrorMap[contest.id] {
                Text(err)
                    .foregroundColor(.red)
                    .font(.callout)
                    .padding()
            } else if let problems = store.problemCache[contest.id], !problems.isEmpty {
                ForEach(Array(problems.enumerated()), id: \.element.index) { _, problem in
                    problemRowItem(contest: contest, problem: problem)
                }
            } else if store.loadingContestIds.contains(contest.id) {
                HStack { ProgressView(); Text("Loading...") }
                    .padding()
            } else {
                Text("Tap to load problems")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .padding()
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }
    
    private func problemRowItem(contest: ContestVM, problem: CFProblem) -> some View {
        Button {
            performLightHaptic()
            selectedProblem = problem
        } label: {
            HStack(spacing: 12) {
                // 状态图标
                circledStatusIcon(for: problemStateForDisplay(vmId: contest.id, p: problem))
                    .scaleEffect(1.1)
                
                // 题目信息
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(problem.index)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(colorForProblemRating(problem.rating))
                        
                        Text(problem.name)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                    
                    HStack(spacing: 10) {
                        if let rating = problem.rating {
                            HStack(spacing: 4) {
                                Text("●")
                                    .font(.system(size: 8))
                                Text("\(rating)")
                            }
                            .font(.caption2)
                            .foregroundColor(colorForProblemRating(rating))
                        }
                        
                        if let solvedCount = store.problemStatistics[problem.id] {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                Text(formatSolvedCount(solvedCount))
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 题库列表
    private var problemsetListView: some View {
        VStack(spacing: 16) {
            // 加载中且无缓存时显示骨架屏
            if problemsetStore.loading && problemsetStore.problems.isEmpty {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonProblemCard()
                }
                .padding(.horizontal, 20)
            }
            // 有数据时显示
            else if !problemsetStore.problems.isEmpty {
                // 统计信息卡片
                statsCard
                
                // 题目卡片网格
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(Array(problemsetStore.displayedProblems.enumerated()), id: \.element.id) { index, problem in
                        problemGridCard(problem: problem, index: index)
                    }
                }
                
                // 加载更多
                if problemsetStore.canLoadMore {
                    Button {
                        problemsetStore.loadMoreIfNeeded()
                    } label: {
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("Load More")
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding()
                    }
                    .buttonStyle(.bordered)
                }
            }
            // 无数据时显示空状态
            else {
                VStack(spacing: 16) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    if problemsetStore.loading {
                        Text("Loading problems...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        ProgressView()
                            .padding(.top, 8)
                    } else {
                        Text("No Problems Found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("Pull to refresh")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    
    private var statsCard: some View {
        HStack(spacing: 20) {
            StatItem(
                title: "Total",
                value: "\(problemsetStore.problems.count)",
                icon: "list.bullet.rectangle",
                color: .blue
            )
            
            Divider()
                .frame(height: 40)
            
            StatItem(
                title: "Solved",
                value: "\(problemsetStore.userSolvedProblems.count)",
                icon: "checkmark.circle.fill",
                color: .green
            )
            
            Divider()
                .frame(height: 40)
            
            StatItem(
                title: "Favorites",
                value: "\(favoritesManager.favorites.count)",
                icon: "star.fill",
                color: .yellow
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        )
    }
    
    private func problemGridCard(problem: CFProblem, index: Int) -> some View {
        Button {
            performLightHaptic()
            selectedProblem = problem
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // 顶部：ID和状态
                HStack {
                    Text("\(problem.contestId ?? 0)\(problem.index)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    circledStatusIcon(for: problemsetStore.getProblemStatus(for: problem))
                }
                
                // 题目名称
                Text(problem.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                // 标签
                if let tags = problem.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(Color(.systemGray6))
                                    )
                            }
                            if tags.count > 3 {
                                Text("+\(tags.count - 3)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // 底部：评分、通过人数和收藏
                HStack(spacing: 12) {
                    if let rating = problem.rating {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(colorForProblemRating(rating))
                                .frame(width: 8, height: 8)
                            Text("\(rating)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(colorForProblemRating(rating))
                    }
                    
                    // 通过人数
                    if let solvedCount = problemsetStore.problemStatistics[problem.id] {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text(formatSolvedCount(solvedCount))
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if favoritesManager.isFavorite(id: problem.id) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.yellow)
                    }
                }
            }
            .padding(12)
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(colorForProblemRating(problem.rating).opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index % 10) * 0.03), value: problemsetStore.displayedProblems.count)
    }
    
    // MARK: - 工具栏
    private var favoritesButtonView: some View {
        Button {
            showingFavorites = true
        } label: {
            Image(systemName: favoritesManager.favorites.isEmpty ? "star" : "star.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .symbolEffect(.bounce, value: favoritesManager.favorites.count)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 顶部 TabBar 切换器 (iOS 26 原生毛玻璃风格)
    private var modeTabBar: some View {
        HStack(spacing: 0) {
            ForEach(PracticeMode.allCases, id: \.self) { mode in
                modeTabBarButton(for: mode)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    @ViewBuilder
    private func modeTabBarButton(for mode: PracticeMode) -> some View {
        if selectedMode == mode {
            selectedTabButton(for: mode)
        } else {
            unselectedTabButton(for: mode)
        }
    }
    
    private func selectedTabButton(for mode: PracticeMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedMode = mode
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName(for: mode))
                    .font(.system(size: 16))
                Text(mode.rawValue)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    
    private func unselectedTabButton(for mode: PracticeMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedMode = mode
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName(for: mode))
                    .font(.system(size: 16))
                Text(mode.rawValue)
                    .font(.subheadline)
                    .fontWeight(.regular)
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
    
    private func iconName(for mode: PracticeMode) -> String {
        switch mode {
        case .contests: return "list.bullet.rectangle"
        case .problemset: return "doc.text.magnifyingglass"
        }
    }
    
    @ViewBuilder
    private var filterButtonView: some View {
        if selectedMode == .problemset {
            Button {
                showingFilterSheet = true
            } label: {
                ZStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                    
                    if problemsetStore.filter.hasActiveFilters {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .offset(x: 8, y: -8)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                showingContestFilterSheet = true
            } label: {
                ZStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                    
                    if store.filter.hasActiveFilters {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .offset(x: 8, y: -8)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - 辅助函数
    private func partitionContests(_ contests: [ContestVM]) -> (upcoming: [ContestVM], ongoing: [ContestVM], finished: [ContestVM]) {
        var upcoming: [ContestVM] = []
        var ongoing: [ContestVM] = []
        var finished: [ContestVM] = []
        
        for contest in contests {
            if contest.phase == "BEFORE" {
                upcoming.append(contest)
            } else if contest.phase == "CODING" || contest.phase == "PENDING_SYSTEM_TEST" || contest.phase == "SYSTEM_TEST" {
                ongoing.append(contest)
            } else {
                finished.append(contest)
            }
        }
        
        let upcomingAndOngoing = (upcoming + ongoing).sorted { contest1, contest2 in
            guard let time1 = contest1.startTime, let time2 = contest2.startTime else {
                return false
            }
            return time1 < time2
        }
        
        return (upcomingAndOngoing, [], finished)
    }
    
    private func countdownText(to targetDate: Date) -> String {
        let interval = targetDate.timeIntervalSince(currentTime)
        
        if interval <= 0 {
            return "Started"
        }
        
        let totalSeconds = Int(interval)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if totalSeconds < 48 * 3600 {
            return String(format: "%02d:%02d:%02d", hours + days * 24, minutes, seconds)
        } else {
            return "\(days)d"
        }
    }
    
    private func timeUntil(_ date: Date, showSeconds: Bool = false) -> String {
        let interval = date.timeIntervalSince(currentTime)
        
        if interval <= 0 {
            return "Ended"
        }
        
        let totalSeconds = Int(interval)
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if totalSeconds > 48 * 3600 {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: currentTime)
            let startOfTargetDay = calendar.startOfDay(for: date)
            let dayComponents = calendar.dateComponents([.day], from: startOfToday, to: startOfTargetDay)
            return "\(dayComponents.day ?? 0)d"
        }
        
        if showSeconds {
            if totalSeconds >= 3600 {
                return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            } else if minutes > 0 {
                return String(format: "%02d:%02d", minutes, seconds)
            } else {
                return "\(seconds)s"
            }
        } else {
            if totalSeconds >= 3600 {
                return "\(hours)h \(minutes)m"
            } else if minutes > 0 {
                return "\(minutes)m"
            } else {
                return "\(totalSeconds)s"
            }
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func phaseIcon(for phase: String) -> String {
        switch phase {
        case "BEFORE": return "clock"
        case "CODING": return "play.fill"
        case "PENDING_SYSTEM_TEST", "SYSTEM_TEST": return "hourglass"
        default: return "checkmark"
        }
    }
    
    private func phaseText(for phase: String) -> String {
        switch phase {
        case "BEFORE": return "UPCOMING"
        case "CODING": return "LIVE"
        case "PENDING_SYSTEM_TEST": return "PENDING"
        case "SYSTEM_TEST": return "TESTING"
        default: return "FINISHED"
        }
    }
    
    private func phaseColor(for phase: String) -> Color {
        switch phase {
        case "BEFORE": return .orange
        case "CODING": return .green
        case "PENDING_SYSTEM_TEST", "SYSTEM_TEST": return .blue
        default: return .secondary
        }
    }
    
    private func gradientColors(for phase: String, index: Int) -> [Color] {
        let colorSets: [[Color]] = [
            [.orange, .red],
            [.blue, .purple],
            [.green, .teal],
            [.pink, .orange],
            [.purple, .blue]
        ]
        return colorSets[index % colorSets.count]
    }
    
    private func problemStateForDisplay(vmId: Int, p: CFProblem) -> ProblemAttemptState {
        let key = ProblemKey(contestId: p.contestId ?? vmId, index: p.index)
        if let s = store.problemAttemptMap[key] { return s }
        let norm = normalizeProblemName(p.name)
        return store.problemAttemptByName[norm] ?? .none
    }
    
    private func normalizeProblemName(_ name: String) -> String {
        let lowered = name.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsedSpaces = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsedSpaces
    }
    
    // MARK: - 定时器管理
    private func startCountdownTimer() {
        stopCountdownTimer()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            currentTime = Date()
        }
    }
    
    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}

// MARK: - 统计信息卡片组件
struct StatItem: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 圆形进度条样式
struct ContestCircularProgressStyle: ProgressViewStyle {
    var strokeLinewidth: CGFloat = 2
    
    func makeBody(configuration: Configuration) -> some View {
        let progress = configuration.fractionCompleted ?? 0
        
        return ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: strokeLinewidth)
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: strokeLinewidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview("Practice iOS 26 Design") {
    NavigationStack {
        ContestsView(store: ContestsStore())
            .navigationTitle("Practice")
    }
}

// MARK: - 骨架屏题目卡片
struct SkeletonProblemCard: View {
    @State private var shimmerOffset: CGFloat = -300
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部行
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 14)
                
                Spacer()
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 20, height: 20)
            }
            
            // 题目名称
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(height: 16)
                .frame(maxWidth: .infinity)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 100, height: 16)
            
            // 底部
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 12)
                
                Spacer()
            }
        }
        .padding(12)
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        )
        .overlay(
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Color.white.opacity(0.3), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .offset(x: shimmerOffset)
                .clipped()
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 300
            }
        }
    }
}


