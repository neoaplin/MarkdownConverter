//
//  ClipboardMarkdownConverter.swift
//  MarkdownConverter
//
//  Created by Neo Aplin on 2/9/2025.
//

import Foundation
import AppKit
import WebKit

enum ConversionError: LocalizedError {
    case noSupportedClipboardItem
    case failedToReadClipboard
    case failedToConvert
    case turndownNotLoaded
    case webViewInitialisation
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .noSupportedClipboardItem: return "Clipboard does not contain text or rich text."
        case .failedToReadClipboard:    return "Couldn't read the clipboard."
        case .failedToConvert:          return "HTML to Markdown conversion failed."
        case .turndownNotLoaded:        return "Turndown could not be loaded."
        case .webViewInitialisation:    return "Conversion engine not initialised."
        case .resourceMissing(let n):   return "Missing resource: \(n)"
        }
    }
}

final class ClipboardMarkdownConverter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var ready = false
    private var initializationRetries = 0
    private let maxRetries = 3

    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        print("Setting up WebView...")
        
        // Load turndown.js from bundle
        guard let turndownPath = Bundle.main.path(forResource: "turndown", ofType: "js"),
              let turndownSource = try? String(contentsOfFile: turndownPath, encoding: .utf8) else {
            print("ERROR: Could not load turndown.js from bundle")
            return
        }
        
        print("Loaded turndown.js, size: \(turndownSource.count) characters")
        
        // Create configuration with Turndown pre-injected
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.websiteDataStore = .default() // Use default instead of nonPersistent
        
        // Prepare the user script
        let userScript = WKUserScript(
            source: """
            // Inject Turndown library
            \(turndownSource)
            
            // Initialize Turndown service
            if (typeof TurndownService !== 'undefined') {
                window.turndownService = new TurndownService({
                    headingStyle: 'atx',
                    hr: '---',
                    bulletListMarker: '-',
                    codeBlockStyle: 'fenced',
                    emDelimiter: '*',
                    strongDelimiter: '**'
                });
                
                // Add custom rules
                window.turndownService.addRule('strikethrough', {
                    filter: ['del', 's', 'strike'],
                    replacement: function (content) {
                        return '~~' + content + '~~';
                    }
                });
                
                console.log('Turndown service initialized');
            } else {
                console.error('TurndownService not found after injection');
            }
            
            // Add conversion function
            window.convertToMarkdown = function(html) {
                if (!window.turndownService) {
                    return { error: 'Turndown service not available' };
                }
                try {
                    var tempDiv = document.createElement('div');
                    tempDiv.innerHTML = html;
                    var markdown = window.turndownService.turndown(tempDiv);
                    return { success: markdown };
                } catch (e) {
                    return { error: e.toString() };
                }
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        
        config.userContentController.addUserScript(userScript)
        
        // Create a hidden window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], // Use standard window style
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderOut(nil) // Hide but keep in memory
        
        // Create WebView
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        
        // Add to window
        window.contentView?.addSubview(webView)
        
        // Load a minimal HTML page
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Converter</title>
        </head>
        <body>
            <p>Markdown Converter Ready</p>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
    }
    
    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("WebView finished loading")
        checkIfReady()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebView navigation failed: \(error)")
        retryInitialization()
    }
    
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("WebView process terminated")
        ready = false
        retryInitialization()
    }
    
    private func retryInitialization() {
        initializationRetries += 1
        if initializationRetries < maxRetries {
            print("Retrying WebView initialization (attempt \(initializationRetries + 1)/\(maxRetries))...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.webView.reload()
            }
        } else {
            print("Failed to initialize WebView after \(maxRetries) attempts")
        }
    }
    
    private func checkIfReady() {
        // Test if Turndown is available
        let testJS = "typeof window.convertToMarkdown === 'function' ? 'ready' : 'not ready'"
        
        webView.evaluateJavaScript(testJS) { [weak self] result, error in
            if let status = result as? String, status == "ready" {
                print("Turndown is ready!")
                self?.ready = true
                self?.initializationRetries = 0
            } else {
                print("Turndown check failed: \(String(describing: result)), error: \(String(describing: error))")
                self?.retryInitialization()
            }
        }
    }
    
    // Public API
    func convertClipboardToMarkdown(completion: @escaping (Result<Void, Error>) -> Void) {
        print("\n=== Starting clipboard conversion ===")
        
        guard ready else {
            print("WebView not ready")
            completion(.failure(ConversionError.webViewInitialisation))
            return
        }
        
        guard let items = NSPasteboard.general.pasteboardItems, !items.isEmpty else {
            print("No pasteboard items found")
            completion(.failure(ConversionError.failedToReadClipboard))
            return
        }
        
        print("Found \(items.count) pasteboard items")
        
        // List available types for debugging
        for (index, item) in items.enumerated() {
            let types = item.types.map { $0.rawValue }
            print("Item \(index) types: \(types)")
        }
        
        // Try HTML first
        if let html = readHTML(from: items) {
            print("Found HTML content:")
            print("First 500 chars: \(String(html.prefix(500)))")
            print("Total HTML length: \(html.count)")
            
            convertHTMLToMarkdown(html) { [weak self] result in
                switch result {
                case .success(let markdown):
                    print("Conversion successful!")
                    print("Markdown preview: \(String(markdown.prefix(200)))")
                    self?.writeMarkdownToPasteboard(markdown)
                    completion(.success(()))
                case .failure(let error):
                    print("Conversion failed: \(error)")
                    completion(.failure(error))
                }
            }
            return
        }
        
        // Try RTF
        if let rtfHTML = readRTFasHTML(from: items) {
            print("Found RTF content, converting to HTML...")
            print("HTML from RTF length: \(rtfHTML.count)")
            
            convertHTMLToMarkdown(rtfHTML) { [weak self] result in
                switch result {
                case .success(let markdown):
                    print("RTF conversion successful!")
                    self?.writeMarkdownToPasteboard(markdown)
                    completion(.success(()))
                case .failure(let error):
                    print("RTF conversion failed: \(error)")
                    completion(.failure(error))
                }
            }
            return
        }
        
        // Fall back to plain text
        if let text = readPlain(from: items) {
            print("Only plain text found, using as-is")
            print("Text preview: \(String(text.prefix(200)))")
            writeMarkdownToPasteboard(text)
            completion(.success(()))
            return
        }
        
        print("No supported content type found")
        completion(.failure(ConversionError.noSupportedClipboardItem))
    }
    
    private func convertHTMLToMarkdown(_ html: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Clean the HTML
        let cleanHTML = sanitiseHTML(html)
        
        // Properly escape the HTML for JavaScript
        let escaped = cleanHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        
        let js = "window.convertToMarkdown(\"\(escaped)\")"
        
        print("Executing conversion JavaScript...")
        
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("JavaScript error: \(error)")
                completion(.failure(error))
                return
            }
            
            if let dict = result as? [String: Any] {
                if let markdown = dict["success"] as? String {
                    print("Successfully converted to markdown (length: \(markdown.count))")
                    completion(.success(markdown))
                } else if let errorMsg = dict["error"] as? String {
                    print("Conversion error: \(errorMsg)")
                    completion(.failure(ConversionError.failedToConvert))
                } else {
                    print("Unexpected result format: \(dict)")
                    completion(.failure(ConversionError.failedToConvert))
                }
            } else {
                print("Unexpected result type: \(String(describing: result))")
                completion(.failure(ConversionError.failedToConvert))
            }
        }
    }
    
    private func writeMarkdownToPasteboard(_ markdown: String) {
        print("\n=== Writing to pasteboard ===")
        print("Markdown length: \(markdown.count)")
        
        // Get current clipboard content for comparison
        if let currentItems = NSPasteboard.general.pasteboardItems?.first {
            print("Current clipboard types before: \(currentItems.types.map { $0.rawValue })")
        }
        
        let pb = NSPasteboard.general
        pb.clearContents()
        
        // Write both plain text and markdown UTI
        let written1 = pb.setString(markdown, forType: .string)
        let written2 = pb.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
        
        print("Write results: string=\(written1), markdown=\(written2)")
        
        // Verify what was written
        if let newItems = NSPasteboard.general.pasteboardItems?.first {
            print("New clipboard types after: \(newItems.types.map { $0.rawValue })")
            if let verifyText = newItems.string(forType: .string) {
                print("Verified text on clipboard (first 100 chars): \(String(verifyText.prefix(100)))")
            }
        }
        
        print("✓ Markdown written to clipboard")
    }
    
    // Pasteboard helpers
    private func readHTML(from items: [NSPasteboardItem]) -> String? {
        for item in items {
            if let html = item.string(forType: .html),
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return html
            }
        }
        return nil
    }
    
    private func readRTFasHTML(from items: [NSPasteboardItem]) -> String? {
        for item in items {
            if let rtfData = item.data(forType: .rtf) {
                do {
                    let attributed = try NSAttributedString(
                        data: rtfData,
                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil
                    )
                    
                    let htmlData = try attributed.data(
                        from: NSRange(location: 0, length: attributed.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
                    )
                    
                    if let html = String(data: htmlData, encoding: .utf8) {
                        return html
                    }
                } catch {
                    print("RTF conversion error: \(error)")
                }
            }
        }
        return nil
    }
    
    private func readPlain(from items: [NSPasteboardItem]) -> String? {
        for item in items {
            if let text = item.string(forType: .string), !text.isEmpty {
                return text
            }
        }
        return nil
    }
    
    private func sanitiseHTML(_ html: String) -> String {
        var cleaned = html
        
        // Remove comments
        cleaned = cleaned.replacingOccurrences(
            of: #"<!--[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )
        
        // Remove script and style tags
        cleaned = cleaned.replacingOccurrences(
            of: #"<(script|style)[\s\S]*?</\1>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Remove meta tags
        cleaned = cleaned.replacingOccurrences(
            of: #"<meta[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        return cleaned
    }
    // Public API for Markdown to RTF conversion
    func convertClipboardMarkdownToRTF(completion: @escaping (Result<Void, Error>) -> Void) {
        print("\n=== Starting Markdown to RTF conversion ===")
        
        guard let items = NSPasteboard.general.pasteboardItems, !items.isEmpty else {
            print("No pasteboard items found")
            completion(.failure(ConversionError.failedToReadClipboard))
            return
        }
        
        // Read markdown/plain text from clipboard
        guard let markdown = readPlain(from: items) else {
            print("No text found in clipboard")
            completion(.failure(ConversionError.noSupportedClipboardItem))
            return
        }
        
        print("Found markdown text: \(markdown.prefix(200))...")
        
        // Convert Markdown to HTML first
        let html = convertMarkdownToHTML(markdown)
        print("Converted to HTML, now converting to RTF...")
        writeRTFToPasteboard(html: html)
        completion(.success(()))
    }

    
    // Convert Markdown to HTML using basic patterns (synchronous)
    private func convertMarkdownToHTML(_ markdown: String) -> String {
        var html = markdown
        
        // Headers - preserve line breaks after headers
        html = html.replacingOccurrences(
            of: #"(?m)^### (.+)$"#,
            with: "<h3>$1</h3>\n",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"(?m)^## (.+)$"#,
            with: "<h2>$1</h2>\n",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"(?m)^# (.+)$"#,
            with: "<h1>$1</h1>\n",
            options: .regularExpression
        )
        
        // Bold and italic (keep as is)
        html = html.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"\*(.+?)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        
        // Links (keep as is)
        html = html.replacingOccurrences(
            of: #"\[(.+?)\]\((.+?)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )
        
        // Process line by line
        let lines = html.components(separatedBy: "\n")
        var processedLines: [String] = []
        var inUnorderedList = false
        var inOrderedList = false
        
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Unordered list items
            if trimmedLine.hasPrefix("- ") {
                if !inUnorderedList {
                    processedLines.append("<ul>")
                    inUnorderedList = true
                }
                let content = String(trimmedLine.dropFirst(2))
                processedLines.append("  <li>\(content)</li>")
            }
            // Ordered list items
            else if trimmedLine.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                if !inOrderedList {
                    processedLines.append("<ol>")
                    inOrderedList = true
                }
                let content = trimmedLine.replacingOccurrences(
                    of: #"^\d+\. "#,
                    with: "",
                    options: .regularExpression
                )
                processedLines.append("  <li>\(content)</li>")
            }
            // Empty lines - preserve them!
            else if trimmedLine.isEmpty {
                // Close any open lists
                if inUnorderedList {
                    processedLines.append("</ul>")
                    inUnorderedList = false
                }
                if inOrderedList {
                    processedLines.append("</ol>")
                    inOrderedList = false
                }
                // Add a paragraph break to maintain separation
                processedLines.append("<p>&nbsp;</p>")  // This preserves the empty line
            }
            // Regular content
            else {
                // Close any open lists
                if inUnorderedList {
                    processedLines.append("</ul>")
                    inUnorderedList = false
                }
                if inOrderedList {
                    processedLines.append("</ol>")
                    inOrderedList = false
                }
                
                // Add as paragraph if not already HTML
                if !trimmedLine.hasPrefix("<") {
                    processedLines.append("<p>\(trimmedLine)</p>")
                } else {
                    processedLines.append(trimmedLine)
                }
            }
        }
        
        // Close any remaining open lists
        if inUnorderedList {
            processedLines.append("</ul>")
        }
        if inOrderedList {
            processedLines.append("</ol>")
        }
        
        html = processedLines.joined(separator: "\n")
        
        // Wrap in basic HTML structure
        html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
                ul, ol { margin: 0.5em 0; }
                p { margin: 0.5em 0; }
            </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
        
        return html
    }

    // Write RTF to pasteboard
    private func writeRTFToPasteboard(html: String) {
        guard let htmlData = html.data(using: .utf8) else {
            print("Failed to convert HTML to data")
            return
        }
        
        do {
            let attributed = try NSAttributedString(
                data: htmlData,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            
            let rtfData = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(rtfData, forType: .rtf)
            
            // Also set the plain text version
            pb.setString(attributed.string, forType: .string)
            
            print("✓ RTF written to clipboard")
            
        } catch {
            print("Failed to convert to RTF: \(error)")
        }
    }
    
}
