//
//  MarkdownConverterApp.swift
//  MarkdownConverter
//
//  Created by Neo Aplin on 2/9/2025.
//

import SwiftUI
import AppKit
import HotKey  // You'll need to add this SPM package


@main
struct MarkdownConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window for this utility. A Settings scene can be added later.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let converter = ClipboardMarkdownConverter()
    private var markdownHotKey: HotKey?
    private var richTextHotKey: HotKey?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {  // <- Change this name
                image.isTemplate = true // This makes it adapt to light/dark mode
                button.image = image
            } else {
                button.title = "MD"  // Fallback if image not found
            }
            button.toolTip = "Convert clipboard to Markdown"
        }
        
        // Build the menu
        let menu = NSMenu()

        let convertItem = NSMenuItem(
            title: "Convert to Markdown",
            action: #selector(convertNow),
            keyEquivalent: "M"
        )
        convertItem.target = self
        menu.addItem(convertItem)

        let convertToRichTextItem = NSMenuItem(
            title: "Convert to Rich Text",
            action: #selector(convertToRichText),
            keyEquivalent: "R"
        )
        convertToRichTextItem.target = self
        menu.addItem(convertToRichTextItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        
        // Register global hotkeys
        setupGlobalHotkeys()
    }

    private func setupGlobalHotkeys() {
        // Command+Shift+M for Markdown
        markdownHotKey = HotKey(key: .m, modifiers: [.command, .shift])
        markdownHotKey?.keyDownHandler = { [weak self] in
            self?.convertNow()
        }
        
        // Command+Shift+R for Rich Text
        richTextHotKey = HotKey(key: .r, modifiers: [.command, .shift])
        richTextHotKey?.keyDownHandler = { [weak self] in
            self?.convertToRichText()
        }
    }
    
    
    @objc private func convertNow() {
        print("Starting conversion...")
        converter.convertClipboardToMarkdown { result in
            switch result {
            case .success:
                print("Conversion successful!")
                // You could add a subtle notification here if desired
                break
            case .failure(let error):
                print("Conversion failed: \(error)")
                Self.showBriefAlert(
                    title: "Couldn't convert clipboard",
                    message: error.localizedDescription
                )
            }
        }
    }
    
    @objc private func convertToRichText() {
        print("Starting Markdown to RTF conversion...")
        converter.convertClipboardMarkdownToRTF { result in
            switch result {
            case .success:
                print("Markdown to RTF conversion successful!")
                break
            case .failure(let error):
                print("Markdown to RTF conversion failed: \(error)")
                Self.showBriefAlert(
                    title: "Couldn't convert to Rich Text",
                    message: error.localizedDescription
                )
            }
        }
    }
    private static func showBriefAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            // Ensure the alert appears for a UIElement app
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
