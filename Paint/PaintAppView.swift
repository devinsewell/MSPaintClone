//
//  ContentView.swift
//  Paint
//
//  Created by Devin Sewell on 11/2/25.
//
import SwiftUI

enum ToolMode { case brush, bucket, eyedropper, select }

struct PaintAppView: View {
    @State private var pixels = Array(repeating: UInt32(0xFF000000), count: 64 * 64)
    @State private var drawColor = Color.white
    @State private var tool: ToolMode = .brush
    @State private var brushSize = 4
    @State private var selectionRect: CGRect? = nil
    @State private var undoStack: [[UInt32]] = []
    @State private var redoStack: [[UInt32]] = []

    var body: some View {
        VStack(spacing: 8) {
            // --- top bar ---
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

            // --- canvas ---
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

            // --- tool row ---
            HStack(spacing: 14) {
                ColorPicker("", selection: $drawColor).labelsHidden()

                HStack(spacing: 6) {
                    Image(systemName: "paintbrush.fill")
                        .foregroundColor(tool == .brush ? .yellow : .gray)
                        .onTapGesture { tool = .brush }

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

    // --- undo / redo ---
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

// --- canvas ---
struct PixelCanvas: View {
    @Binding var pixels: [UInt32]
    var size: Int
    @Binding var drawColor: Color
    var brushSize: Int
    var tool: ToolMode
    @Binding var selectionRect: CGRect?
    var onStrokeBegan: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let px = geo.size.width / CGFloat(size)
            ZStack {
                Canvas { ctx, _ in
                    for y in 0..<size {
                        for x in 0..<size {
                            let i = y * size + x
                            let rect = CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)
                            ctx.fill(Path(rect), with: .color(Color(from: pixels[i])))
                        }
                    }
                    if let rect = selectionRect {
                        let path = Path(rect)
                        ctx.stroke(path, with: .color(.yellow.opacity(0.8)), lineWidth: 2)
                        ctx.fill(path, with: .color(.yellow.opacity(0.2)))
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let startX = Int(v.startLocation.x / px)
                        let startY = Int(v.startLocation.y / px)
                        let x = Int(v.location.x / px)
                        let y = Int(v.location.y / px)
                        guard x >= 0, y >= 0, x < size, y < size else { return }

                        if v.startLocation == v.location { onStrokeBegan?() }

                        if tool == .select {
                            let minX = CGFloat(min(startX, x))
                            let minY = CGFloat(min(startY, y))
                            let maxX = CGFloat(max(startX, x) + 1)
                            let maxY = CGFloat(max(startY, y) + 1)
                            selectionRect = CGRect(
                                x: minX * px,
                                y: minY * px,
                                width: (maxX - minX) * px,
                                height: (maxY - minY) * px
                            )
                            return
                        }

                        let insideSel: (Int, Int) -> Bool = { xx, yy in
                            guard let r = selectionRect else { return true }
                            let rect = CGRect(x: CGFloat(xx) * px, y: CGFloat(yy) * px, width: px, height: px)
                            return r.intersects(rect)
                        }

                        switch tool {
                        case .eyedropper:
                            drawColor = Color(from: pixels[y * size + x]) // fix here
                        case .bucket:
                            let newColor = colorToUInt(drawColor)
                            if let sel = selectionRect {
                                let minX = Int(sel.minX / px)
                                let minY = Int(sel.minY / px)
                                let maxX = Int(ceil(sel.maxX / px))
                                let maxY = Int(ceil(sel.maxY / px))
                                for yy in minY..<maxY {
                                    for xx in minX..<maxX {
                                        guard xx >= 0, yy >= 0, xx < size, yy < size else { continue }
                                        pixels[yy * size + xx] = newColor
                                    }
                                }
                            } else {
                                floodFill(&pixels, x, y, size, newColor)
                            }
                        case .brush:
                            let r = Double(max(1, brushSize)) / 2.0
                            let colorVal = colorToUInt(drawColor)
                            for yy in 0..<size {
                                for xx in 0..<size {
                                    let dx = Double(xx - x)
                                    let dy = Double(yy - y)
                                    if sqrt(dx*dx + dy*dy) <= r, insideSel(xx, yy) {
                                        pixels[yy * size + xx] = colorVal
                                    }
                                }
                            }
                        default: break
                        }
                    }
                    .onEnded { _ in
                        if tool == .select,
                           let rect = selectionRect,
                           rect.width < 2 && rect.height < 2 {
                            selectionRect = nil
                        }
                    }
            )
        }
    }
}

// --- flood fill ---
func floodFill(_ px: inout [UInt32], _ sx: Int, _ sy: Int, _ s: Int, _ newColor: UInt32) {
    let target = px[sy * s + sx]
    if target == newColor { return }
    var stack = [(sx, sy)]
    while let (x, y) = stack.popLast() {
        let i = y * s + x
        if i < 0 || i >= px.count || px[i] != target { continue }
        px[i] = newColor
        if x > 0 { stack.append((x - 1, y)) }
        if x < s - 1 { stack.append((x + 1, y)) }
        if y > 0 { stack.append((x, y - 1)) }
        if y < s - 1 { stack.append((x, y + 1)) }
    }
}

// --- color utils ---
func colorToUInt(_ color: Color) -> UInt32 {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    return (UInt32(a*255)<<24) | (UInt32(r*255)<<16) | (UInt32(g*255)<<8) | UInt32(b*255)
}

extension Color {
    init(from argb: UInt32) {
        let a = Double((argb>>24)&255)/255
        let r = Double((argb>>16)&255)/255
        let g = Double((argb>>8)&255)/255
        let b = Double(argb&255)/255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

#Preview { PaintAppView() }
