//
//  ChatView.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import SwiftUI
import AppKit

struct QAGroupView: View {
    let item: QAItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.question).font(.headline)
            Divider()
            ParsedTextView(text: item.answer)
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.2), lineWidth: 1))
    }
}

struct ParsedTextView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Split text into main content and sources
            let parts = text.components(separatedBy: "\n\n**Sources:**")
            let mainContent = parts.first ?? text
            let sources = parts.count > 1 ? parts[1] : ""
            
            // Main content
            Text(mainContent)
                .font(.body)
                .textSelection(.enabled)
            
            // Sources section with clickable citations
            if !sources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("**Sources:**")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    ForEach(parseSources(sources), id: \.id) { source in
                        Button(action: {
                            openFile(at: source.filePath)
                        }) {
                            HStack {
                                Text(source.citation)
                                    .foregroundColor(.blue)
                                    .underline()
                                Spacer()
                                Image(systemName: "doc.text")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }
    
    private func parseSources(_ sourcesText: String) -> [CitationSource] {
        let lines = sourcesText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var sources: [CitationSource] = []
        
        for line in lines {
            if line.hasPrefix("[") {
                // Extract citation number and file path
                // Format: "[1] filename.pdf - folderName | /full/path/to/file.pdf"
                let components = line.components(separatedBy: " | ")
                if components.count >= 2 {
                    let citationPart = components[0].trimmingCharacters(in: .whitespaces)
                    let fullPath = components[1].trimmingCharacters(in: .whitespaces)
                    
                    sources.append(CitationSource(
                        citation: citationPart,
                        filePath: fullPath
                    ))
                } else {
                    // Fallback for old format without full path
                    let components = line.components(separatedBy: " - ")
                    if components.count >= 2 {
                        let citation = components[0].trimmingCharacters(in: .whitespaces)
                        let fileInfo = components[1].trimmingCharacters(in: .whitespaces)
                        
                        let filePath = extractFilePath(from: citation, fileInfo: fileInfo)
                        
                        sources.append(CitationSource(
                            citation: citation,
                            filePath: filePath
                        ))
                    }
                }
            }
        }
        
        return sources
    }
    
    private func extractFilePath(from citation: String, fileInfo: String) -> String {
        // Extract filename from citation like "[1] filename.pdf"
        let citationParts = citation.components(separatedBy: " ")
        if citationParts.count >= 2 {
            let fileName = citationParts[1]
            // Try to find the full path by searching in common locations
            return findFullPath(for: fileName, in: fileInfo)
        }
        return ""
    }
    
    private func findFullPath(for fileName: String, in folderInfo: String) -> String {
        // This is a simplified approach - in a real app you'd want to store the full paths
        // For now, we'll try to construct a reasonable path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let possiblePaths = [
            "\(homeDir)/Desktop/Career/Company/\(folderInfo)/\(fileName)",
            "\(homeDir)/Documents/\(folderInfo)/\(fileName)",
            "\(homeDir)/Desktop/\(folderInfo)/\(fileName)"
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // Fallback to just the filename
        return fileName
    }
    
    private func openFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}

struct CitationSource: Identifiable {
    let id = UUID()
    let citation: String
    let filePath: String
}

struct LoadingAnimationView: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Spinning indicator
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.blue, lineWidth: 2)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
            
            // Flashing wave text
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Text("●")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                        .opacity(isAnimating ? 1.0 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                            value: isAnimating
                        )
                }
            }
            
            Text("AI is thinking...")
                .font(.body)
                .foregroundColor(.secondary)
                .opacity(isAnimating ? 1.0 : 0.5)
                .animation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                    value: isAnimating
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.2), lineWidth: 1))
        .onAppear {
            isAnimating = true
        }
    }
}

private var settingsIcon: some View {
    Group {
        #if canImport(AppKit)
        if NSImage(named: "logo3") != nil {
            Image("logo3").resizable().renderingMode(.original)
        } else {
            Image(systemName: "gearshape.fill").symbolRenderingMode(.hierarchical)
        }
        #else
        Image(systemName: "gearshape.fill").symbolRenderingMode(.hierarchical)
        #endif
    }
    .frame(width: 18, height: 18)
}

// Transparent background view
struct TransparentBackground: View {
    var body: some View {
        Color.clear
            .background(.regularMaterial.opacity(0.8))
    }
}

// Extension to make window transparent
#if canImport(AppKit)
extension NSWindow {
    func setTransparent() {
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.styleMask.insert(.fullSizeContentView)
    }
}
#endif

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var currentPage: AppPage = .chat

    var body: some View {
        Group {
            switch currentPage {
            case .chat:
                ChatPageView(vm: vm, currentPage: $currentPage)
            case .settings:
                SettingsPageView(currentPage: $currentPage)
            }
        }
    }
}

enum AppPage {
    case chat
    case settings
}

struct ChatPageView: View {
    @ObservedObject var vm: ChatViewModel
    @Binding var currentPage: AppPage

    var body: some View {
        VStack(spacing: 0) {
            // TOP INPUT
            HStack(spacing: 8) {
                TextField("Ask AI anything...", text: $vm.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(vm.isLoading ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                    .scaleEffect(vm.isLoading ? 1.02 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: vm.isLoading)
                    .disabled(vm.isLoading)
                    .onSubmit {
                        if !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isLoading {
                            Task { await vm.send() }
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            Divider()

            // MESSAGES
            ScrollViewReader { proxy in
            ScrollView {
                    LazyVStack(spacing: 16) {
                    ForEach(vm.items) { item in
                        QAGroupView(item: item)
                                .padding(.horizontal, 16)
                                .id(item.id)
                        }
                        
                        // Loading animation when AI is responding
                        if vm.isLoading {
                            LoadingAnimationView()
                                .padding(.horizontal, 16)
                                .id("loading")
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: vm.items.count) {
                    // Scroll to bottom when new message is added
                    if let lastItem = vm.items.last {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(lastItem.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: vm.isLoading) {
                    if vm.isLoading {
                        // Scroll to loading indicator
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // BOTTOM-LEFT SETTINGS BUTTON
            HStack {
                Button {
                    currentPage = .settings
                } label: {
                    settingsIcon
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Settings")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial.opacity(0.95))
        .onAppear {
            // Set window transparency
            #if canImport(AppKit)
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first {
                    window.setTransparent()
                }
            }
            #endif
        }
    }
}

// New Settings Page View
struct SettingsPageView: View {
    @Binding var currentPage: AppPage
    @State private var selectedTab: SettingsTab = .general
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Header with back button
                HStack {
                    Button {
                        currentPage = .chat
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Back to Chat")
                    
                    Text("Settings")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                Divider()
                
                // Settings Tabs
                VStack(alignment: .leading, spacing: 4) {
                    SettingsTabButton(
                        title: "General",
                        icon: "gearshape.fill",
                        isSelected: selectedTab == .general
                    ) {
                        selectedTab = .general
                    }
                    
                    SettingsTabButton(
                        title: "AI",
                        icon: "brain.head.profile",
                        isSelected: selectedTab == .ai
                    ) {
                        selectedTab = .ai
                    }
                    
                    SettingsTabButton(
                        title: "Indexing",
                        icon: "doc.text.magnifyingglass",
                        isSelected: selectedTab == .indexing
                    ) {
                        selectedTab = .indexing
                    }
                    
                    SettingsTabButton(
                        title: "Account",
                        icon: "person.circle.fill",
                        isSelected: selectedTab == .account
                    ) {
                        selectedTab = .account
                    }
                    
                    SettingsTabButton(
                        title: "About",
                        icon: "info.circle.fill",
                        isSelected: selectedTab == .about
                    ) {
                        selectedTab = .about
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                Spacer()
            }
            .frame(width: 200)
            .background(.regularMaterial.opacity(0.8))
            
            Divider()
            
            // Right Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsView()
                    case .ai:
                        AISettingsView()
                    case .indexing:
                        IndexingSettingsView()
                    case .account:
                        AccountSettingsView()
                    case .about:
                        AboutSettingsView()
                    }
                }
                .padding(24)
            }
            .background(.regularMaterial.opacity(0.95))
        }
        .background(.regularMaterial.opacity(0.95))
    }
}

enum SettingsTab: CaseIterable {
    case general, ai, indexing, account, about
    
    var title: String {
        switch self {
        case .general: return "General"
        case .ai: return "AI"
        case .indexing: return "Indexing"
        case .account: return "Account"
        case .about: return "About"
        }
    }
}

struct SettingsTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// Settings Content Views
struct GeneralSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow(
                    title: "Window Transparency",
                    description: "Adjust the transparency level of the main window",
                    content: {
                        HStack {
                            Text("High")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(value: .constant(0.95), in: 0.5...1.0)
                            Text("Low")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 200)
                    }
                )
                
                SettingsRow(
                    title: "Auto-save Conversations",
                    description: "Automatically save chat history",
                    content: {
                        Toggle("", isOn: .constant(true))
                    }
                )
                
                SettingsRow(
                    title: "Start at Login",
                    description: "Launch Smart Light when you log in",
                    content: {
                        Toggle("", isOn: .constant(false))
                    }
                )
            }
        }
    }
}

struct AISettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AI Configuration")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow(
                    title: "AI Model",
                    description: "Select the AI model for responses",
                    content: {
                        Picker("Model", selection: .constant("gpt-5-nano")) {
                            Text("GPT-5 Nano").tag("gpt-5-nano")
                            Text("GPT-4").tag("gpt-4")
                            Text("Claude").tag("claude")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                )
                
                SettingsRow(
                    title: "Response Style",
                    description: "Configure how the AI responds",
                    content: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Verbosity:")
                                Picker("Verbosity", selection: .constant("low")) {
                                    Text("Low").tag("low")
                                    Text("Medium").tag("medium")
                                    Text("High").tag("high")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                            }
                            
                            HStack {
                                Text("Reasoning:")
                                Picker("Reasoning", selection: .constant("minimal")) {
                                    Text("Minimal").tag("minimal")
                                    Text("Standard").tag("standard")
                                    Text("Detailed").tag("detailed")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                            }
                        }
                    }
                )
                
                SettingsRow(
                    title: "API Key",
                    description: "Your OpenAI API key for AI responses",
                    content: {
                        HStack {
                            SecureField("sk-...", text: .constant("sk-****************"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Button("Test") {
                                // Test API key
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                )
            }
        }
    }
}

struct IndexingSettingsView: View {
    @State private var chunks = 0
    @State private var foldersIndexed: [String] = []
    @State private var indexing = false
    @State private var showProgress = false
    @State private var progress = 0.0
    @State private var progressStage = "Starting..."
    @State private var cancelIndexing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Indexing")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow(
                    title: "Current Status",
                    description: "Indexed chunks and folders",
                    content: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(chunks) chunks indexed")
                                .font(.system(size: 14, weight: .medium))
                            if !foldersIndexed.isEmpty {
                                Text("Folders: \(foldersIndexed.count)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                )
                
                SettingsRow(
                    title: "Index New Folder",
                    description: "Select folders to index for AI search",
                    content: {
                        Button("Choose Folders") {
                            pickAndIndex()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                )
                
                if showProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress, total: 1.0) {
                            Text("Indexing…")
                        } currentValueLabel: {
                            Text("\(Int(progress * 100))%")
                        }
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                        
                        Text(progressStageText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .animation(.easeInOut(duration: 0.3), value: progressStageText)
                        
                        if indexing {
                            Button("Cancel") {
                                cancelIndexing = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
    
    private var progressStageText: String {
        if progress < 0.1 {
            return "Discovering files..."
        } else if progress < 0.9 {
            return "Processing files..."
        } else if progress < 0.95 {
            return "Finalizing..."
        } else if progress < 1.0 {
            return "Completing..."
        } else {
            return "Complete!"
        }
    }
    
    private func pickAndIndex() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        
        indexing = true
        showProgress = true
        progress = 0
        progressStage = "Starting..."
        cancelIndexing = false
        let folders = panel.urls.map { $0.path }
        
        guard let ix = RagSession.shared.indexer else { 
            self.progress = 1.0
            indexing = false
            showProgress = false
            return 
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                RagSession.shared.resetStore()
                
                if self.cancelIndexing {
                    DispatchQueue.main.async {
                        self.handleIndexingCancellation()
                    }
                    return
                }
                
                try ix.index(folders: folders, 
                            progress: { p in
                                DispatchQueue.main.async { 
                                    self.progress = max(min(p, 1.0), 0.0)
                                    if p < 0.1 {
                                        self.progressStage = "Discovering files..."
                                    } else if p < 0.9 {
                                        self.progressStage = "Processing files..."
                                    } else if p < 0.95 {
                                        self.progressStage = "Finalizing..."
                                    } else if p < 1.0 {
                                        self.progressStage = "Completing..."
                                    } else {
                                        self.progressStage = "Complete!"
                                    }
                                }
                            },
                            shouldCancel: {
                                return self.cancelIndexing
                            })
                
                if self.cancelIndexing {
                    DispatchQueue.main.async {
                        self.handleIndexingCancellation()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.chunks = RagSession.shared.getStoreCount()
                        self.foldersIndexed = folders
                        self.indexing = false
                        self.progress = 1.0
                        self.progressStage = "Complete!"
                        self.showProgress = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.indexing = false
                    self.progress = 0
                    self.progressStage = "Error"
                    self.showProgress = false
                }
            }
        }
    }
    
    private func handleIndexingCancellation() {
        indexing = false
        showProgress = false
        progress = 0
        progressStage = "Cancelled"
        cancelIndexing = false
    }
}

struct AccountSettingsView: View {
    @State private var isLoggedIn = false
    @State private var userName = ""
    @State private var userEmail = ""
    @State private var showLoginSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            if isLoggedIn {
                // Logged in state
                VStack(alignment: .leading, spacing: 16) {
                    // User profile section
                    HStack(spacing: 16) {
                        // Profile avatar
                        Circle()
                            .fill(.blue.gradient)
                            .frame(width: 64, height: 64)
                            .overlay(
                                Text(userName.prefix(1).uppercased())
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            )
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(userName)
                                .font(.system(size: 18, weight: .semibold))
                            Text(userEmail)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text("Pro Member")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.blue)
            .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    
                    Divider()
                    
                    // Account features
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account Features")
                            .font(.system(size: 16, weight: .semibold))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            AccountFeatureRow(
                                icon: "cloud.fill",
                                title: "Cloud Sync",
                                description: "Sync your data across devices",
                                isPro: true
                            )
                            
                            AccountFeatureRow(
                                icon: "brain.head.profile",
                                title: "Unlimited AI Queries",
                                description: "No limits on AI responses",
                                isPro: true
                            )
                            
                            AccountFeatureRow(
                                icon: "doc.text.magnifyingglass",
                                title: "Advanced Search",
                                description: "Enhanced document search capabilities",
                                isPro: true
                            )
                            
                            AccountFeatureRow(
                                icon: "folder.fill",
                                title: "Unlimited Indexing",
                                description: "Index as many folders as you want",
                                isPro: true
                            )
                        }
                    }
                    
                    Divider()
                    
                    // Account actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account Actions")
                            .font(.system(size: 16, weight: .semibold))
                        
                        VStack(spacing: 8) {
                            Button("Manage Subscription") {
                                // Open subscription management
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Button("Export Data") {
                                // Export user data
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Button("Sign Out") {
                                signOut()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                // Not logged in state
                VStack(alignment: .leading, spacing: 20) {
                    // Get Started section
                    HStack(spacing: 16) {
                        // App logo
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.blue.gradient)
                            .frame(width: 64, height: 64)
                            .overlay(
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                            )
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Get Started")
                                .font(.system(size: 20, weight: .bold))
                            Text("Sign in to sync your data, access Pro features, and unlock unlimited AI queries.")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Sign in buttons
                    HStack(spacing: 12) {
                        Button("Sign Up") {
                            showLoginSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Log In") {
                            showLoginSheet = true
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Divider()
                    
                    // Pro features preview
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pro Features")
                            .font(.system(size: 16, weight: .semibold))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            AccountFeatureRow(
                                icon: "cloud.fill",
                                title: "Cloud Sync",
                                description: "Sync your data across devices",
                                isPro: true
                            )
                            
                            AccountFeatureRow(
                                icon: "infinity",
                                title: "Unlimited AI Queries",
                                description: "No limits on AI responses",
                                isPro: true
                            )
                            
                            AccountFeatureRow(
                                icon: "bolt.fill",
                                title: "Priority Processing",
                                description: "Faster indexing and responses",
                                isPro: true
                            )
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginSheetView(isLoggedIn: $isLoggedIn, userName: $userName, userEmail: $userEmail)
        }
        .onAppear {
            loadUserData()
        }
    }
    
    private func loadUserData() {
        // Load user data from UserDefaults or keychain
        userName = UserDefaults.standard.string(forKey: "userName") ?? ""
        userEmail = UserDefaults.standard.string(forKey: "userEmail") ?? ""
        isLoggedIn = !userName.isEmpty && !userEmail.isEmpty
    }
    
    private func signOut() {
        UserDefaults.standard.removeObject(forKey: "userName")
        UserDefaults.standard.removeObject(forKey: "userEmail")
        userName = ""
        userEmail = ""
        isLoggedIn = false
    }
}

struct AccountFeatureRow: View {
    let icon: String
    let title: String
    let description: String
    let isPro: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.blue)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    if isPro {
                        Text("Pro")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct LoginSheetView: View {
    @Binding var isLoggedIn: Bool
    @Binding var userName: String
    @Binding var userEmail: String
    @Environment(\.dismiss) private var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text(isSignUp ? "Create Account" : "Sign In")
                    .font(.system(size: 24, weight: .bold))
                
                Text(isSignUp ? "Create your Smart Light account" : "Welcome back to Smart Light")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            
            // Form
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email")
                        .font(.system(size: 14, weight: .medium))
                    TextField("Enter your email", text: $email)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.system(size: 14, weight: .medium))
                    SecureField("Enter your password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            // Buttons
            VStack(spacing: 12) {
                Button(isSignUp ? "Create Account" : "Sign In") {
                    handleAuth()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || email.isEmpty || password.isEmpty)
                
                Button(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up") {
                    isSignUp.toggle()
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
            
            Spacer()
        }
        .padding(24)
        .frame(width: 400, height: 300)
    }
    
    private func handleAuth() {
        isLoading = true
        
        // Simulate authentication
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // For demo purposes, always succeed
            userName = email.components(separatedBy: "@").first ?? "User"
            userEmail = email
            
            UserDefaults.standard.set(userName, forKey: "userName")
            UserDefaults.standard.set(userEmail, forKey: "userEmail")
            
            isLoggedIn = true
            isLoading = false
            dismiss()
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("About")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    // App icon placeholder
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.blue.gradient)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smart Light")
                            .font(.system(size: 20, weight: .bold))
                        Text("Version 1.0.0")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Text("AI-powered document search and chat")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Features")
                        .font(.system(size: 16, weight: .semibold))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        FeatureRow(icon: "doc.text.magnifyingglass", text: "Document indexing and search")
                        FeatureRow(icon: "brain.head.profile", text: "AI-powered responses")
                        FeatureRow(icon: "folder.fill", text: "Multiple file format support")
                        FeatureRow(icon: "bolt.fill", text: "Fast and efficient indexing")
                    }
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.blue)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let description: String
    let content: () -> Content
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            content()
        }
        .padding(.vertical, 8)
    }
}

