import SwiftUI

/// The edge dock's silhouette: the right edge runs the full height flush against the
/// screen, concave fillets where that edge turns in at top and bottom, and rounded corners
/// on the left.
///
/// This is `NotchBackgroundShape` rotated a quarter turn, and it is written out rather than
/// derived from it: the path code has its axes baked in, and a version parameterised over
/// "which edge am I hanging off" would make both harder to read than either is now. The
/// reasoning behind the concave corners carries over unchanged — a convex corner reads as a
/// card that happens to be near the edge, a concave one reads as something growing out of
/// the edge, which is what the reference design does.
struct EdgeBackgroundShape: InsettableShape {
    /// Radius of the rounded corners on the left (the free side).
    var innerCorner: CGFloat
    /// Radius of the concave fillets against the screen edge, and how far the shape spills
    /// past the body at top and bottom.
    var flare: CGFloat
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(innerCorner, flare) }
        set { innerCorner = newValue.first; flare = newValue.second }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self; copy.inset += amount; return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let f = max(0, min(flare, r.height / 2))
        let c = max(0, min(innerCorner, min(r.height / 2 - f, r.width / 2)))

        var p = Path()
        // Down the screen edge, full height.
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        // Bottom fillet: centred on the screen edge, level with the fillet's inner end, so
        // the arc leaves the vertical edge tangentially and meets the horizontal the same way.
        if f > 0 {
            p.addArc(center: CGPoint(x: r.maxX - f, y: r.maxY), radius: f,
                     startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        }
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY - f))
        if c > 0 {
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - f - c),
                           control: CGPoint(x: r.minX, y: r.maxY - f))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + f + c))
        if c > 0 {
            p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY + f),
                           control: CGPoint(x: r.minX, y: r.minY + f))
        }
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        if f > 0 {
            p.addArc(center: CGPoint(x: r.maxX - f, y: r.minY), radius: f,
                     startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        }
        p.closeSubpath()
        return p
    }
}

/// A speech bubble with its tail on the right, pointing at whatever it belongs to.
///
/// `tailCenterY` is measured from the top of the bubble and is animatable, so moving the
/// bubble from one ring to the next slides the tail instead of cutting to it.
struct BubbleShape: Shape {
    var tailCenterY: CGFloat
    var corner: CGFloat = Theme.rowCorner + 4
    var tailWidth: CGFloat = EdgeGeometry.tailWidth
    var tailHeight: CGFloat = EdgeGeometry.tailHeight

    var animatableData: CGFloat {
        get { tailCenterY }
        set { tailCenterY = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > tailWidth, rect.height > 0 else { return Path() }
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width - tailWidth, height: rect.height)
        let c = max(0, min(corner, min(body.width / 2, body.height / 2)))
        let half = tailHeight / 2
        // The tail's base is kept inside the straight part of the right edge, so it never
        // grows out of a corner arc.
        let centre = min(max(tailCenterY, body.minY + c + half), body.maxY - c - half)

        // Drawn as one continuous outline rather than a rounded rect with a triangle laid
        // on top. Two overlapping subpaths fill identically but stroke differently: the
        // seam where they meet gets outlined too, and a hairline across the base of the
        // tail is exactly the sort of detail that makes a shape look pasted together.
        var p = Path()
        p.move(to: CGPoint(x: body.minX + c, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - c, y: body.minY))
        p.addArc(center: CGPoint(x: body.maxX - c, y: body.minY + c), radius: c,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        // Right edge down to the tail, out to the point, and back.
        p.addLine(to: CGPoint(x: body.maxX, y: centre - half))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: centre),
                       control: CGPoint(x: body.maxX + tailWidth * 0.5, y: centre - half * 0.3))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: centre + half),
                       control: CGPoint(x: body.maxX + tailWidth * 0.5, y: centre + half * 0.3))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - c))
        p.addArc(center: CGPoint(x: body.maxX - c, y: body.maxY - c), radius: c,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX + c, y: body.maxY))
        p.addArc(center: CGPoint(x: body.minX + c, y: body.maxY - c), radius: c,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + c))
        p.addArc(center: CGPoint(x: body.minX + c, y: body.minY + c), radius: c,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
