import AppKit

final class RingAboutWindow:NSWindowController {
    private let onDebug:()->Void
    init(onDebug:@escaping ()->Void) {
        self.onDebug=onDebug
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:280,height:210),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="关于 CodexRing";window.titleVisibility = .hidden
        window.titlebarAppearsTransparent=true;window.isMovableByWindowBackground=true
        window.isReleasedWhenClosed=false
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        super.init(window:window)

        let icon=NSImageView()
        icon.image=NSApp.applicationIconImage;icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("CodexRing 图标")
        icon.widthAnchor.constraint(equalToConstant:72).isActive=true
        icon.heightAnchor.constraint(equalToConstant:72).isActive=true
        let gesture=NSClickGestureRecognizer(target:self,action:#selector(iconClicked(_:)))
        gesture.numberOfClicksRequired=5
        icon.addGestureRecognizer(gesture)

        let name=NSTextField(labelWithString:"CodexRing")
        name.font=NSFont.systemFont(ofSize:22,weight:.semibold)
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版本"
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String
        let versionLabel=NSTextField(labelWithString:"版本 \(version)"+(build.map { " (\($0))" } ?? ""))
        versionLabel.font=NSFont.systemFont(ofSize:13);versionLabel.textColor = .secondaryLabelColor
        let stack=NSStackView(views:[icon,name,versionLabel])
        stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=12
        stack.translatesAutoresizingMaskIntoConstraints=false
        let content=window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo:content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo:content.centerYAnchor)
        ])
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func iconClicked(_ gesture:NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onDebug()
    }
}
