import Foundation
import CoreGraphics
public enum DockEdge: String, CaseIterable { case left, right, top, bottom }
public enum DragMotion {
    public static func origin(initial:CGPoint,start:CGPoint,current:CGPoint,locked:Bool)->CGPoint {
        locked ? initial:CGPoint(x:initial.x+current.x-start.x,y:initial.y+current.y-start.y)
    }
}
public enum Docking {
    public static let handle: CGFloat = 14
    public static func handle(for diameter: CGFloat) -> CGFloat { diameter <= 32 ? 8 : handle }
    public static func clamped(_ frame: CGRect, to screen: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - frame.width),
               y: min(max(frame.minY, screen.minY), screen.maxY - frame.height), width: frame.width, height: frame.height)
    }
    public static func relocated(_ frame:CGRect,from source:CGRect,to target:CGRect)->CGRect {
        if source == target { return clamped(frame,to:target) }
        guard source.width>0,source.height>0 else { return clamped(frame,to:target) }
        let x=min(1,max(0,(frame.midX-source.minX)/source.width))
        let y=min(1,max(0,(frame.midY-source.minY)/source.height))
        return clamped(CGRect(x:target.minX+target.width*x-frame.width/2,
                              y:target.minY+target.height*y-frame.height/2,
                              width:frame.width,height:frame.height),to:target)
    }
    public static func nearestEdge(_ frame: CGRect, screen: CGRect, threshold: CGFloat = 16) -> DockEdge? {
        let distances: [(DockEdge, CGFloat)] = [(.left, abs(frame.minX - screen.minX)), (.right, abs(frame.maxX - screen.maxX)),
                                               (.top, abs(frame.maxY - screen.maxY)), (.bottom, abs(frame.minY - screen.minY))]
        return distances.filter { $0.1 <= threshold }.min { $0.1 < $1.1 }?.0
    }
    public static func revealed(_ frame: CGRect, edge: DockEdge, screen: CGRect) -> CGRect {
        var f = clamped(frame, to: screen)
        switch edge {
        case .left: f.origin.x = screen.minX + 4
        case .right: f.origin.x = screen.maxX - f.width - 4
        case .top: f.origin.y = screen.maxY - f.height - 4
        case .bottom: f.origin.y = screen.minY + 4
        }
        return f
    }
    public static func hidden(_ frame: CGRect, edge: DockEdge, screen: CGRect) -> CGRect {
        var f = clamped(frame, to: screen)
        let tab = handle(for: min(frame.width, frame.height))
        switch edge {
        case .left: f.origin.x = screen.minX; f.size.width = tab
        case .right: f.origin.x = screen.maxX - tab; f.size.width = tab
        case .top: f.origin.y = screen.maxY - tab; f.size.height = tab
        case .bottom: f.origin.y = screen.minY; f.size.height = tab
        }
        return f
    }
}
