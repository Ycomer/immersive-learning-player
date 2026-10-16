import Foundation

@main struct CoverRegionChecks {
    static func main() {
        func close(_ a: Double, _ b: Double) { precondition(abs(a-b) < 0.000001, "\(a) != \(b)") }
        let viewport = CGSize(width: 1000, height: 500)
        let region = CoverRegion(x: 0.2, y: 0.4, width: 0.6, height: 0.3)
        let moved = region.moved(by: CGSize(width: 100, height: -50), in: viewport)
        close(moved.x, 0.3); close(moved.y, 0.3)
        close(moved.width, region.width); close(moved.height, region.height)
        let boundary = region.moved(by: CGSize(width: 10000, height: -10000), in: viewport)
        close(boundary.x, 0.4); close(boundary.y, 0)
        for corner in CoverRegion.Corner.allCases {
            let resized = region.resized(corner, by: CGSize(width: 50, height: 25), in: viewport)
            let left = corner == .topLeft || corner == .bottomLeft
            let top = corner == .topLeft || corner == .topRight
            close(left ? resized.x + resized.width : resized.x, left ? 0.8 : 0.2)
            close(top ? resized.y + resized.height : resized.y, top ? 0.7 : 0.4)
            for delta in [CGSize(width: 10000, height: 10000), CGSize(width: -10000, height: -10000)] {
                let extreme = region.resized(corner, by: delta, in: viewport)
                precondition(extreme.width >= 0.18-0.000001 && extreme.height >= 0.08-0.000001)
                precondition(extreme.x >= 0 && extreme.y >= 0 && extreme.x+extreme.width <= 1.000001 && extreme.y+extreme.height <= 1.000001)
            }
        }
        let normal = region.pixels(in: viewport)
        let fullscreen = region.pixels(in: CGSize(width: 2000, height: 1000))
        close(fullscreen.minX, normal.minX*2); close(fullscreen.minY, normal.minY*2)
        close(fullscreen.width, normal.width*2); close(fullscreen.height, normal.height*2)
        precondition(region.moved(by: CGSize(width: 1, height: 1), in: .zero) == region)
        precondition(region.resized(.topLeft, by: CGSize(width: 1, height: 1), in: .zero) == region)
        let invalid = CoverRegion(x: .nan, y: .infinity, width: -1, height: .nan).clamped()
        precondition(invalid.x.isFinite && invalid.y.isFinite && invalid.width == 0.18 && invalid.height == 0.18)
        print("Cover region checks passed: dragging, four corner anchors, bounds, minimum sizes, viewport scaling, invalid values")
    }
}
