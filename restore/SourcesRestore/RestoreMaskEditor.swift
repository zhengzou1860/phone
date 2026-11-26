import SwiftUI
import UIKit
import ImageIO

enum RestoreMaskTool {
    case paint
    case erase
}

struct RestoreMaskEditor: View {
    @Binding var mask: RestoreMask
    let imageURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var tool: RestoreMaskTool = .paint
    @State private var brushSize: Double = 0.04
    @State private var redoStack: [RestoreMask] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("在破损、划痕或缺失区域涂抹。只修补选中的位置，其余画面保持不变。")
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)

                MaskCanvasUIView(image: image, mask: mask, tool: tool, brushSize: brushSize) { updated in
                    redoStack.removeAll()
                    mask = updated
                }
                .frame(height: 430)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RestoreTheme.stroke, lineWidth: 1)
                )

                Picker("蒙版工具", selection: $tool) {
                    Label("涂抹", systemImage: "paintbrush.fill").tag(RestoreMaskTool.paint)
                    Label("擦除", systemImage: "eraser.fill").tag(RestoreMaskTool.erase)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("画笔大小").font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(Int(brushSize * 100))%").font(.caption.monospacedDigit()).foregroundStyle(RestoreTheme.secondary)
                    }
                    Slider(value: $brushSize, in: 0.01...0.18)
                }

                HStack(spacing: 10) {
                    Button {
                        redoStack.append(mask)
                        mask.removeLast()
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(mask.isEmpty)
                    Button {
                        redoStack.append(mask)
                        mask = RestoreMask()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(mask.isEmpty)
                    Spacer()
                    Button {
                        if let previous = redoStack.popLast() { mask = previous }
                    } label: {
                        Label("重做", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(redoStack.isEmpty)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(RestoreTheme.cyan)

                if !mask.isEmpty {
                    Label("已选择修补区域", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(RestoreTheme.green)
                }
            }
            .padding(18)
            .background(RestoreTheme.background.ignoresSafeArea())
            .navigationTitle("涂抹缺损区域")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(RestoreTheme.cyan)
        .interactiveDismissDisabled(false)
        .task(id: imageURL.path) {
            image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1800,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
                return UIImage(cgImage: thumbnail)
            }.value
        }
    }
}

private final class RestoreMaskCanvasPlatformView: UIView {
    var image: UIImage?
    var repairMask: RestoreMask
    var tool: RestoreMaskTool
    var brushSize: Double
    let coordinator: MaskCanvasCoordinator

    init(image: UIImage?, mask: RestoreMask, tool: RestoreMaskTool, brushSize: Double, onChange: @escaping (RestoreMask) -> Void) {
        self.image = image
        self.repairMask = mask
        self.tool = tool
        self.brushSize = brushSize
        self.coordinator = MaskCanvasCoordinator()
        super.init(frame: .zero)
        backgroundColor = RestoreTheme.background.uiColor
        isMultipleTouchEnabled = false
        coordinator.canvas = self
        coordinator.onChange = onChange
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let image, let imageRect = fittedImageRect else { return }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let overlay = UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            let context = renderer.cgContext
            let color = RestoreTheme.cyan.opacity(0.52).uiColor.cgColor
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(color)
            context.setFillColor(color)
            let scale = Double(min(image.size.width, image.size.height))
            for stroke in repairMask.sanitized().strokes {
                context.setBlendMode(stroke.erasing ? .clear : .normal)
                let lineWidth = stroke.brushSize * scale * imageRect.width / image.size.width
                context.setLineWidth(lineWidth)
                guard let first = stroke.points.first else { continue }
                let firstPoint = CGPoint(
                    x: imageRect.minX + first.x * imageRect.width,
                    y: imageRect.minY + (1 - first.y) * imageRect.height
                )
                if stroke.points.count == 1 {
                    let radius = lineWidth / 2
                    context.fillEllipse(in: CGRect(x: firstPoint.x - radius, y: firstPoint.y - radius, width: radius * 2, height: radius * 2))
                    continue
                }
                context.beginPath()
                context.move(to: firstPoint)
                for point in stroke.points.dropFirst() {
                    context.addLine(to: CGPoint(
                        x: imageRect.minX + point.x * imageRect.width,
                        y: imageRect.minY + (1 - point.y) * imageRect.height
                    ))
                }
                context.strokePath()
            }
        }
        image.draw(in: imageRect)
        overlay.draw(in: bounds)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        beginStroke(at: point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        coordinator.extendStroke(with: point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator.activeStrokeID = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        coordinator.activeStrokeID = nil
    }

    fileprivate var fittedImageRect: CGRect? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func beginStroke(at point: CGPoint) {
        guard let imageRect = fittedImageRect, imageRect.contains(point) else { return }
        let normalized = RestoreMaskPoint(
            x: Double((point.x - imageRect.minX) / imageRect.width),
            y: Double(1 - (point.y - imageRect.minY) / imageRect.height)
        ).clamped()
        let stroke = RestoreMaskStroke(points: [normalized], brushSize: brushSize, erasing: tool == .erase)
        var updated = repairMask
        updated.append(stroke)
        repairMask = updated
        coordinator.activeStrokeID = stroke.id
        coordinator.onChange(updated)
        setNeedsDisplay()
    }
}

private final class MaskCanvasCoordinator: NSObject {
    weak var canvas: RestoreMaskCanvasPlatformView?
    var onChange: (RestoreMask) -> Void = { _ in }
    var activeStrokeID: UUID?

    func extendStroke(with point: CGPoint) {
        guard let canvas, let activeStrokeID, let imageRect = canvas.fittedImageRect, imageRect.contains(point) else { return }
        let normalized = RestoreMaskPoint(
            x: Double((point.x - imageRect.minX) / imageRect.width),
            y: Double(1 - (point.y - imageRect.minY) / imageRect.height)
        ).clamped()
        guard let index = canvas.repairMask.strokes.firstIndex(where: { $0.id == activeStrokeID }) else { return }
        canvas.repairMask.strokes[index].points.append(normalized)
        onChange(canvas.repairMask)
        canvas.setNeedsDisplay()
    }
}

private struct MaskCanvasUIView: UIViewRepresentable {
    let image: UIImage?
    let mask: RestoreMask
    let tool: RestoreMaskTool
    let brushSize: Double
    let onChange: (RestoreMask) -> Void

    func makeUIView(context: Context) -> RestoreMaskCanvasPlatformView {
        let view = RestoreMaskCanvasPlatformView(image: image, mask: mask, tool: tool, brushSize: brushSize, onChange: onChange)
        return view
    }

    func updateUIView(_ uiView: RestoreMaskCanvasPlatformView, context: Context) {
        uiView.image = image
        uiView.repairMask = mask
        uiView.tool = tool
        uiView.brushSize = brushSize
        uiView.setNeedsDisplay()
    }
}

private extension Color {
    var uiColor: UIColor { UIColor(self) }
}
