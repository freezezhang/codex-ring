import AppKit
import QuotaCore

final class RingAboutWindow:NSWindowController {
    static var versionText:String {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? L10n.string("about.devVersion")
        return L10n.format("about.version",version)
    }
    private let onDebug:()->Void
    private let icon=NSImageView()
    private let versionLabel=NSTextField(labelWithString:"")
    init(onDebug:@escaping ()->Void) {
        self.onDebug=onDebug
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:280,height:210),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent=true;window.isMovableByWindowBackground=true
        window.isReleasedWhenClosed=false
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary,.canJoinAllApplications,.ignoresCycle]
        super.init(window:window)

        icon.image=NSApp.applicationIconImage;icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant:72).isActive=true
        icon.heightAnchor.constraint(equalToConstant:72).isActive=true
        let gesture=NSClickGestureRecognizer(target:self,action:#selector(iconClicked(_:)))
        gesture.numberOfClicksRequired=5
        icon.addGestureRecognizer(gesture)

        let name=NSTextField(labelWithString:"CodexRing")
        name.font=NSFont.systemFont(ofSize:22,weight:.semibold)
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
        applyLanguage()
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func applyLanguage() {
        window?.title=L10n.string("about.windowTitle")
        icon.setAccessibilityLabel(L10n.string("about.icon.a11y"))
        versionLabel.stringValue=Self.versionText
    }
    @objc private func iconClicked(_ gesture:NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onDebug()
    }
}
