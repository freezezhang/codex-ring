import Foundation

public struct CodexFollowWindow:Equatable {
    public var id:UInt32
    public var frame:CGRect
    public var isOnScreen:Bool
    public var isFocused:Bool
    public var usageFrame:CGRect? = nil
    public init(id:UInt32,frame:CGRect,isOnScreen:Bool,isFocused:Bool=false) {
        self.id=id;self.frame=frame;self.isOnScreen=isOnScreen;self.isFocused=isFocused
    }
}
public enum CodexFollowAction:Equatable {
    case free,hidden,attach(CodexFollowWindow)
}
public enum CodexFollow {
    /// Probe only the lower sidebar. A 20-point grid intersects every eligible
    /// control (at least 26 points wide/high), including on secondary displays.
    /// Points are discovery hints, never an assumed overlay position.
    public static func usageSearchRegion(window:CGRect)->CGRect {
        CGRect(x:window.minX,y:max(window.minY,window.maxY-300),
               width:min(320,window.width),height:min(300,window.height))
    }
    public static func usageProbePoints(window:CGRect)->[CGPoint] {
        let region=usageSearchRegion(window:window)
        guard !region.isEmpty,!region.isNull else { return [] }
        var points:[CGPoint]=[]
        for y in [80.0,104,56] {
            let point=CGPoint(x:region.minX+28,y:region.maxY-y)
            if region.contains(point) { points.append(point) }
        }
        for x in stride(from:min(10,region.width/2),to:region.width,by:20) {
            for y in stride(from:min(10,region.height/2),to:region.height,by:20) {
                points.append(CGPoint(x:region.minX+x,y:region.maxY-y))
            }
        }
        return points
    }
    /// Center a compact ring over the native usage icon, without changing the
    /// user's normal ring size or saved free/follow positions.
    public static func usageOverlayFrame(control:CGRect,window:CGRect)->CGRect? {
        guard [control.minX,control.minY,control.width,control.height].allSatisfy(\.isFinite),
              control.width>=24,control.height>=24,control.width<=100,control.height<=64,
              window.contains(control) else { return nil }
        let size:CGFloat=26
        guard control.width>=size,control.height>=size else { return nil }
        return CGRect(x:control.midX-size/2,y:control.midY-size/2,width:size,height:size)
    }
    /// Public WindowServer metadata provides basic following without AX trust.
    /// Remember identified windows rather than adopting hidden renderer helpers
    /// after the real Codex window closes. On startup in another Space, wait.
    public static func basicWindows(candidates:[CodexFollowWindow],previous:[CodexFollowWindow],hasObservedWindow:Bool)->[CodexFollowWindow] {
        let known=Set(previous.map(\.id))
        let visible=candidates.filter(\.isOnScreen)
        if !visible.isEmpty { return visible + candidates.filter { !$0.isOnScreen && known.contains($0.id) } }
        if hasObservedWindow { return candidates.filter { known.contains($0.id) } }
        return candidates
    }
    /// AX may omit windows on inactive Spaces. A previously identified window
    /// still registered with WindowServer is not evidence of closure.
    public static func retainedOffscreenWindows(previous:[CodexFollowWindow],registeredIDs:Set<UInt32>)->[CodexFollowWindow] {
        previous.filter { registeredIDs.contains($0.id) }.map {
            var window=$0;window.isOnScreen=false;return window
        }
    }
    /// Windows are ordered front to back, and exclude minimized/hidden windows.
    /// Existing windows in another Space must not be confused with closed ones.
    public static func action(enabled:Bool,windows:[CodexFollowWindow])->CodexFollowAction {
        guard enabled,!windows.isEmpty else { return .free }
        let visible=windows.filter(\.isOnScreen)
        guard let window=visible.first(where:\.isFocused) ?? visible.first else { return .hidden }
        return .attach(window)
    }
    public static func area(window:CGRect,screen:CGRect)->CGRect {
        let visible=window.intersection(screen)
        return visible.isNull ? screen:visible
    }
    private static func travel(in area:CGRect,size:CGFloat)->CGRect {
        let margin=min(12,max(0,(min(area.width,area.height)-size)/2))
        let top=min(48,max(0,area.height-size-margin))
        return CGRect(x:area.minX+margin,y:area.minY+margin,
                      width:max(0,area.width-size-2*margin),height:max(0,area.height-size-margin-top))
    }
    public static func frame(in area:CGRect,size:CGFloat,anchor:PanelPosition?)->CGRect {
        let range=travel(in:area,size:size)
        func unit(_ value:Double?)->CGFloat { guard let value,value.isFinite else { return 1 };return CGFloat(min(1,max(0,value))) }
        return CGRect(x:range.minX+range.width*unit(anchor?.x),y:range.minY+range.height*unit(anchor?.y),width:size,height:size)
    }
    public static func anchor(for frame:CGRect,in area:CGRect)->PanelPosition {
        let range=travel(in:area,size:frame.width)
        func unit(_ value:CGFloat,_ length:CGFloat)->Double { length>0 ? Double(min(1,max(0,value/length))):1 }
        return PanelPosition(x:unit(frame.minX-range.minX,range.width),y:unit(frame.minY-range.minY,range.height))
    }
}
