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
    @State private var showSettings = false

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
                #if os(macOS)
                if #available(macOS 13.0, *) {
                    SettingsLink {
                        settingsIcon
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                } else {
                    Button {
                        #if canImport(AppKit)
                        // Try native preferences window first
                        let opened = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                        if !opened { showSettings = true }
                        #else
                        showSettings = true
                        #endif
                    } label: {
                        settingsIcon
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
                #endif
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial.opacity(0.95))
        .sheet(isPresented: $showSettings) { SettingsView() }
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

