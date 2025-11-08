//
//  ContentView.swift
//  Paint
//
//  Created by Devin Sewell on 11/2/25.
//

import SwiftUI
import UIKit

// MARK: - Tool

enum ToolMode {
    case brush
    case eraser
    case bucket
    case eyedropper
    case select
}

// MARK: - Root

struct PaintAppView: View {
    @State private var pixels = Array(repeating: UInt32(0xFF000000), count: 64 * 64)
    @State private var drawColor = Color.white
    @State private var tool: ToolMode = .brush
    @State private var brushSize = 4
    @State private var selectionRect: CGRect? = nil           // in pixel coords (0...size)
    @State private var undoStack: [[UInt32]] = []
    @State private var redoStack: [[UInt32]] = []

    var body: some View {
        VStack(spacing: 8) {
            // top bar
            HStack {
                Button("Clear") {
                    pushUndo()
                    pixels = Array(repeating: 0xFF000000, count: 64 * 64)
                }
                .foregroundColor(.red)

                Spacer()

                Text("Paint App")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                HStack(spacing: 14) {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundColor(undoStack.isEmpty ? .gray : .yellow)
                        .onTapGesture { undo() }

                    Image(systemName: "arrow.uturn.forward")
                        .foregroundColor(redoStack.isEmpty ? .gray : .yellow)
                        .onTapGesture { redo() }
                }
            }
            .padding(.horizontal, 16)
            .font(.system(size: 18))

            // canvas
            PixelCanvas(
                pixels: $pixels,
                size: 64,
                drawColor: $drawColor,
                brushSize: brushSize,
                tool: tool,
                selectionRect: $selectionRect,
                onStrokeBegan: pushUndo
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .border(.gray.opacity(0.4))

            // tools
            HStack(spacing: 14) {
                ColorPicker("", selection: $drawColor)
                    .labelsHidden()

                HStack(spacing: 6) {
                    Image(systemName: "paintbrush.fill")
                        .foregroundColor(tool == .brush ? .yellow : .gray)
                        .onTapGesture { tool = .brush }

                    Image(systemName: "eraser.fill")
                        .foregroundColor(tool == .eraser ? .yellow : .gray)
                        .onTapGesture { tool = .eraser }

                    Button("-") { brushSize = max(1, brushSize - 1) }
                    Text("\(brushSize)")
                        .foregroundColor(.white)
                        .font(.system(size: 14, design: .monospaced))
                    Button("+") { brushSize = min(32, brushSize + 1) }
                }

                Image(systemName: "drop.fill")
                    .foregroundColor(tool == .bucket ? .yellow : .gray)
                    .onTapGesture { tool = .bucket }

                Image(systemName: "eyedropper")
                    .foregroundColor(tool == .eyedropper ? .yellow : .gray)
                    .onTapGesture { tool = .eyedropper }

                Image(systemName: "cursorarrow.square")
                    .foregroundColor(tool == .select ? .yellow : .gray)
                    .onTapGesture {
                        if tool == .select && selectionRect != nil {
                            selectionRect = nil
                        } else {
                            tool = .select
                        }
                    }
            }
            .font(.system(size: 20))
            .padding(.horizontal, 8)

            Spacer()
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: - Undo / Redo

    func pushUndo() {
        undoStack.append(pixels)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(pixels)
        pixels = last
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pixels)
        pixels = next
    }
}

// MARK: - PixelCanvas
// 1 finger: tools
// 2 fingers: pinch (zoom) + drag (pan), persistent

struct PixelCanvas: View {
    @Binding var pixels: [UInt32]
    var size: Int
    @Binding var drawColor: Color
    var brushSize: Int
    var tool: ToolMode
    @Binding var selectionRect: CGRect?          // pixel space
    var onStrokeBegan: (() -> Void)?

    @State private var zoom: CGFloat = 1         // current zoom
    @State private var offset: CGSize = .zero    // current pan

    // snapshot at 2-finger gesture start
    @State private var twoBaseZoom: CGFloat = 1
    @State private var twoBaseOffset: CGSize = .zero

    @State private var selectionStart: CGPoint? = nil // pixel coords

    var body: some View {
        GeometryReader { geo in
            let basePx = geo.size.width / CGFloat(size)

            ZStack {
                // pixels
                Canvas { ctx, _ in
                    let cell = basePx * zoom

                    for y in 0..<size {
                        for x in 0..<size {
                            let color = Color(from: pixels[y * size + x])

                            let sx = offset.width + CGFloat(x) * cell
                            let sy = offset.height + CGFloat(y) * cell

                            // snap rect to avoid hairlines
                            let rect = CGRect(
                                x: floor(sx),
                                y: floor(sy),
                                width: ceil(cell),
                                height: ceil(cell)
                            )

                            ctx.fill(Path(rect), with: .color(color))
                        }
                    }

                    if let r = selectionRect {
                        let cell = basePx * zoom
                        let sx = offset.width + r.origin.x * cell
                        let sy = offset.height + r.origin.y * cell
                        let sw = r.size.width * cell
                        let sh = r.size.height * cell

                        let srect = CGRect(
                            x: floor(sx),
                            y: floor(sy),
                            width: floor(sw),
                            height: floor(sh)
                        )

                        let path = Path(srect)
                        ctx.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 2)
                        ctx.fill(path, with: .color(.yellow.opacity(0.2)))
                    }
                }

                // touch handling
                TouchCatcher(
                    onSingleTouch: { point, phase in
                        handleSingleTouch(point: point, phase: phase, geo: geo, basePx: basePx)
                    },
                    onTwoFingerUpdate: { translation, scale, phase in
                        handleTwoFinger(translation: translation, scale: scale, phase: phase)
                    }
                )
            }
            .clipped()
        }
    }

    // MARK: - 1-finger

    private func handleSingleTouch(point: CGPoint, phase: UITouch.Phase, geo: GeometryProxy, basePx: CGFloat) {
        guard phase != .stationary else { return }

        if tool == .select {
            handleSelectTouch(point: point, phase: phase, geo: geo, basePx: basePx)
            return
        }

        guard let (x, y) = mapToPixel(point: point, basePx: basePx) else { return }

        switch phase {
        case .began:
            onStrokeBegan?()
            fallthrough
        case .moved:
            applyTool(atX: x, y: y)
        case .ended, .cancelled:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Selection (pixel coords)

    private func handleSelectTouch(point: CGPoint, phase: UITouch.Phase, geo: GeometryProxy, basePx: CGFloat) {
        guard let (x, y) = mapToPixel(point: point, basePx: basePx) else { return }

        switch phase {
        case .began:
            let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
            selectionStart = p
            selectionRect = CGRect(origin: p, size: .zero)

        case .moved:
            guard let start = selectionStart else { return }
            let minX = min(start.x, CGFloat(x))
            let minY = min(start.y, CGFloat(y))
            let maxX = max(start.x, CGFloat(x) + 1)
            let maxY = max(start.y, CGFloat(y) + 1)
            selectionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .ended, .cancelled:
            if let r = selectionRect, r.width < 1, r.height < 1 {
                selectionRect = nil
            }
            selectionStart = nil

        @unknown default:
            break
        }
    }

    // MARK: - Apply tool

    private func applyTool(atX x: Int, y: Int) {
        guard x >= 0, y >= 0, x < size, y < size else { return }

        let insideSel: (Int, Int) -> Bool = { xx, yy in
            guard let r = selectionRect else { return true }
            let p = CGPoint(x: CGFloat(xx) + 0.5, y: CGFloat(yy) + 0.5)
            return r.contains(p)
        }

        switch tool {
        case .eyedropper:
            drawColor = Color(from: pixels[y * size + x])

        case .bucket:
            let newColor = colorToUInt(drawColor)
            if let r = selectionRect {
                let minX = max(0, Int(floor(r.minX)))
                let minY = max(0, Int(floor(r.minY)))
                let maxX = min(size, Int(ceil(r.maxX)))
                let maxY = min(size, Int(ceil(r.maxY)))
                for yy in minY..<maxY {
                    for xx in minX..<maxX {
                        pixels[yy * size + xx] = newColor
                    }
                }
            } else {
                floodFill(&pixels, x, y, size, newColor)
            }

        case .brush, .eraser:
            let r = Double(max(1, brushSize)) / 2.0
            let cVal: UInt32 = (tool == .eraser) ? 0x00000000 : colorToUInt(drawColor)

            for yy in 0..<size {
                for xx in 0..<size {
                    if !insideSel(xx, yy) { continue }
                    let dx = Double(xx - x)
                    let dy = Double(yy - y)
                    if dx*dx + dy*dy <= r*r {
                        pixels[yy * size + xx] = cVal
                    }
                }
            }

        case .select:
            break
        }
    }

    // MARK: - 2-finger pinch + pan

    private func handleTwoFinger(
        translation: CGSize,
        scale: CGFloat,
        phase: UITouch.Phase
    ) {
        switch phase {
        case .began:
            twoBaseZoom = zoom
            twoBaseOffset = offset

        case .moved:
            let newZoom = clampZoom(twoBaseZoom * scale)
            let newOffset = CGSize(
                width: twoBaseOffset.width + translation.width,
                height: twoBaseOffset.height + translation.height
            )
            zoom = newZoom
            offset = newOffset

        case .ended, .cancelled:
            // commit last values
            let newZoom = clampZoom(twoBaseZoom * scale)
            let newOffset = CGSize(
                width: twoBaseOffset.width + translation.width,
                height: twoBaseOffset.height + translation.height
            )
            zoom = newZoom
            offset = newOffset
            twoBaseZoom = newZoom
            twoBaseOffset = newOffset

        @unknown default:
            break
        }
    }

    // MARK: - Helpers

    private func mapToPixel(point: CGPoint, basePx: CGFloat) -> (Int, Int)? {
        let cell = basePx * zoom
        guard cell > 0 else { return nil }

        let lx = point.x - offset.width
        let ly = point.y - offset.height

        let x = Int(floor(lx / cell))
        let y = Int(floor(ly / cell))

        if x < 0 || y < 0 || x >= size || y >= size { return nil }
        return (x, y)
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        let minZ: CGFloat = 1
        let maxZ: CGFloat = 32
        if !z.isFinite { return minZ }
        return max(minZ, min(maxZ, z))
    }
}

// MARK: - TouchCatcher
// Sends:
//  - onSingleTouch(point, phase) for 1-finger
//  - onTwoFingerUpdate(translationFromStart, scaleFromStart, phase) for 2-finger

struct TouchCatcher: UIViewRepresentable {
    var onSingleTouch: (CGPoint, UITouch.Phase) -> Void
    var onTwoFingerUpdate: (CGSize, CGFloat, UITouch.Phase) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.isMultipleTouchEnabled = true
        v.onSingleTouch = onSingleTouch
        v.onTwoFingerUpdate = onTwoFingerUpdate
        return v
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.onSingleTouch = onSingleTouch
        uiView.onTwoFingerUpdate = onTwoFingerUpdate
    }

    final class TouchView: UIView {
        var onSingleTouch: ((CGPoint, UITouch.Phase) -> Void)?
        var onTwoFingerUpdate: ((CGSize, CGFloat, UITouch.Phase) -> Void)?

        private var twoFingerActive = false
        private var initialCentroid: CGPoint = .zero
        private var initialDistance: CGFloat = 0

        private var lastTranslation: CGSize = .zero
        private var lastScale: CGFloat = 1

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            handle(event: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            handle(event: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            handle(event: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            handle(event: event)
        }

        private func handle(event: UIEvent?) {
            guard let allSet = event?.allTouches else { return }
            let all = Array(allSet)
            let active = all.filter { $0.phase != .ended && $0.phase != .cancelled }
            let count = active.count

            if twoFingerActive {
                if count < 2 {
                    // finish with last known translation/scale
                    twoFingerActive = false
                    onTwoFingerUpdate?(lastTranslation, lastScale, .ended)
                    resetTwoFinger()
                    return
                }

                let (centroid, dist) = centroidAndDistance(of: active)
                if initialDistance <= 0 {
                    initialCentroid = centroid
                    initialDistance = max(dist, 0.01)
                    lastTranslation = .zero
                    lastScale = 1
                    onTwoFingerUpdate?(.zero, 1, .began)
                    return
                }

                let translation = CGSize(
                    width: centroid.x - initialCentroid.x,
                    height: centroid.y - initialCentroid.y
                )
                let rawScale = dist / initialDistance
                let scale = rawScale.isFinite ? max(rawScale, 0.01) : 1

                lastTranslation = translation
                lastScale = scale
                onTwoFingerUpdate?(translation, scale, .moved)
                return
            }

            // not in 2-finger mode yet

            if count == 2 {
                twoFingerActive = true
                let (centroid, dist) = centroidAndDistance(of: active)
                initialCentroid = centroid
                initialDistance = max(dist, 0.01)
                lastTranslation = .zero
                lastScale = 1
                onTwoFingerUpdate?(.zero, 1, .began)
                return
            }

            if count == 1, let t = active.first {
                let loc = t.location(in: self)
                onSingleTouch?(loc, t.phase)
            }
        }

        private func resetTwoFinger() {
            initialCentroid = .zero
            initialDistance = 0
            lastTranslation = .zero
            lastScale = 1
        }

        private func centroidAndDistance(of touches: [UITouch]) -> (CGPoint, CGFloat) {
            guard !touches.isEmpty else { return (.zero, 0) }

            var sx: CGFloat = 0
            var sy: CGFloat = 0
            for t in touches {
                let p = t.location(in: self)
                sx += p.x
                sy += p.y
            }
            let c = CGFloat(touches.count)
            let centroid = CGPoint(x: sx / c, y: sy / c)

            var acc: CGFloat = 0
            for t in touches {
                let p = t.location(in: self)
                let dx = p.x - centroid.x
                let dy = p.y - centroid.y
                acc += sqrt(dx*dx + dy*dy)
            }
            let avgDist = acc / c
            return (centroid, avgDist)
        }
    }
}

// MARK: - Flood fill

func floodFill(_ px: inout [UInt32], _ sx: Int, _ sy: Int, _ s: Int, _ newColor: UInt32) {
    if sx < 0 || sy < 0 || sx >= s || sy >= s { return }
    let target = px[sy * s + sx]
    if target == newColor { return }
    var stack = [(sx, sy)]
    while let (x, y) = stack.popLast() {
        if x < 0 || y < 0 || x >= s || y >= s { continue }
        let i = y * s + x
        if i < 0 || i >= px.count || px[i] != target { continue }
        px[i] = newColor
        stack.append((x - 1, y))
        stack.append((x + 1, y))
        stack.append((x, y - 1))
        stack.append((x, y + 1))
    }
}

// MARK: - Color utils

func colorToUInt(_ color: Color) -> UInt32 {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    return (UInt32(a * 255) << 24)
        | (UInt32(r * 255) << 16)
        | (UInt32(g * 255) << 8)
        | (UInt32(b * 255))
}

extension Color {
    init(from argb: UInt32) {
        let a = Double((argb >> 24) & 255) / 255
        let r = Double((argb >> 16) & 255) / 255
        let g = Double((argb >> 8) & 255) / 255
        let b = Double(argb & 255) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

#Preview {
    PaintAppView()
}
