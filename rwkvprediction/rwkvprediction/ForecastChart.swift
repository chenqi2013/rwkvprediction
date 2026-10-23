import SwiftUI
import UIKit

enum Design {
    static let ink = adaptive(light: 0x19212C, dark: 0xE9EDF5)
    static let secondary = adaptive(light: 0x8B9098, dark: 0xA2ACBA)
    static let bodyText = adaptive(light: 0x626975, dark: 0xC0C8D4)
    static let orange = adaptive(light: 0xF47735, dark: 0xFF9A5F)
    static let orangeSoft = adaptive(light: 0xFFF3E9, dark: 0x36271F)
    static let blue = adaptive(light: 0x5776D7, dark: 0x89A6FF)
    static let green = adaptive(light: 0x199E83, dark: 0x40C5A7)
    static let red = adaptive(light: 0xE75A58, dark: 0xFF7975)
    static let line = adaptive(light: 0xECEEF0, dark: 0x303945)
    static let canvas = adaptive(light: 0xF7F8FA, dark: 0x101419)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1A2029)
    static let selectedSurface = adaptive(light: 0xFFFFFF, dark: 0x303A49)
    static let action = adaptive(light: 0x19212C, dark: 0xF79250)
    static let onAction = adaptive(light: 0xFFFFFF, dark: 0x181C23)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct ForecastChart: View {
    let snapshot: MarketSnapshot
    let forecast: Forecast
    let confidence: Int
    var historicalOnly = false
    @State private var selectedX: CGFloat?
    private let insetLeft: CGFloat = 2
    private let insetRight: CGFloat = 48
    private let insetTop: CGFloat = 23
    private let insetBottom: CGFloat = 28

    private var limits: (Double, Double) {
        let values = snapshot.history.map(\.close) + (historicalOnly ? [] : forecast.points.flatMap { [$0.lower(confidence), $0.upper(confidence)] })
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.15, 0.001)
        return (low - padding, high + padding)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - insetRight - insetLeft
            let height = geometry.size.height - insetTop - insetBottom
            let split = historicalOnly ? width : width * 0.49
            let bounds = limits
            let y: (Double) -> CGFloat = { value in
                insetTop + height * (1 - (value - bounds.0) / (bounds.1 - bounds.0))
            }
            let currentY = y(snapshot.asset.price)
            let history = snapshot.history.enumerated().map { index, point in
                CGPoint(x: insetLeft + split * CGFloat(index) / CGFloat(max(snapshot.history.count-1, 1)), y: y(point.close))
            }
            let future: (KeyPath<ForecastPoint, Double>) -> [CGPoint] = { key in
                [CGPoint(x: insetLeft + split, y: currentY)] + forecast.points.enumerated().map { i, point in
                    CGPoint(x: insetLeft + split + (width-split) * CGFloat(i+1) / CGFloat(forecast.points.count), y: y(point[keyPath: key]))
                }
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for index in 0...4 {
                        let gridY = insetTop + height * CGFloat(index) / 4
                        var grid = Path()
                        grid.move(to: CGPoint(x: insetLeft, y: gridY))
                        grid.addLine(to: CGPoint(x: width+insetLeft, y: gridY))
                        context.stroke(grid, with: .color(Design.line), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                        let value = bounds.1 - (bounds.1-bounds.0) * Double(index) / 4
                        context.draw(Text(snapshot.asset.formatted(value)).font(.system(size: 10, design: .monospaced)).foregroundColor(Design.secondary), at: CGPoint(x: size.width, y: gridY), anchor: .trailing)
                    }
                    if !historicalOnly {
                        let upper = future(confidence == 95 ? \.p975 : \.p90)
                        let lower = future(confidence == 95 ? \.p025 : \.p10)
                        context.fill(band(upper, lower), with: .linearGradient(Gradient(colors: [Design.orange.opacity(0.05), Design.orange.opacity(0.18)]), startPoint: CGPoint(x: split, y: 0), endPoint: CGPoint(x: width, y: 0)))
                        context.fill(band(future(\.p75), future(\.p25)), with: .color(Design.orange.opacity(0.16)))
                        context.stroke(line(upper), with: .color(Design.orange.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [3,3]))
                        context.stroke(line(lower), with: .color(Design.orange.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [3,3]))
                        context.stroke(line(future(\.p50)), with: .color(Design.orange), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                        var divider = Path()
                        divider.move(to: CGPoint(x: split+insetLeft, y: 8))
                        divider.addLine(to: CGPoint(x: split+insetLeft, y: insetTop+height))
                        context.stroke(divider, with: .color(Design.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 0.8, dash: [3,4]))
                    }
                    context.stroke(line(history), with: .color(Design.blue), style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                    let dot = CGRect(x: split+insetLeft-4, y: currentY-4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(Design.surface))
                    context.fill(Path(ellipseIn: dot), with: .color(Design.blue))
                    if let selectedX {
                        var cursor = Path()
                        cursor.move(to: CGPoint(x: selectedX, y: insetTop))
                        cursor.addLine(to: CGPoint(x: selectedX, y: insetTop+height))
                        context.stroke(cursor, with: .color(Design.ink.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3,3]))
                    }
                }
                if !historicalOnly {
                    Text("预测区间").font(.system(size: 10, weight: .medium)).foregroundStyle(Design.orange)
                        .position(x: split + (width-split)/2, y: 9)
                    Text("当前").font(.system(size: 9)).foregroundStyle(Design.secondary)
                        .position(x: split+1, y: insetTop+height+13)
                }
                Text(shortDate(snapshot.history.first?.date ?? ""))
                    .font(.system(size: 10)).foregroundStyle(Design.secondary)
                    .position(x: 19, y: insetTop+height+13)
                Text(shortDate(historicalOnly ? snapshot.history.last?.date ?? "" : forecast.last.date))
                    .font(.system(size: 10)).foregroundStyle(Design.secondary)
                    .position(x: width-12, y: insetTop+height+13)
                if let selectedX {
                    let point = tooltip(x: selectedX, split: split, width: width)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(point.0).font(.system(size: 10)).foregroundStyle(Design.secondary)
                        Text(point.1).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Design.ink)
                    .padding(8).background(Design.selectedSurface, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.09), radius: 5, y: 2)
                    .position(x: min(max(selectedX, 80), geometry.size.width-85), y: 30)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { selectedX = min(max($0.location.x, insetLeft), width) }
                .onEnded { _ in selectedX = nil })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(snapshot.asset.name)历史走势及未来\(forecast.horizon)个交易日预测。期末\(confidence)%预测区间\(snapshot.asset.formatted(forecast.last.lower(confidence)))至\(snapshot.asset.formatted(forecast.last.upper(confidence)))，中位值\(snapshot.asset.formatted(forecast.last.p50))。")
        }
    }
    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }
    private func band(_ upper: [CGPoint], _ lower: [CGPoint]) -> Path {
        Path { path in
            guard let first = upper.first else { return }
            path.move(to: first)
            for point in upper.dropFirst() { path.addLine(to: point) }
            for point in lower.reversed() { path.addLine(to: point) }
            path.closeSubpath()
        }
    }
    private func shortDate(_ date: String) -> String { String(date.suffix(5)).replacingOccurrences(of: "-", with: "/") }
    private func tooltip(x: CGFloat, split: CGFloat, width: CGFloat) -> (String, String) {
        if x <= split || historicalOnly {
            let index = min(max(Int((x-insetLeft)/split * CGFloat(snapshot.history.count-1)), 0), snapshot.history.count-1)
            let point = snapshot.history[index]
            return (point.date + " · 历史", snapshot.asset.formatted(point.close))
        }
        let index = min(max(Int((x-split)/(width-split) * CGFloat(forecast.points.count))-1, 0), forecast.points.count-1)
        let point = forecast.points[index]
        return (point.date + " · 预测", "\(snapshot.asset.formatted(point.lower(confidence))) – \(snapshot.asset.formatted(point.upper(confidence)))")
    }
}
