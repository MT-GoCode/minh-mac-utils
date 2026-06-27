import SwiftUI

/// A trapezoidal tab welded to one screen edge: full-width along the attached edge, tapering
/// toward the protruding side, rounded corners on the protruding side, and concave fillets
/// ("smoothing at the base") where the sides blend into the edge. Bars just use a plain Rectangle.
struct TabShape: Shape {
    let edge: Edge          // .top, .leading (left), .trailing (right)
    var taper: CGFloat = 26 // how much each side pulls in toward the protruding end
    var radius: CGFloat = 14
    var fillet: CGFloat = 16

    enum Edge { case top, leading, trailing }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = min(taper, r.width / 3, r.height / 3)
        let rad = min(radius, r.height / 3, r.width / 3)
        let f = min(fillet, r.height / 3, r.width / 3)

        switch edge {
        case .top:
            // attached along the TOP edge (y=minY), protruding DOWN to maxY
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            // right shoulder: concave blend from the edge inward
            p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.minY + f),
                           control: CGPoint(x: r.maxX - t, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - t, y: r.maxY - rad))
            p.addQuadCurve(to: CGPoint(x: r.maxX - t - rad, y: r.maxY),
                           control: CGPoint(x: r.maxX - t, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + t + rad, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.maxY - rad),
                           control: CGPoint(x: r.minX + t, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + t, y: r.minY + f))
            // left shoulder: concave blend back to the edge
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY),
                           control: CGPoint(x: r.minX + t, y: r.minY))
        case .leading:
            // attached along the LEFT edge (x=minX), protruding RIGHT to maxX
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.maxY - t),
                           control: CGPoint(x: r.minX, y: r.maxY - t))
            p.addLine(to: CGPoint(x: r.maxX - rad, y: r.maxY - t))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - t - rad),
                           control: CGPoint(x: r.maxX, y: r.maxY - t))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + t + rad))
            p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.minY + t),
                           control: CGPoint(x: r.maxX, y: r.minY + t))
            p.addLine(to: CGPoint(x: r.minX + f, y: r.minY + t))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY),
                           control: CGPoint(x: r.minX, y: r.minY + t))
        case .trailing:
            // attached along the RIGHT edge (x=maxX), protruding LEFT to minX
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.maxY - t),
                           control: CGPoint(x: r.maxX, y: r.maxY - t))
            p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY - t))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - t - rad),
                           control: CGPoint(x: r.minX, y: r.maxY - t))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + t + rad))
            p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY + t),
                           control: CGPoint(x: r.minX, y: r.minY + t))
            p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + t))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                           control: CGPoint(x: r.maxX, y: r.minY + t))
        }
        p.closeSubpath()
        return p
    }
}
