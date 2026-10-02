import PDFKit
import UIKit

/// A page-at-a-time PDF writer for the reports: headings, wrapped text, key–value rows, tables,
/// pictures — and a new page whenever the next block would not fit.
///
/// Written by hand on `UIGraphicsPDFRenderer` rather than with a layout library because
/// what the reports need is small and fixed, and a report that is exactly the same on every
/// phone is worth more than a clever one.
@MainActor
final class ReportCanvas {
    static let pageSize = CGSize(width: 595.2, height: 841.8)    // A4 in points
    static let margin: CGFloat = 40

    private(set) var context: UIGraphicsPDFRendererContext
    private(set) var y: CGFloat = 0
    private(set) var pageNumber = 0
    private let footer: String

    var contentWidth: CGFloat { Self.pageSize.width - 2 * Self.margin }
    private var bottom: CGFloat { Self.pageSize.height - Self.margin - 18 }

    init(context: UIGraphicsPDFRendererContext, footer: String) {
        self.context = context
        self.footer = footer
        newPage()
    }

    /// Renders a whole document: `build` draws on the canvas it is given.
    static func render(footer: String, build: (ReportCanvas) -> Void) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize),
                                             format: pdfFormat())
        return renderer.pdfData { context in
            let canvas = ReportCanvas(context: context, footer: footer)
            build(canvas)
            canvas.drawFooter()
        }
    }

    private static func pdfFormat() -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Sensorstorm"]
        return format
    }

    func newPage() {
        if pageNumber > 0 { drawFooter() }
        context.beginPage()
        pageNumber += 1
        y = Self.margin
    }

    private func drawFooter() {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray]
        let text = "\(footer) · \(pageNumber)"
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: Self.pageSize.width - Self.margin - size.width,
                                            y: Self.pageSize.height - Self.margin + 4), withAttributes: attributes)
    }

    /// Starts a new page unless `height` still fits on this one.
    func ensure(_ height: CGFloat) {
        if y + height > bottom { newPage() }
    }

    func space(_ points: CGFloat) {
        y += points
    }

    @discardableResult
    func text(_ string: String, font: UIFont = .systemFont(ofSize: 10), color: UIColor = .black,
              indent: CGFloat = 0, width: CGFloat? = nil, after: CGFloat = 4,
              alignment: NSTextAlignment = .natural) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let available = (width ?? contentWidth) - indent
        let box = (string as NSString).boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: attributes, context: nil)
        ensure(ceil(box.height))
        (string as NSString).draw(in: CGRect(x: Self.margin + indent, y: y, width: available, height: ceil(box.height)),
                                  withAttributes: attributes)
        y += ceil(box.height) + after
        return ceil(box.height)
    }

    func title(_ string: String) {
        text(string, font: .systemFont(ofSize: 22, weight: .bold), after: 6)
    }

    func heading(_ string: String) {
        ensure(40)
        space(8)
        text(string, font: .systemFont(ofSize: 13, weight: .semibold), after: 3)
        rule()
    }

    func rule() {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: Self.margin, y: y))
        path.addLine(to: CGPoint(x: Self.pageSize.width - Self.margin, y: y))
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        y += 6
    }

    /// „Schlagloch · 7/10": two columns, the key grey and narrow.
    func row(_ key: String, _ value: String, keyWidth: CGFloat = 120) {
        let keyAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black]
        let valueWidth = contentWidth - keyWidth
        let box = (value as NSString).boundingRect(with: CGSize(width: valueWidth, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: valueAttributes, context: nil)
        let height = max(ceil(box.height), 12)
        ensure(height)
        (key as NSString).draw(in: CGRect(x: Self.margin, y: y + 1, width: keyWidth - 6, height: height), withAttributes: keyAttributes)
        (value as NSString).draw(in: CGRect(x: Self.margin + keyWidth, y: y, width: valueWidth, height: height), withAttributes: valueAttributes)
        y += height + 3
    }

    /// A table with a bold header row; columns share the width by `weights`.
    func table(header: [String], rows: [[String]], weights: [CGFloat]) {
        let total = weights.reduce(0, +)
        let widths = weights.map { $0 / total * contentWidth }
        func draw(_ cells: [String], bold: Bool) {
            let font = bold ? UIFont.systemFont(ofSize: 9, weight: .semibold) : UIFont.systemFont(ofSize: 9)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            var height: CGFloat = 12
            for (index, cell) in cells.enumerated() {
                let box = (cell as NSString).boundingRect(with: CGSize(width: widths[index] - 4, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                          attributes: attributes, context: nil)
                height = max(height, ceil(box.height))
            }
            ensure(height + 3)
            var x = Self.margin
            for (index, cell) in cells.enumerated() {
                (cell as NSString).draw(in: CGRect(x: x, y: y, width: widths[index] - 4, height: height), withAttributes: attributes)
                x += widths[index]
            }
            y += height + 3
        }
        draw(header, bold: true)
        rule()
        for cells in rows { draw(cells, bold: false) }
    }

    /// A picture, scaled down to fit the box, left-aligned.
    @discardableResult
    func image(_ image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat, after: CGFloat = 6) -> CGSize {
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        ensure(size.height)
        image.draw(in: CGRect(x: Self.margin, y: y, width: size.width, height: size.height))
        y += size.height + after
        return size
    }

    /// A picture next to a column of text, the way one case of a report is laid out.
    func imageBeside(_ image: UIImage?, width: CGFloat, height: CGFloat, build: (_ indent: CGFloat) -> Void) {
        ensure(height)
        let startY = y
        if let image {
            let scale = min(width / image.size.width, height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: Self.margin, y: startY, width: size.width, height: size.height))
        }
        build(image == nil ? 0 : width + 12)
        y = max(y, startY + height) + 4
    }
}
