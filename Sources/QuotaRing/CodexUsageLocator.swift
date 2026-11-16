import AppKit
import ApplicationServices
import QuotaCore

/// Locates sidebar controls without activating Codex or reading chat content.
/// Presses only the matched control in response to an explicit ring click.
final class CodexUsageLocator {
    private var accessibilityActivation=CodexAccessibilityActivation()
    /// Chromium and Electron use different renderer accessibility flags.
    /// These app-local flags enable the tree; they do not grant or
    /// change macOS Accessibility permission, activate windows, or press UI.
    func prepare(application:AXUIElement,pid:pid_t) {
        let result=accessibilityActivation.prepare(processID:pid,now:ProcessInfo.processInfo.systemUptime,
            isEnabled:{ self.attribute(application,$0) as? Bool },
            enable:{ name in
                let error=AXUIElementSetAttributeValue(application,name as CFString,kCFBooleanTrue)
                self.diagnostic("renderer initialization: \(name), result=\(error.rawValue)")
                return error == .success
            })
        if let result { diagnostic("renderer state: \(result)") }
    }
    private struct Cached {
        let element:AXUIElement
    }
    private var cache:[UInt32:Cached]=[:]
    private struct SearchPass {
        let window:AXUIElement
        let bounds:CGRect
        let startedAt:TimeInterval
        let points:[CGPoint]
        var pointIndex=0
        var hitCount=0
        var candidateCount=0
        var nodes:[AXUIElement]
        var nodeIndex=0
    }
    private var searches:[UInt32:SearchPass]=[:]
    private struct FailedSearch {
        let window:AXUIElement
        let bounds:CGRect
        var backoff=UsageSearchBackoff()
    }
    private var failures:[UInt32:FailedSearch]=[:]
    // All access, including invalidation, runs on the monitor's serial queue.
    func reset() { cache.removeAll();searches.removeAll();failures.removeAll() }
    func retain(windowIDs:Set<UInt32>) {
        cache=cache.filter { windowIDs.contains($0.key) }
        searches=searches.filter { windowIDs.contains($0.key) }
        failures=failures.filter { windowIDs.contains($0.key) }
    }
    private func failed(id:UInt32,window:AXUIElement,bounds:CGRect,at now:TimeInterval) {
        var failure=failures[id] ?? FailedSearch(window:window,bounds:bounds)
        failure.backoff.failed(at:now)
        if failures.count>=32 { failures.removeAll() }
        failures[id]=failure;searches[id]=nil
    }
    private var lastDiagnostic=""
    private func diagnostic(_ value:String) {
        guard ProcessInfo.processInfo.arguments.contains("--space-diagnostics"),value != lastDiagnostic else { return }
        lastDiagnostic=value
        FileHandle.standardError.write(Data(("[usage-locator] "+value+"\n").utf8))
    }
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
    private func parent(of element:AXUIElement)->AXUIElement? {
        guard let value=attribute(element,kAXParentAttribute),CFGetTypeID(value)==AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func belongs(_ element:AXUIElement,to window:AXUIElement)->Bool {
        if let owner=attribute(element,kAXWindowAttribute) { return CFEqual(owner,window) }
        var current:AXUIElement?=element
        for _ in 0..<16 {
            guard let node=current else { return false }
            if CFEqual(node,window) { return true }
            current=parent(of:node)
        }
        return false
    }
    func locate(in window:AXUIElement,application:AXUIElement,id:UInt32,bounds:CGRect)->CGRect? {
        let region=CodexFollow.usageSearchRegion(window:bounds)
        func valid(_ rect:CGRect)->Bool {
            rect.width>=26 && rect.width<=100 && rect.height>=26 && rect.height<=64 && region.contains(rect)
        }
        // Revalidate the actual control, rather than expiring a working match
        // every second and forcing a fresh walk through a large Electron tree.
        if let cached=cache[id],isUsage(cached.element),let rect=frame(cached.element),
           valid(rect),belongs(cached.element,to:window) {
            diagnostic("matched cached control")
            return rect
        }
        cache[id]=nil
        let now=ProcessInfo.processInfo.systemUptime
        if let failure=failures[id] {
            if failure.bounds != bounds || !CFEqual(failure.window,window) {
                failures[id]=nil;searches[id]=nil
            } else if !failure.backoff.allowsSearch(at:now) { return nil }
        }
        var search=searches[id]
        if let pass=search,pass.bounds == bounds,CFEqual(pass.window,window),now-pass.startedAt>10 {
            failed(id:id,window:window,bounds:bounds,at:now)
            return nil
        }
        if search == nil || search!.bounds != bounds || !CFEqual(search!.window,window) {
            search=SearchPass(window:window,bounds:bounds,startedAt:now,
                              points:CodexFollow.usageProbePoints(window:bounds),nodes:[window])
        }
        var pass=search!
        AXUIElementSetMessagingTimeout(application,0.05)
        AXUIElementSetMessagingTimeout(window,0.05)
        let deadline=now+0.4,probeDeadline=now+0.15
        func remember(_ element:AXUIElement,_ rect:CGRect,_ method:String)->CGRect {
            if cache.count>=32 { cache.removeAll() }
            cache[id]=Cached(element:element);searches[id]=nil;failures[id]=nil
            diagnostic("matched control via "+method)
            return rect
        }
        // Application-scoped AX hit-testing reads controls without moving the
        // pointer or clicking. Walk from an icon leaf to its actual button,
        // accepting only a named usage control owned by the target window.
        while pass.pointIndex<pass.points.count,ProcessInfo.processInfo.systemUptime<probeDeadline {
            let point=pass.points[pass.pointIndex];pass.pointIndex += 1
            var hit:AXUIElement?
            guard AXUIElementCopyElementAtPosition(application,Float(point.x),Float(point.y),&hit) == .success else { continue }
            pass.hitCount += 1
            for _ in 0..<12 {
                guard let node=hit,ProcessInfo.processInfo.systemUptime<probeDeadline else { break }
                if CFEqual(node,window) { break }
                if let rect=frame(node),valid(rect) {
                    pass.candidateCount += 1
                    if isUsage(node),belongs(node,to:window) { return remember(node,rect,"sidebar hit-test") }
                }
                hit=parent(of:node)
            }
        }
        // Keep progress between monitor ticks: a timeout must not permanently
        // starve a deeper control by restarting at the window root each time.
        while pass.nodeIndex<pass.nodes.count,pass.nodeIndex<1600,ProcessInfo.processInfo.systemUptime<deadline {
            let element=pass.nodes[pass.nodeIndex];pass.nodeIndex += 1
            let rect=frame(element)
            if let rect,rect.width>1,rect.height>1,!region.intersects(rect) { continue }
            if let rect,valid(rect),isUsage(element),belongs(element,to:window) {
                return remember(element,rect,"tree traversal")
            }
            if let children=attribute(element,kAXChildrenAttribute) as? [AXUIElement] {
                pass.nodes += children.prefix(max(0,1600-pass.nodes.count))
            }
        }
        let finished=pass.pointIndex>=pass.points.count && (pass.nodeIndex>=pass.nodes.count || pass.nodeIndex>=1600)
        if searches.count>=32 { searches.removeAll() }
        if finished { failed(id:id,window:window,bounds:bounds,at:ProcessInfo.processInfo.systemUptime) }
        else { searches[id]=pass }
        diagnostic("control not found; probes=\(pass.pointIndex)/\(pass.points.count), hits=\(pass.hitCount), candidates=\(pass.candidateCount), nodes=\(pass.nodeIndex), search=\(finished ? "complete":"continuing")")
        return nil
    }
}
