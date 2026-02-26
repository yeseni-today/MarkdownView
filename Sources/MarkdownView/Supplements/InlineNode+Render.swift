//
//  InlineNode+Render.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2025/1/3.
//

import Foundation
import Litext
import MarkdownParser
import SwiftMath
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

extension [MarkdownInlineNode] {
    func render(theme: MarkdownTheme, context: MarkdownTextView.PreprocessedContent, viewProvider: ReusableViewProvider) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for node in self {
            result.append(node.render(theme: theme, context: context, viewProvider: viewProvider))
        }
        return result
    }
}

private final class LTXInlineMathAttachment: LTXAttachment {
    private let attrString: NSAttributedString
    private let fixedAscent: CGFloat?
    private let fixedDescent: CGFloat?
    private var fixedRunDelegate: CTRunDelegate?

    init(
        attrString: NSAttributedString,
        fixedAscent: CGFloat? = nil,
        fixedDescent: CGFloat? = nil
    ) {
        self.attrString = attrString
        self.fixedAscent = fixedAscent
        self.fixedDescent = fixedDescent
        super.init()
    }

    override func attributedStringRepresentation() -> NSAttributedString {
        attrString
    }

    override var runDelegate: CTRunDelegate {
        guard let fixedAscent, let fixedDescent else {
            return super.runDelegate
        }
        if fixedRunDelegate == nil {
            var callbacks = CTRunDelegateCallbacks(
                version: kCTRunDelegateVersion1,
                dealloc: { _ in },
                getAscent: { refCon in
                    let attachment = Unmanaged<LTXInlineMathAttachment>.fromOpaque(refCon).takeUnretainedValue()
                    return attachment.fixedAscent ?? attachment.size.height * 0.9
                },
                getDescent: { refCon in
                    let attachment = Unmanaged<LTXInlineMathAttachment>.fromOpaque(refCon).takeUnretainedValue()
                    return attachment.fixedDescent ?? attachment.size.height * 0.1
                },
                getWidth: { refCon in
                    let attachment = Unmanaged<LTXInlineMathAttachment>.fromOpaque(refCon).takeUnretainedValue()
                    return attachment.size.width
                }
            )

            let unmanagedSelf = Unmanaged.passUnretained(self)
            fixedRunDelegate = CTRunDelegateCreate(&callbacks, unmanagedSelf.toOpaque())
        }
        return fixedRunDelegate!
    }
}

extension MarkdownInlineNode {
    func render(theme: MarkdownTheme, context: MarkdownTextView.PreprocessedContent, viewProvider: ReusableViewProvider) -> NSAttributedString {
        assert(Thread.isMainThread)
        switch self {
        case let .text(string):
            return NSMutableAttributedString(
                string: string,
                attributes: [
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ]
            )
        case .softBreak:
            return NSAttributedString(string: " ", attributes: [
                .font: theme.fonts.body,
                .foregroundColor: theme.colors.body,
            ])
        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: [
                .font: theme.fonts.body,
                .foregroundColor: theme.colors.body,
            ])
        case let .code(string), let .html(string):
            let controlAttributes: [NSAttributedString.Key: Any] = [
                .font: theme.fonts.codeInline,
                .backgroundColor: theme.colors.codeBackground.withAlphaComponent(0.05),
            ]
            let text = NSMutableAttributedString(string: string, attributes: [.foregroundColor: theme.colors.code])
            text.addAttributes(controlAttributes, range: .init(location: 0, length: text.length))
            return text
        case let .emphasis(children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: theme.colors.emphasis,
                ],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .strong(children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [.font: theme.fonts.bold],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .strikethrough(children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [.strikethroughStyle: NSUnderlineStyle.thick.rawValue],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .link(destination, children):
            let ans = NSMutableAttributedString()
            children.map { $0.render(theme: theme, context: context, viewProvider: viewProvider) }.forEach { ans.append($0) }
            ans.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: theme.colors.highlight,
                ],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .image(source, _): // children => alternative text can be ignored?
            return NSAttributedString(
                string: source,
                attributes: [
                    .link: source,
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ]
            )
        case let .math(content, replacementIdentifier):
            // Get LaTeX content from rendered context or fallback to raw content
            let latexContent = context.rendered[replacementIdentifier]?.text ?? content
            let inlineMathVerticalAlignment = theme.inlineMathVerticalAlignment

            if let item = context.rendered[replacementIdentifier], let image = item.image {
                var imageSize = image.size

                let drawingCallback = LTXLineDrawingAction { context, line, lineOrigin in
                    let glyphRuns = CTLineGetGlyphRuns(line) as NSArray
                    var runOffsetX: CGFloat = 0
                    var targetRun: CTRun?
                    for i in 0 ..< glyphRuns.count {
                        let run = glyphRuns[i] as! CTRun
                        let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                        if attributes[.contextIdentifier] as? String == replacementIdentifier {
                            targetRun = run
                            break
                        }
                        runOffsetX += CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
                    }

                    guard let targetRun else { return }

                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    CTLineGetTypographicBounds(line, &ascent, &descent, nil)

                    var drawY = lineOrigin.y
                    switch inlineMathVerticalAlignment {
                    case .bottom:
                        if imageSize.height > ascent { // we only draw above the line
                            let newWidth = imageSize.width * (ascent / imageSize.height)
                            imageSize = CGSize(width: newWidth, height: ascent)
                        }
                    case .center:
                        var runAscent: CGFloat = 0
                        var runDescent: CGFloat = 0
                        _ = CTRunGetTypographicBounds(targetRun, CFRange(location: 0, length: 0), &runAscent, &runDescent, nil)
                        drawY = lineOrigin.y - runDescent
                    }

                    let rect = CGRect(
                        x: lineOrigin.x + runOffsetX,
                        y: drawY,
                        width: imageSize.width,
                        height: imageSize.height
                    )

                    context.saveGState()

                    #if canImport(UIKit)
                        context.translateBy(x: 0, y: rect.origin.y + rect.size.height)
                        context.scaleBy(x: 1, y: -1)
                        context.translateBy(x: 0, y: -rect.origin.y)
                        image.draw(in: rect)
                    #else
                        assert(image.isTemplate)
                        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            // Resolve label color at draw time for dynamic appearance updates
                            let labelColor = NSColor.labelColor.cgColor
                            context.clip(to: rect, mask: cgImage)
                            context.setFillColor(labelColor)
                            context.fill(rect)
                        } else {
                            assertionFailure()
                        }
                    #endif

                    context.restoreGState()
                }
                let attachment: LTXAttachment
                switch inlineMathVerticalAlignment {
                case .bottom:
                    attachment = LTXAttachment.hold(attrString: .init(string: latexContent))
                case .center:
                    let textAscent = max(theme.fonts.body.ascender, 0)
                    let textDescent = max(-theme.fonts.body.descender, 0)
                    let textCenterOffset = (textAscent - textDescent) * 0.5

                    let halfHeight = imageSize.height * 0.5
                    var attachmentAscent = halfHeight + textCenterOffset
                    attachmentAscent = min(max(0, attachmentAscent), imageSize.height)
                    let attachmentDescent = imageSize.height - attachmentAscent

                    attachment = LTXInlineMathAttachment(
                        attrString: .init(string: latexContent),
                        fixedAscent: attachmentAscent,
                        fixedDescent: attachmentDescent
                    )
                }
                attachment.size = imageSize

                let attributes: [NSAttributedString.Key: Any] = [
                    LTXAttachmentAttributeName: attachment,
                    LTXLineDrawingCallbackName: drawingCallback,
                    kCTRunDelegateAttributeName as NSAttributedString.Key: attachment.runDelegate,
                    .contextIdentifier: replacementIdentifier,
                    .mathLatexContent: latexContent, // Store LaTeX content for on-demand rendering
                ]

                return NSAttributedString(
                    string: LTXReplacementText,
                    attributes: attributes
                )
            } else {
                // Fallback: render failed, show original LaTeX as inline code
                return NSAttributedString(
                    string: latexContent,
                    attributes: [
                        .font: theme.fonts.codeInline,
                        .foregroundColor: theme.colors.code,
                        .backgroundColor: theme.colors.codeBackground.withAlphaComponent(0.05),
                    ]
                )
            }
        }
    }
}
