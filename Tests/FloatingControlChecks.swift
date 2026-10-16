import Foundation
import CoreGraphics

@main struct FloatingControlChecks {
    static func main() {
        func close(_ a: Double, _ b: Double) { precondition(abs(a-b) < 0.000001, "\(a) != \(b)") }
        let panel = CGSize(width: 740, height: 120)
        for viewport in [CGSize(width: 760, height: 460), CGSize(width: 1220, height: 858), CGSize(width: 1800, height: 1169)] {
            let bounds = CGRect(x: 24, y: 64, width: viewport.width-48, height: viewport.height-86)
            let fitted = CGSize(width: min(panel.width, bounds.width), height: panel.height)
            for position in [FloatingControlPosition(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1), .init(x: -99, y: 99), .init(x: .nan, y: .infinity)] {
                let center = position.center(in: bounds, panelSize: fitted)
                precondition(center.x-fitted.width/2 >= bounds.minX-0.000001)
                precondition(center.x+fitted.width/2 <= bounds.maxX+0.000001)
                precondition(center.y-fitted.height/2 >= bounds.minY-0.000001)
                precondition(center.y+fitted.height/2 <= bounds.maxY+0.000001)
                let restored = FloatingControlPosition.at(center, in: bounds, panelSize: fitted)
                let nextCenter = restored.center(in: bounds, panelSize: fitted)
                close(nextCenter.x, center.x); close(nextCenter.y, center.y)
            }
            let topLeft = FloatingControlPosition.at(CGPoint(x: -10000, y: -10000), in: bounds, panelSize: fitted)
            let bottomRight = FloatingControlPosition.at(CGPoint(x: 10000, y: 10000), in: bounds, panelSize: fitted)
            close(topLeft.y, 0); close(bottomRight.y, 1)
            close(topLeft.x, bounds.width == fitted.width ? 0.5 : 0)
            close(bottomRight.x, bounds.width == fitted.width ? 0.5 : 1)
        }
        let small = FloatingControlPosition.at(.zero, in: .zero, panelSize: panel)
        precondition(small.x.isFinite && small.y.isFinite)
        print("PASS: floating controls stay reachable at all edges, window sizes and fullscreen; drag positions round-trip")
    }
}
