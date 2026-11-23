import SwiftUI
import AppKit
import Highlightr

struct MarkdownView: View {
    let text: String
    var showsCodeLineNumbers = false
    var textFont: Font = .system(size: 12)
    var codeFontSize: CGFloat = 12
    var usesSystemCodeFont = false
    
    private static let summaryRegex = try! NSRegularExpression(pattern: "<summary>([^<]*)</summary>", options: [])
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parseContent(text), id: \.id) { segment in
                switch segment.type {
                case .text:
                    Text(LocalizedStringKey(segment.content))
                        .font(textFont)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                case .code(let language):
                    CodeBlockView(
                        code: segment.content,
                        language: language,
                        showsLineNumbers: showsCodeLineNumbers,
                        fontSize: codeFontSize,
                        usesSystemFont: usesSystemCodeFont
                    )
                case .thinking(let title):
                    ThinkingBlockView(title: title, content: segment.content, textFont: textFont)
                }
            }
        }
    }
    
    private enum SegmentType {
        case text
        case code(language: String?)
        case thinking(title: String)
    }
    
    private struct ContentSegment: Identifiable {
        let id = UUID()
        let type: SegmentType
        let content: String
    }
    
    private func parseContent(_ input: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        let lines = input.components(separatedBy: .newlines)
        
        var currentText = ""
        var currentCode = ""
        var currentThinking = ""
        var isInsideCodeBlock = false
        var isInsideThinkingBlock = false
        var currentLanguage: String? = nil
        var currentThinkingTitle = "Thinking Process"
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Check for code blocks
            if trimmedLine.hasPrefix("```") && !isInsideThinkingBlock {
                if isInsideCodeBlock {
                    // End of code block
                    segments.append(ContentSegment(type: .code(language: currentLanguage), content: currentCode.trimmingCharacters(in: .newlines)))
                    currentCode = ""
                    isInsideCodeBlock = false
                    currentLanguage = nil
                } else {
                    // Start of code block
                    let textToSave = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !textToSave.isEmpty {
                        segments.append(ContentSegment(type: .text, content: textToSave))
                        currentText = ""
                    }
                    isInsideCodeBlock = true
                    let lang = trimmedLine.replacingOccurrences(of: "```", with: "")
                    currentLanguage = lang.isEmpty ? nil : lang
                }
                continue
            }
            
            // Check for thinking blocks
            if !isInsideCodeBlock {
                if trimmedLine == "<details>" || trimmedLine == "<think>" || trimmedLine.hasPrefix("<details>") {
                    let textToSave = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !textToSave.isEmpty {
                        segments.append(ContentSegment(type: .text, content: textToSave))
                        currentText = ""
                    }
                    isInsideThinkingBlock = true
                    currentThinkingTitle = "Thinking Process"
                    
                    // Try to extract inline summary if it exists on the same line
                    if let match = Self.summaryRegex.firstMatch(in: trimmedLine, range: NSRange(trimmedLine.startIndex..., in: trimmedLine)) {
                        if let range = Range(match.range(at: 1), in: trimmedLine) {
                            let title = String(trimmedLine[range])
                            if !title.isEmpty {
                                currentThinkingTitle = title
                            }
                        }
                    }
                    continue
                }
                
                if isInsideThinkingBlock && (trimmedLine == "</details>" || trimmedLine == "</think>") {
                    segments.append(ContentSegment(type: .thinking(title: currentThinkingTitle), content: currentThinking.trimmingCharacters(in: .newlines)))
                    currentThinking = ""
                    isInsideThinkingBlock = false
                    continue
                }
                
                if isInsideThinkingBlock && trimmedLine.hasPrefix("<summary>") && trimmedLine.hasSuffix("</summary>") {
                    let title = trimmedLine.replacingOccurrences(of: "<summary>", with: "").replacingOccurrences(of: "</summary>", with: "")
                    if !title.isEmpty {
                        currentThinkingTitle = title
                    }
                    continue
                }
            }
            
            // Append line to active block
            if isInsideCodeBlock {
                currentCode += line + "\n"
            } else if isInsideThinkingBlock {
                currentThinking += line + "\n"
            } else {
                currentText += line + "\n"
            }
        }
        
        // Handle unclosed blocks at the end of the text
        if isInsideCodeBlock {
            segments.append(ContentSegment(type: .code(language: currentLanguage), content: currentCode.trimmingCharacters(in: .newlines)))
        } else if isInsideThinkingBlock {
            segments.append(ContentSegment(type: .thinking(title: currentThinkingTitle), content: currentThinking.trimmingCharacters(in: .newlines)))
        } else {
            let textToSave = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !textToSave.isEmpty {
                segments.append(ContentSegment(type: .text, content: textToSave))
            }
        }
        
        return segments
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?
    var showsLineNumbers = false
    var fontSize: CGFloat = 12
    var usesSystemFont = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language = language {
                HStack {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        showCopiedFeedback()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .help(copied ? "Copied" : "Copy code")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.1))
            }
            
            HStack(alignment: .top, spacing: 0) {
                if showsLineNumbers {
                    Text(lineNumberText)
                        .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .lineSpacing(0)
                        .padding(.vertical, 12)
                        .padding(.leading, 10)
                        .padding(.trailing, 8)
                        .frame(minWidth: lineNumberColumnWidth, alignment: .trailing)
                        .textSelection(.disabled)

                    Rectangle()
                        .fill(Color.gray.opacity(0.16))
                        .frame(width: 1)
                        .padding(.vertical, 8)
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(highlightedCode)
                        .padding(12)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.black.opacity(0.03))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func showCopiedFeedback() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
    
    private var highlightedCode: AttributedString {
        let isDark = colorScheme == .dark
        return HighlightrUtility.highlight(
            code: code,
            language: language,
            isDark: isDark,
            fontSize: fontSize,
            usesSystemFont: usesSystemFont
        )
    }

    private var lineCount: Int {
        max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var lineNumberText: String {
        (1...lineCount).map(String.init).joined(separator: "\n")
    }

    private var lineNumberColumnWidth: CGFloat {
        CGFloat(String(lineCount).count * 8 + 18)
    }
}

struct HighlightrUtility {
    private static let highlightr = Highlightr()
    
    static func highlight(
        code: String,
        language: String?,
        isDark: Bool,
        fontSize: CGFloat = 13,
        usesSystemFont: Bool = false
    ) -> AttributedString {
        guard let highlightr = highlightr else {
            return fallbackHighlight(code: code, fontSize: fontSize, usesSystemFont: usesSystemFont)
        }
        
        let themeName = isDark ? "atom-one-dark" : "xcode"
        highlightr.setTheme(to: themeName)
        
        let lang = language?.lowercased()
        
        if let nsString = highlightr.highlight(code, as: lang) {
            // Highlightr returns an NSAttributedString with a smaller default font.
            // We can bump up the font size for better readability if desired.
            let mutable = NSMutableAttributedString(attributedString: nsString)
            let fullRange = NSRange(location: 0, length: mutable.length)
            
            // Apply a nice monospaced font
            let font = usesSystemFont
                ? NSFont.systemFont(ofSize: fontSize)
                : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            mutable.addAttribute(.font, value: font, range: fullRange)
            
            return (try? AttributedString(mutable, including: \.appKit)) ?? fallbackHighlight(code: code, fontSize: fontSize, usesSystemFont: usesSystemFont)
        }
        
        return fallbackHighlight(code: code, fontSize: fontSize, usesSystemFont: usesSystemFont)
    }
    
    private static func fallbackHighlight(code: String, fontSize: CGFloat, usesSystemFont: Bool) -> AttributedString {
        var attrStr = AttributedString(code)
        attrStr.font = usesSystemFont
            ? .system(size: fontSize, weight: .regular)
            : .system(size: fontSize, weight: .regular, design: .monospaced)
        return attrStr
    }
}

struct ThinkingBlockView: View {
    let title: String
    let content: String
    let textFont: Font
    @State private var isExpanded = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(LocalizedStringKey(content))
                .font(textFont)
                .lineSpacing(4)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
