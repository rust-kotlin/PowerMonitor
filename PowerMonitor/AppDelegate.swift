import SwiftUI
import AppKit
import Combine

// AppDelegate is kept focused on window, menu, and panel orchestration.
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var statusMenu: NSMenu?
    weak var menuHostingView: NSView?
    var networkOverlayPanel: NSPanel?

    let monitor = SystemMonitor()
    let stressTester = StressTestController()

    private var eventMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var localRightClickMonitor: Any?
    private var overlayMoveObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var currentMetric: MonitorMetric?
    private var metricFrames: [MonitorMetric: CGRect] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let menuView = MenuBarMainView(monitor: monitor, onBlockClick: { [weak self] metric, blockRect in
                self?.togglePopover(metric: metric, sender: button, blockRect: blockRect)
            }, onFramesUpdate: { [weak self] frames in
                self?.metricFrames = frames
            })

            let hostingView = NSHostingView(rootView: menuView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            menuHostingView = hostingView

            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: button.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor)
            ])

            rebuildStatusMenu()

            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(statusButtonClicked(_:))

            if monitor.isMock {
                button.toolTip = monitor.mockWarning
            }

            monitor.$isMock
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isMock in
                    guard let self = self, let button = self.statusItem?.button else { return }
                    button.toolTip = isMock ? self.monitor.mockWarning : nil
                }
                .store(in: &cancellables)

            monitor.$useColoredValues
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            monitor.$showMetricDividers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            monitor.$networkDisplayMode
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            monitor.$diskDisplayMode
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            // Rebuild the menu and overlay together because both reflect the same
            // persisted network overlay settings.
            monitor.$networkOverlaySettings
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                    self?.updateNetworkOverlayPanel()
                }
                .store(in: &cancellables)

            monitor.$networkThroughput
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshNetworkOverlayContent()
                }
                .store(in: &cancellables)

            monitor.$thresholds
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            monitor.$metricOrder
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            monitor.$hiddenMetrics
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)

            stressTester.$mode
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebuildStatusMenu()
                }
                .store(in: &cancellables)
        }

        popover.behavior = .applicationDefined
        popover.animates = false
        updateNetworkOverlayPanel()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            if self.popover.isShown {
                self.popover.close()
            }
        }
        
        setupMacos27RightClickFix()
    }

    private func setupMacos27RightClickFix() {
        let mask: NSEvent.EventTypeMask = [.rightMouseDown]
        
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMacos27RightClick()
        }
        
        localRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMacos27RightClick()
            return event
        }
    }

    private func handleMacos27RightClick() {
        guard let button = statusItem?.button, let window = button.window else { return }
        
        let mouseLocation = NSEvent.mouseLocation
        let windowFrame = window.frame
        
        if windowFrame.contains(mouseLocation) {
            rebuildStatusMenu()
            NSApp.activate(ignoringOtherApps: true)
            let menuPoint = NSPoint(x: button.bounds.midX, y: button.bounds.maxY)
            statusMenu?.popUp(positioning: nil, at: menuPoint, in: button)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.resetFanControlForExit()
        stressTester.stopAll()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()

        let setIntervalItem = NSMenuItem(title: "Set Interval", action: #selector(setIntervalMenuItem(_:)), keyEquivalent: "")
        setIntervalItem.target = self
        menu.addItem(setIntervalItem)

        let coloredItem = NSMenuItem(title: "Colored Values", action: #selector(toggleColoredValues(_:)), keyEquivalent: "")
        coloredItem.target = self
        coloredItem.state = monitor.useColoredValues ? .on : .off
        menu.addItem(coloredItem)

        let dividerItem = NSMenuItem(title: "Show Metric Dividers", action: #selector(toggleMetricDividers(_:)), keyEquivalent: "")
        dividerItem.target = self
        dividerItem.state = monitor.showMetricDividers ? .on : .off
        menu.addItem(dividerItem)

        let thresholdItem = NSMenuItem(title: "Set Thresholds for Colored Values", action: #selector(setThresholdsMenuItem(_:)), keyEquivalent: "")
        thresholdItem.target = self
        menu.addItem(thresholdItem)

        let networkModeMenuItem = NSMenuItem(title: "Network UI", action: nil, keyEquivalent: "")
        networkModeMenuItem.submenu = makeNetworkModeMenu()
        menu.addItem(networkModeMenuItem)

        let diskModeMenuItem = NSMenuItem(title: "SSD UI", action: nil, keyEquivalent: "")
        diskModeMenuItem.submenu = makeDiskModeMenu()
        menu.addItem(diskModeMenuItem)

        let networkSourceMenuItem = NSMenuItem(title: "Network Source", action: nil, keyEquivalent: "")
        networkSourceMenuItem.submenu = makeNetworkSourceMenu()
        menu.addItem(networkSourceMenuItem)

        let diskSourceMenuItem = NSMenuItem(title: "SSD Source", action: nil, keyEquivalent: "")
        diskSourceMenuItem.submenu = makeDiskSourceMenu()
        menu.addItem(diskSourceMenuItem)

        let networkOverlayMenuItem = NSMenuItem(title: "Network Overlay", action: nil, keyEquivalent: "")
        networkOverlayMenuItem.submenu = makeNetworkOverlayMenu()
        menu.addItem(networkOverlayMenuItem)

        menu.addItem(.separator())

        let stressBothItem = NSMenuItem(title: "Stress CPU + GPU", action: #selector(toggleStressBothMenuItem(_:)), keyEquivalent: "")
        stressBothItem.target = self
        stressBothItem.state = stressTester.mode == .cpuAndGPU ? .on : .off
        menu.addItem(stressBothItem)

        menu.addItem(.separator())

        let displayConfigItem = NSMenuItem(title: "Configure Display Items", action: #selector(configureDisplayItemsMenuItem(_:)), keyEquivalent: "")
        displayConfigItem.target = self
        menu.addItem(displayConfigItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitMenuItem(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu
    }
    @objc private func toggleColoredValues(_ sender: Any?) {
        monitor.setUseColoredValues(!monitor.useColoredValues)
    }

    @objc private func toggleMetricDividers(_ sender: Any?) {
        monitor.setShowMetricDividers(!monitor.showMetricDividers)
    }

    private func makeNetworkModeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in NetworkDisplayMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(setNetworkDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = monitor.networkDisplayMode == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeDiskModeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in DiskDisplayMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(setDiskDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = monitor.diskDisplayMode == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeNetworkSourceMenu() -> NSMenu {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(title: "Default", action: #selector(setNetworkSource(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = monitor.networkSourceName == nil ? .on : .off
        menu.addItem(defaultItem)

        let options = monitor.availableNetworkInterfaces
        if !options.isEmpty {
            menu.addItem(.separator())
        }

        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(setNetworkSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = monitor.networkSourceName == option.id ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func makeDiskSourceMenu() -> NSMenu {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(title: "Default", action: #selector(setDiskSource(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = monitor.diskSourcePath == nil ? .on : .off
        menu.addItem(defaultItem)

        let options = monitor.availableDiskVolumes
        if !options.isEmpty {
            menu.addItem(.separator())
        }

        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(setDiskSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.path
            item.state = monitor.diskSourcePath == option.path ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func makeNetworkOverlayMenu() -> NSMenu {
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Show Overlay", action: #selector(toggleNetworkOverlayEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = monitor.networkOverlaySettings.isEnabled ? .on : .off
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        let uploadItem = NSMenuItem(title: "Show Upload", action: #selector(toggleNetworkOverlayUpload(_:)), keyEquivalent: "")
        uploadItem.target = self
        uploadItem.state = monitor.networkOverlaySettings.showsUpload ? .on : .off
        menu.addItem(uploadItem)

        let downloadItem = NSMenuItem(title: "Show Download", action: #selector(toggleNetworkOverlayDownload(_:)), keyEquivalent: "")
        downloadItem.target = self
        downloadItem.state = monitor.networkOverlaySettings.showsDownload ? .on : .off
        menu.addItem(downloadItem)

        menu.addItem(.separator())

        let clickThroughItem = NSMenuItem(title: "Mouse Through", action: #selector(toggleNetworkOverlayClickThrough(_:)), keyEquivalent: "")
        clickThroughItem.target = self
        clickThroughItem.state = monitor.networkOverlaySettings.clickThrough ? .on : .off
        menu.addItem(clickThroughItem)

        let sizeMenuItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeMenuItem.submenu = makeNetworkOverlaySizeMenu()
        menu.addItem(sizeMenuItem)

        let styleMenuItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleMenuItem.submenu = makeNetworkOverlayStyleMenu()
        menu.addItem(styleMenuItem)

        let opacityMenuItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityMenuItem.submenu = makeNetworkOverlayOpacityMenu()
        menu.addItem(opacityMenuItem)

        return menu
    }

    private func makeNetworkOverlayOpacityMenu() -> NSMenu {
        let menu = NSMenu()
        for percent in [100, 90, 80, 70, 60, 50] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setNetworkOverlayOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Double(percent) / 100.0
            item.state = abs(monitor.networkOverlaySettings.opacity - (Double(percent) / 100.0)) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeNetworkOverlayStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for style in NetworkOverlayStyle.allCases {
            let item = NSMenuItem(title: style.menuTitle, action: #selector(setNetworkOverlayStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = monitor.networkOverlaySettings.style == style ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeNetworkOverlaySizeMenu() -> NSMenu {
        let menu = NSMenu()
        for size in NetworkOverlaySize.allCases {
            let item = NSMenuItem(title: size.menuTitle, action: #selector(setNetworkOverlaySize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = monitor.networkOverlaySettings.size == size ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func setNetworkDisplayMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = NetworkDisplayMode(rawValue: rawValue) else { return }
        monitor.setNetworkDisplayMode(mode)
    }

    @objc private func setDiskDisplayMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = DiskDisplayMode(rawValue: rawValue) else { return }
        monitor.setDiskDisplayMode(mode)
    }

    @objc private func setNetworkSource(_ sender: NSMenuItem) {
        monitor.setNetworkSourceName(sender.representedObject as? String)
    }

    @objc private func setDiskSource(_ sender: NSMenuItem) {
        monitor.setDiskSourcePath(sender.representedObject as? String)
    }

    @objc private func toggleNetworkOverlayEnabled(_ sender: Any?) {
        monitor.setNetworkOverlayEnabled(!monitor.networkOverlaySettings.isEnabled)
    }

    @objc private func toggleNetworkOverlayUpload(_ sender: Any?) {
        monitor.setNetworkOverlayShowsUpload(!monitor.networkOverlaySettings.showsUpload)
    }

    @objc private func toggleNetworkOverlayDownload(_ sender: Any?) {
        monitor.setNetworkOverlayShowsDownload(!monitor.networkOverlaySettings.showsDownload)
    }

    @objc private func toggleNetworkOverlayClickThrough(_ sender: Any?) {
        monitor.setNetworkOverlayClickThrough(!monitor.networkOverlaySettings.clickThrough)
    }

    @objc private func setNetworkOverlayOpacity(_ sender: NSMenuItem) {
        guard let opacity = sender.representedObject as? Double else { return }
        monitor.setNetworkOverlayOpacity(opacity)
    }

    @objc private func setNetworkOverlayStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = NetworkOverlayStyle(rawValue: rawValue) else { return }
        monitor.setNetworkOverlayStyle(style)
    }

    @objc private func setNetworkOverlaySize(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let size = NetworkOverlaySize(rawValue: rawValue) else { return }
        monitor.setNetworkOverlaySize(size)
    }

    @objc private func setThresholdsMenuItem(_ sender: Any?) {
        let editorModel = ThresholdEditorModel(thresholds: monitor.thresholds)
        let accepted = presentSettingsPanel(
            title: "Set Thresholds",
            saveTitle: "Save",
            size: NSSize(width: 452, height: 640)
        ) {
            ThresholdEditorView(model: editorModel)
        }
        if accepted {
            monitor.setThresholds(editorModel.makeThresholds())
        }
    }

    @objc private func toggleStressBothMenuItem(_ sender: Any?) {
        if stressTester.mode == .cpuAndGPU {
            stressTester.stopAll()
        } else {
            stressTester.startCPUAndGPU()
        }
    }

    @objc private func configureDisplayItemsMenuItem(_ sender: Any?) {
        let visibleMetrics = monitor.metricOrder.filter { !monitor.hiddenMetrics.contains($0) }
        let hiddenMetrics = monitor.metricOrder.filter { monitor.hiddenMetrics.contains($0) }
        let editorModel = DisplayConfigEditorModel(
            visibleMetrics: visibleMetrics,
            hiddenMetrics: hiddenMetrics
        )
        let accepted = presentSettingsPanel(
            title: "Configure Display Items",
            saveTitle: "Save",
            size: NSSize(width: 456, height: 280)
        ) {
            DisplayConfigPanelView(model: editorModel)
        }
        if accepted {
            monitor.applyDisplayConfiguration(
                visibleMetrics: editorModel.visibleMetrics,
                hiddenMetrics: editorModel.hiddenMetrics
            )
        }
    }

    private func togglePopover(metric: MonitorMetric, sender: NSView, blockRect: CGRect?) {
        if popover.isShown {
            popover.close()
            if currentMetric == metric {
                currentMetric = nil
                return
            }
        }

        currentMetric = metric
        let detailsView = DetailPopupView(metric: metric, monitor: monitor)
        popover.contentViewController = NSHostingController(rootView: detailsView)
        NSApp.activate(ignoringOtherApps: true)

        if let hosting = menuHostingView, let blockRect {
            hosting.layoutSubtreeIfNeeded()
            let anchor = NSRect(x: blockRect.origin.x, y: blockRect.origin.y, width: blockRect.size.width, height: blockRect.size.height)
            popover.show(relativeTo: anchor, of: hosting, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            return
        }

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func setIntervalMenuItem(_ sender: Any?) {
        let editorModel = IntervalEditorModel(currentValue: monitor.intervalMs)
        let accepted = presentSettingsPanel(
            title: "Set Interval",
            saveTitle: "Apply",
            size: NSSize(width: 352, height: 320)
        ) {
            IntervalEditorView(model: editorModel)
        }
        if accepted {
            let raw = editorModel.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ms = Int(raw), ms >= 1 {
                monitor.setInterval(ms: ms)
            }
        }
    }

    @objc private func quitMenuItem(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // Reuse one lightweight floating panel shell for the small settings windows opened
    // from the status item menu.
    private func presentSettingsPanel<Content: View>(
        title: String,
        saveTitle: String,
        size: NSSize,
        @ViewBuilder content: () -> Content
    ) -> Bool {
        var accepted = false
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.isOpaque = false
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = SettingsPanelContainer(
            saveTitle: saveTitle,
            onCancel: {
                accepted = false
                NSApp.stopModal()
                panel.orderOut(nil)
            },
            onSave: {
                accepted = true
                NSApp.stopModal()
                panel.orderOut(nil)
            },
            content: content()
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        return accepted
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        // macOS 27 right-click is handled by global/local monitors.
        // Fallback for macOS <= 26 if rightMouseUp still reaches here:
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            if let button = statusItem?.button {
                rebuildStatusMenu()
                NSApp.activate(ignoringOtherApps: true)
                let menuPoint = NSPoint(x: button.bounds.midX, y: button.bounds.maxY)
                statusMenu?.popUp(positioning: nil, at: menuPoint, in: button)
            }
        } else if let button = statusItem?.button {
            var clickedMetric: MonitorMetric? = nil
            var clickedRect: CGRect? = nil
            
            if let window = button.window {
                let globalMouse = NSEvent.mouseLocation
                let locationInWindow = window.convertPoint(fromScreen: globalMouse)
                let locationInButton = button.convert(locationInWindow, from: nil)
                
                for (metric, frame) in metricFrames {
                    // Only check X coordinate because Y axis is inverted
                    // SwiftUI menuHostingSpace X perfectly aligns with button X
                    if locationInButton.x >= frame.minX && locationInButton.x <= frame.maxX {
                        clickedMetric = metric
                        clickedRect = frame
                        break
                    }
                }
            }
            
            let finalMetric = clickedMetric ?? currentMetric ?? monitor.orderedVisibleMetrics.first ?? .cpu
            togglePopover(metric: finalMetric, sender: button, blockRect: clickedRect)
        }
    }

    // Lazily create the overlay window and keep its visual settings in sync with config.
    private func updateNetworkOverlayPanel() {
        let settings = monitor.networkOverlaySettings
        guard settings.isEnabled else {
            if let overlayMoveObserver {
                NotificationCenter.default.removeObserver(overlayMoveObserver)
                self.overlayMoveObserver = nil
            }
            networkOverlayPanel?.orderOut(nil)
            networkOverlayPanel = nil
            return
        }

        if networkOverlayPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 66),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            networkOverlayPanel = panel
            if let originX = settings.originX, let originY = settings.originY {
                panel.setFrameOrigin(NSPoint(x: originX, y: originY))
            } else {
                panel.center()
            }
            // Persist the floating overlay position whenever the user drags it.
            overlayMoveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                guard let self, let panel = self.networkOverlayPanel else { return }
                self.monitor.setNetworkOverlayOrigin(panel.frame.origin)
            }
        }

        refreshNetworkOverlayContent()
        networkOverlayPanel?.alphaValue = settings.opacity
        networkOverlayPanel?.ignoresMouseEvents = settings.clickThrough
        networkOverlayPanel?.orderFrontRegardless()
    }

    // Each overlay skin computes a different ideal size, so resize the hosting panel
    // whenever data or appearance settings change.
    private func refreshNetworkOverlayContent() {
        guard let panel = networkOverlayPanel else { return }
        let rootView = NetworkOverlayView(monitor: monitor)
        let hostingView = OverlayHostingView(rootView: rootView)
        hostingView.onRightClick = { [weak self] event, view in
            self?.showNetworkOverlayMenu(event: event, in: view)
        }
        let fittingSize = hostingView.fittingSize
        let newFrame = NSRect(origin: panel.frame.origin, size: NSSize(width: fittingSize.width, height: fittingSize.height))
        panel.setFrame(newFrame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        panel.contentView = hostingView
        panel.alphaValue = monitor.networkOverlaySettings.opacity
        panel.ignoresMouseEvents = monitor.networkOverlaySettings.clickThrough
    }

    private func showNetworkOverlayMenu(event: NSEvent, in view: NSView) {
        let menu = makeNetworkOverlayMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
