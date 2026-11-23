import AppKit
import CoreGraphics

enum ClipboardHistoryLayout {
    static let windowSize = NSSize(width: 800, height: 520)

    static let sidebarWidth: CGFloat = 270
    static let detailWidth: CGFloat = 540
    static let searchFieldWidth: CGFloat = 9
    static let controlCornerRadius: CGFloat = 9
    static let panelStrokeOpacity: CGFloat = 0.16
    static let panelHighlightOpacity: CGFloat = 0.12
    static let panelShadowOpacity: CGFloat = 0.08
    static let controlFillOpacity: CGFloat = 0.10
    static let controlStrokeOpacity: CGFloat = 0.12
    static let sectionFillOpacity: CGFloat = 0.04
    static let sectionStrokeOpacity: CGFloat = 0.08
    static let selectedRowFillOpacity: CGFloat = 0.08
    static let hoverRowFillOpacity: CGFloat = 0.035

    static let outerHorizontalPadding: CGFloat = 16
    static let barVerticalPadding: CGFloat = 4
    static let searchFieldHorizontalPadding: CGFloat = 10
    static let searchFieldVerticalPadding: CGFloat = 4
    static let detailHorizontalPadding: CGFloat = 14
    static let detailVerticalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 2
    static let metadataVerticalPadding: CGFloat = 2
    static let metadataRowVerticalPadding: CGFloat = 6
}
