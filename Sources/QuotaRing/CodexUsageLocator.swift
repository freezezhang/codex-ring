import AppKit
import ApplicationServices

/// Locates sidebar controls without activating Codex or reading chat content.
/// Presses only the matched control in response to an explicit ring click.
final class CodexUsageLocator {
    private struct Cached {
        let element:AXUIElement
        let foundAt:Date
    }
    private var cache:[UInt32:Cached]=[:]
    func press(id:UInt32,expectedFrame:CGRect)->Bool {
        guard let cached=cache[id],isUsage(cached.element),let rect=frame(cached.element),
              abs(rect.minX-expectedFrame.minX)<2,abs(rect.minY-expectedFrame.minY)<2,
              abs(rect.width-expectedFrame.width)<2,abs(rect.height-expectedFrame.height)<2 else { return false }
        var names:CFArray?
        guard AXUIElementCopyActionNames(cached.element,&names) == .success,
              let actions=names as? [String] else { return false }
        let action=actions.contains(kAXPressAction) ? kAXPressAction:(actions.contains(kAXShowMenuAction) ? kAXShowMenuAction:nil)
        guard let action else { return false }
        AXUIElementSetMessagingTimeout(cached.element,0.3)
        let result=AXUIElementPerformAction(cached.element,action as CFString)
        // Native popup actions can time out while their menu is already open.
        // Never retry a click: a second press could close it again.
        return result == .success || result == .cannotComplete
    }
    private func attribute(_ element:AXUIElement,_ name:String)->CFTypeRef? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    private func frame(_ element:AXUIElement)->CGRect? {
        var point=CGPoint.zero,size=CGSize.zero
        guard let p=attribute(element,kAXPositionAttribute),CFGetTypeID(p)==AXValueGetTypeID(),
              let s=attribute(element,kAXSizeAttribute),CFGetTypeID(s)==AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
    private func isUsage(_ element:AXUIElement)->Bool {
        guard let role=attribute(element,kAXRoleAttribute) as? String,
              [kAXPopUpButtonRole,kAXButtonRole].contains(role),
              (attribute(element,"AXHidden") as? Bool) != true else { return false }
        return [kAXTitleAttribute,kAXDescriptionAttribute].contains { name in
            guard let text=attribute(element,name) as? String else { return false }
            return ["用量","使用量","Usage","Rate limits"].contains { $0.caseInsensitiveCompare(text.trimmingCharacters(in:.whitespacesAndNewlines)) == .orderedSame }
        }
    }
    func locate(in window:AXUIElement,id:UInt32,bounds:CGRect)->CGRect? {
        // Search only the bottom of the left sidebar, avoiding chat text.
        let region=CGRect(x:bounds.minX,y:max(bounds.minY,bounds.maxY-300),width:min(320,bounds.width),height:min(300,bounds.height))
        func valid(_ rect:CGRect)->Bool {
            rect.width>=26 && rect.width<=100 && rect.height>=26 && rect.height<=64 && region.contains(rect)
        }
        if let cached=cache[id],Date().timeIntervalSince(cached.foundAt)<1,
           isUsage(cached.element),let rect=frame(cached.element),valid(rect) { return rect }
        cache[id]=nil
        // Bound both traversal and AX messaging so a busy renderer cannot
        // block the main thread or leave an overlay at a guessed position.
        AXUIElementSetMessagingTimeout(window,0.05)
        let deadline=Date().addingTimeInterval(0.4)
        var queue=[window],cursor=0
        while cursor<queue.count,cursor<1600,Date()<deadline {
            let element=queue[cursor];cursor += 1
            let rect=frame(element)
            if let rect,rect.width>1,rect.height>1,!region.intersects(rect) { continue }
            if let rect,valid(rect),isUsage(element) {
                if cache.count>32 { cache.removeAll() }
                cache[id]=Cached(element:element,foundAt:Date());return rect
            }
            if let children=attribute(element,kAXChildrenAttribute) as? [AXUIElement] { queue += children }
        }
        return nil
    }
}
