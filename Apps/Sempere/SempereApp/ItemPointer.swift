import SempereAppCore
import UIKit

/// The app's half of `ItemPointer` (`SempereAppCore`: which region a drag is in, its angle and identifier): the
/// outlines.
extension ItemPointer {
    /// The pointer's outline, centred on the hot spot, screen points.
    var path: UIBezierPath {
        switch self {
        case .move: return Self.fourWay()
        case .resize(let degrees):
            let p = Self.twoWay()
            p.apply(CGAffineTransform(rotationAngle: CGFloat(degrees * .pi / 180)))
            return p
        }
    }

    /// A two-way arrow along x, 22 points long.
    static func twoWay() -> UIBezierPath {
        let half: CGFloat = 11, head: CGFloat = 5, shaft: CGFloat = 1.5
        let p = UIBezierPath()
        p.move(to: CGPoint(x: -half, y: 0))
        p.addLine(to: CGPoint(x: -half + head, y: -head))
        p.addLine(to: CGPoint(x: -half + head, y: -shaft))
        p.addLine(to: CGPoint(x: half - head, y: -shaft))
        p.addLine(to: CGPoint(x: half - head, y: -head))
        p.addLine(to: CGPoint(x: half, y: 0))
        p.addLine(to: CGPoint(x: half - head, y: head))
        p.addLine(to: CGPoint(x: half - head, y: shaft))
        p.addLine(to: CGPoint(x: -half + head, y: shaft))
        p.addLine(to: CGPoint(x: -half + head, y: head))
        p.close()
        return p
    }

    /// Two two-way arrows crossed: move in any direction.
    static func fourWay() -> UIBezierPath {
        let p = twoWay()
        let v = twoWay()
        v.apply(CGAffineTransform(rotationAngle: .pi / 2))
        p.append(v)
        p.usesEvenOddFillRule = false
        return p
    }
}
