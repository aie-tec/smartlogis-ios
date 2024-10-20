// Copyright (c) 2010-2024 Contributors to the openHAB project
//
// See the NOTICE file(s) distributed with this work for additional
// information.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0
//
// SPDX-License-Identifier: EPL-2.0

import Alamofire
import AVFoundation
import AVKit
import Combine
import Kingfisher
import OpenHABCore
import os.log
import SafariServices
import SVGKit
import SwiftUI
import UIKit

enum Action<I, O> {
    typealias Sync = (UIViewController, I) -> O
    typealias Async = (UIViewController, I, @escaping (O) -> Void) -> Void
}

struct OpenHABImageProcessor: ImageProcessor {
    // `identifier` should be the same for processors with the same properties/functionality
    // It will be used when storing and retrieving the image to/from cache.
    let identifier = "org.openhab.svgprocessor"

    // Convert input data/image to target image and return it.
    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        switch item {
        case let .image(image):
            os_log("already an image", log: .default, type: .info)
            return image
        case let .data(data):
            guard !data.isEmpty else { return nil }

            switch data[0] {
            case 0x3C: // svg
                // <?xml version="1.0" encoding="UTF-8"?>
                // <svg
                let svgkSourceNSData = SVGKSourceNSData.source(from: data, urlForRelativeLinks: nil)
                let parseResults = SVGKParser.parseSource(usingDefaultSVGKParser: svgkSourceNSData)
                if parseResults?.parsedDocument != nil, let image = SVGKImage(parsedSVG: parseResults, from: svgkSourceNSData), image.hasSize() {
                    if image.size.width > 1000 || image.size.height > 1000 {
                        return UIImage(systemSymbol: .exclamationmarkTriangle).withTintColor(.orange)
                    }
                    return image.uiImage
                } else {
                    return UIImage(systemSymbol: .exclamationmarkTriangle).withTintColor(.orange)
                }
            default:
                return Kingfisher.DefaultImageProcessor().process(item: item, options: KingfisherParsedOptionsInfo(KingfisherManager.shared.defaultOptions))
            }
        }
    }
}

class OpenHABSitemapViewController: OpenHABViewController, GenericUITableViewCellTouchEventDelegate {
    var pageUrl = ""
    private var selectedWidgetRow: Int = 0
    private var currentPageOperation: Alamofire.Request?
    private var commandOperation: Alamofire.Request?
    private var iconType: IconType = .png
    private var openHABRootUrl = ""
    private var openHABUsername = ""
    private var openHABPassword = ""
    private var openHABAlwaysSendCreds = false
    private var defaultSitemap = ""
    private var idleOff = false
    private var sitemaps: [OpenHABSitemap] = []
    private var currentPage: OpenHABSitemapPage?
    private var selectionPicker: UIPickerView?
    private var pageNetworkStatus: NetworkReachabilityManager.NetworkReachabilityStatus?
    private var pageNetworkStatusAvailable = false
    private var toggle: Int = 0
    private var refreshControl: UIRefreshControl?
    private var filteredPage: OpenHABSitemapPage?
    private var serverProperties: OpenHABServerProperties?
    private let search = UISearchController(searchResultsController: nil)
    private var isUserInteracting = false
    private var isWaitingToReload = false
    private let logger = Logger(subsystem: "org.openhab.app", category: "OpenHABSitemapViewController")

    var relevantPage: OpenHABSitemapPage? {
        if isFiltering {
            filteredPage
        } else {
            currentPage
        }
    }

    // App wide data access
    // https://stackoverflow.com/questions/45832155/how-do-i-refactor-my-code-to-call-appdelegate-on-the-main-thread
    var appData: OpenHABDataObject? {
        AppDelegate.appDelegate.appData
    }

    // MARK: - Private instance methods

    var searchBarIsEmpty: Bool {
        // Returns true if the text is empty or nil
        search.searchBar.text?.isEmpty ?? true
    }

    var isFiltering: Bool {
        search.isActive && !searchBarIsEmpty
    }

    @IBOutlet private var widgetTableView: UITableView!

    // Here goes everything about view loading, appearing, disappearing, entering background and becoming active
    override func viewDidLoad() {
        super.viewDidLoad()
        os_log("OpenHABSitemapViewController viewDidLoad", log: .default, type: .info)

        pageNetworkStatus = nil
        sitemaps = []
        widgetTableView.tableFooterView = UIView()

        registerTableViewCells()
        configureTableView()

        refreshControl = UIRefreshControl()

        refreshControl?.addTarget(self, action: #selector(OpenHABSitemapViewController.handleRefresh(_:)), for: .valueChanged)
        if let refreshControl {
            widgetTableView.refreshControl = refreshControl
        }

        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = NSLocalizedString("search_items", comment: "")
        definesPresentationContext = true

        #if DEBUG
        // setup accessibilityIdentifiers for UITest
        widgetTableView.accessibilityIdentifier = "OpenHABSitemapViewControllerWidgetTableView"
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        os_log("OpenHABSitemapViewController viewDidAppear", log: .viewCycle, type: .info)
        super.viewDidAppear(animated)

        // NOTE: workaround for https://github.com/openhab/openhab-ios/issues/420
        if parent?.navigationItem.searchController == nil {
            DispatchQueue.main.async {
                self.parent?.navigationItem.searchController = self.search
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        os_log("OpenHABSitemapViewController viewWillAppear", log: .viewCycle, type: .info)
        super.viewWillAppear(animated)

        navigationController?.navigationBar.prefersLargeTitles = true

        // Load settings into local properties
        loadSettings()
        // Disable idle timeout if configured in settings
        if idleOff {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        NetworkTracker.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { status in
                os_log("OpenHABViewController tracker status %{PUBLIC}@", log: .viewCycle, type: .info, status.rawValue)
                switch status {
                case .connecting:
                    self.showPopupMessage(seconds: 1.5, title: NSLocalizedString("connecting", comment: ""), message: "", theme: .info)
                case .notConnected:
                    os_log("Tracking error", log: .viewCycle, type: .info)
                    self.showPopupMessage(seconds: 60, title: NSLocalizedString("error", comment: ""), message: NSLocalizedString("network_not_available", comment: ""), theme: .error)
                case _:
                    break
                }
            }
            .store(in: &trackerCancellables)

        var activeServerWatcher = NetworkTracker.shared.$activeConnection.eraseToAnyPublisher()
        // if pageUrl == "" it means we are the first opened OpenHABSitemapViewController
        if pageUrl == "" {
            // Set self as root view controller
            appData?.sitemapViewController = self
            if currentPage != nil {
                currentPage?.widgets = []
                widgetTableView.reloadData()
            }
            os_log("OpenHABSitemapViewController pageUrl is empty, this is first launch", log: .viewCycle, type: .info)
        } else {
            // we only want to our watcher to notify us about changes, and not the inital value
            activeServerWatcher = activeServerWatcher.dropFirst().eraseToAnyPublisher()
            if !pageNetworkStatusChanged() {
                os_log("OpenHABSitemapViewController pageUrl = %{PUBLIC}@", log: .notifications, type: .info, pageUrl)
                loadPage(false)
            } else {
                os_log("OpenHABSitemapViewController network status changed while I was not appearing", log: .viewCycle, type: .info)
                restart()
            }
        }
        // listen for network changes, if stateWatcher.dropFirst() was NOT called, then this will exectue imediately with current values and then again if the network changes, otherwise it will be called on changes only.
        activeServerWatcher
            .receive(on: DispatchQueue.main)
            .sink { activeConnection in
                if let activeConnection {
                    os_log("OpenHABSitemapViewController tracker URL %{PUBLIC}@", log: .viewCycle, type: .info, activeConnection.configuration.url)
                    self.openHABRootUrl = activeConnection.configuration.url
                    self.selectSitemap()
                }
            }
            .store(in: &trackerCancellables)

        ImageDownloader.default.authenticationChallengeResponder = self
    }

    override func viewWillDisappear(_ animated: Bool) {
        os_log("OpenHABSitemapViewController viewWillDisappear", log: .viewCycle, type: .info)
        if currentPageOperation != nil {
            currentPageOperation?.cancel()
            currentPageOperation = nil
        }

        trackerCancellables.removeAll()

        super.viewWillDisappear(animated)

        if #unavailable(iOS 13.0) {
            if animated, !search.isActive, !search.isEditing, navigationController.map({ $0.viewControllers.last != self }) ?? false,
               let searchBarSuperview = search.searchBar.superview,
               let searchBarHeightConstraint = searchBarSuperview.constraints.first(where: {
                   $0.firstAttribute == .height
                       && $0.secondItem == nil
                       && $0.secondAttribute == .notAnAttribute
                       && $0.constant > 0
               }) {
                UIView.performWithoutAnimation {
                    searchBarHeightConstraint.constant = 0
                    searchBarSuperview.superview?.layoutIfNeeded()
                }
            }
        }
        parent?.navigationItem.searchController = nil
    }

    @objc
    override func didEnterBackground(_ notification: Notification?) {
        super.didEnterBackground(notification)
        os_log("OpenHABSitemapViewController didEnterBackground", log: .viewCycle, type: .info)
        if currentPageOperation != nil {
            currentPageOperation?.cancel()
            currentPageOperation = nil
        }
    }

    @objc
    override func didBecomeActive(_ notification: Notification?) {
        super.didBecomeActive(notification)
        os_log("OpenHABSitemapViewController didBecomeActive", log: .viewCycle, type: .info)
        if isViewLoaded, view.window != nil, !pageUrl.isEmpty {
            if !pageNetworkStatusChanged() {
                os_log("OpenHABSitemapViewController isViewLoaded, restarting network activity", log: .viewCycle, type: .info)
                loadPage(false)
            } else {
                os_log("OpenHABSitemapViewController network status changed while it was inactive", log: .viewCycle, type: .info)
                restart()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        widgetTableView.reloadData()
    }

    /// Implementation of GenericUITableViewCellTouchEventDelegate
    func touchDown() {
        isUserInteracting = true
    }

    /// Implementation of GenericUITableViewCellTouchEventDelegate
    func touchUp() {
        isUserInteracting = false
        if isWaitingToReload {
            widgetTableView.reloadData()
            refreshControl?.endRefreshing()
        }
        isWaitingToReload = false
    }

    func configureTableView() {
        widgetTableView.dataSource = self
        widgetTableView.delegate = self
    }

    func registerTableViewCells() {
        widgetTableView.register(cellType: MapViewTableViewCell.self)
        widgetTableView.register(cellType: NewImageUITableViewCell.self)
        widgetTableView.register(cellType: VideoUITableViewCell.self)
    }

    @objc
    func handleRefresh(_ refreshControl: UIRefreshControl?) {
        loadPage(false)
        widgetTableView.reloadData()
        widgetTableView.layoutIfNeeded()
    }

    func restart() {
        if appData?.sitemapViewController == self {
            os_log("I am a rootViewController!", log: .viewCycle, type: .info)

        } else {
            appData?.sitemapViewController?.pageUrl = ""
            navigationController?.popToRootViewController(animated: true)
        }
    }

    func relevantWidget(indexPath: IndexPath) -> OpenHABWidget? {
        relevantPage?.widgets[safe: indexPath.row]
    }

    private func updateWidgetTableView() {
        UIView.performWithoutAnimation {
            widgetTableView.beginUpdates()
            widgetTableView.endUpdates()
        }
    }

    // load our page and show it into UITableView
    func loadPage(_ longPolling: Bool) {
        if currentPageOperation != nil {
            currentPageOperation?.cancel()
            currentPageOperation = nil
        }

        if pageUrl == "" {
            return
        }
        os_log("pageUrl = %{PUBLIC}@", log: OSLog.remoteAccess, type: .info, pageUrl)

        // If this is the first request to the page make a bulk call to pageNetworkStatusChanged
        // to save current reachability status.
        if !longPolling {
            _ = pageNetworkStatusChanged()
        }

        currentPageOperation = NetworkConnection.page(
            pageUrl: pageUrl,
            longPolling: longPolling
        ) { [weak self] response in
            guard let self else { return }

            switch response.result {
            case let .success(data):
                os_log("Page loaded with success", log: OSLog.remoteAccess, type: .info)
                let headers = response.response?.allHeaderFields

                NetworkConnection.atmosphereTrackingId = headers?["X-Atmosphere-tracking-id"] as? String ?? ""
                if !NetworkConnection.atmosphereTrackingId.isEmpty {
                    os_log("Found X-Atmosphere-tracking-id: %{PUBLIC}@", log: .remoteAccess, type: .info, NetworkConnection.atmosphereTrackingId)
                }
                var openHABSitemapPage: OpenHABSitemapPage?
                do {
                    // Self-executing closure
                    // Inspired by https://www.swiftbysundell.com/posts/inline-types-and-functions-in-swift
                    openHABSitemapPage = try {
                        let sitemapPageCodingData = try data.decoded(as: OpenHABSitemapPage.CodingData.self)
                        return sitemapPageCodingData.openHABSitemapPage
                    }()
                } catch {
                    // Printing the error is the only way to actually get the real issue, localizedDescription is pretty useless here
                    print(error)
                    os_log("Should not throw %{PUBLIC}@", log: OSLog.remoteAccess, type: .error, error.localizedDescription)
                    DispatchQueue.main.async {
                        self.showPopupMessage(seconds: 5, title: NSLocalizedString("error", comment: ""), message: error.localizedDescription, theme: .error)
                    }
                }

                currentPage = openHABSitemapPage
                if isFiltering {
                    filterContentForSearchText(search.searchBar.text)
                }

                currentPage?.sendCommand = { [weak self] item, command in
                    self?.sendCommand(item, commandToSend: command)
                }
                // isUserInteracting fixes https://github.com/openhab/openhab-ios/issues/646 where reloading while the user is interacting can have unintended consequences
                if !isUserInteracting {
                    widgetTableView.reloadData()
                    refreshControl?.endRefreshing()
                } else {
                    isWaitingToReload = true
                }
                parent?.navigationItem.title = currentPage?.title.components(separatedBy: "[")[0]

                loadPage(true)
            case let .failure(error):
                os_log("On LoadPage \"%{PUBLIC}@\" code: %d ", log: .remoteAccess, type: .error, error.localizedDescription, response.response?.statusCode ?? 0)

                NetworkConnection.atmosphereTrackingId = ""
                if (error as NSError?)?.code == -1001, longPolling {
                    os_log("Timeout, restarting requests", log: OSLog.remoteAccess, type: .error)
                    loadPage(false)
                } else if error.isExplicitlyCancelledError {
                    os_log("Request was cancelled", log: OSLog.remoteAccess, type: .error)
                } else {
                    // Error
                    DispatchQueue.main.async {
                        if (error as NSError?)?.code == -1012 {
                            self.showPopupMessage(seconds: 5, title: NSLocalizedString("error", comment: ""), message: NSLocalizedString("ssl_certificate_error", comment: ""), theme: .error)
                        } else {
                            self.showPopupMessage(seconds: 5, title: NSLocalizedString("error", comment: ""), message: error.localizedDescription, theme: .error)
                        }
                    }
                }
            }
        }

        currentPageOperation?.resume()

        os_log("OpenHABSitemapViewController request sent", log: .remoteAccess, type: .error)
    }

    // Select sitemap
    func selectSitemap() {
        NetworkConnection.sitemaps(openHABRootUrl: openHABRootUrl) { response in
            switch response.result {
            case let .success(data):
                self.sitemaps = deriveSitemaps(data)
                switch self.sitemaps.count {
                case 2...:
                    if !self.defaultSitemap.isEmpty {
                        if let sitemapToOpen = self.sitemap(byName: self.defaultSitemap) {
                            if self.currentPage?.pageId != sitemapToOpen.name {
                                self.currentPage?.widgets.removeAll() // NOTE: remove all widgets to ensure cells get invalidated
                            }
                            self.pageUrl = sitemapToOpen.homepageLink
                            self.loadPage(false)
                        } else {
                            self.showSideMenu()
                        }
                    } else {
                        self.showSideMenu()
                    }
                case 1:
                    self.pageUrl = self.sitemaps[0].homepageLink
                    self.loadPage(false)
                case ...0:
                    self.showPopupMessage(seconds: 5, title: NSLocalizedString("warning", comment: ""), message: NSLocalizedString("empty_sitemap", comment: ""), theme: .warning)
                    self.showSideMenu()
                default: break
                }
                self.widgetTableView.reloadData()
            case let .failure(error):
                os_log("%{PUBLIC}@ %d", log: .default, type: .error, error.localizedDescription, response.response?.statusCode ?? 0)
                DispatchQueue.main.async {
                    // Error
                    if (error as NSError?)?.code == -1012 {
                        self.showPopupMessage(seconds: 5, title: NSLocalizedString("error", comment: ""), message: NSLocalizedString("ssl_certificate_error", comment: ""), theme: .error)
                    } else {
                        self.showPopupMessage(seconds: 5, title: NSLocalizedString("error", comment: ""), message: error.localizedDescription, theme: .error)
                    }
                }
            }
        }
    }

    // This is mainly used for navigting to a specific sitemap and path from notifications
    func pushSitemap(name: String, path: String?) {
        // this will be called imediately after connecting for the initial state, otherwise it will wait for the state to change
        // since we do not reference the sink cancelable, this will only fire once
        NetworkTracker.shared.waitForActiveConnection { activeConnection in
            if let openHABUrl = activeConnection?.configuration.url {
                os_log("pushSitemap: pushing page", log: .default, type: .error)
                let newViewController = (self.storyboard?.instantiateViewController(withIdentifier: "OpenHABPageViewController") as? OpenHABSitemapViewController)!
                if let path {
                    newViewController.pageUrl = "\(openHABUrl)/rest/sitemaps/\(name)/\(path)"
                } else {
                    newViewController.pageUrl = "\(openHABUrl)/rest/sitemaps/\(name)"
                }
                newViewController.openHABRootUrl = openHABUrl
                self.navigationController?.pushViewController(newViewController, animated: true)
            }
        }
        .store(in: &trackerCancellables)
    }

    // load app settings
    func loadSettings() {
        openHABUsername = Preferences.username
        openHABPassword = Preferences.password
        openHABAlwaysSendCreds = Preferences.alwaysSendCreds
        defaultSitemap = Preferences.defaultSitemap
        idleOff = Preferences.idleOff
        iconType = IconType(rawValue: Preferences.iconType) ?? .png

        appData?.openHABUsername = openHABUsername
        appData?.openHABPassword = openHABPassword
        appData?.openHABAlwaysSendCreds = openHABAlwaysSendCreds

        #if DEBUG
        // always use demo sitemap for UITest
        if ProcessInfo.processInfo.environment["UITest"] != nil {
            defaultSitemap = "demo"
            iconType = .png
        }
        #endif
    }

    // Find and return sitemap by it's name if any
    func sitemap(byName sitemapName: String?) -> OpenHABSitemap? {
        for sitemap in sitemaps where sitemap.name == sitemapName {
            return sitemap
        }
        return nil
    }

    func pageNetworkStatusChanged() -> Bool {
        os_log("OpenHABSitemapViewController pageNetworkStatusChange", log: .remoteAccess, type: .info)
        if !pageUrl.isEmpty {
            let pageReachability = NetworkReachabilityManager(host: pageUrl)
            if !pageNetworkStatusAvailable {
                pageNetworkStatus = pageReachability?.status
                pageNetworkStatusAvailable = true
                return false
            } else {
                if pageNetworkStatus == pageReachability?.status {
                    return false
                } else {
                    pageNetworkStatus = pageReachability?.status
                    return true
                }
            }
        }
        return false
    }

    func filterContentForSearchText(_ searchText: String?, scope: String = "All") {
        guard let searchText else { return }

        filteredPage = currentPage?.filter {
            $0.label.lowercased().contains(searchText.lowercased()) && $0.type != .frame
        }
        filteredPage?.sendCommand = { [weak self] item, command in
            self?.sendCommand(item, commandToSend: command)
        }
        widgetTableView.reloadData()
    }

    func sendCommand(_ item: OpenHABItem?, commandToSend command: String?) {
        if commandOperation != nil {
            commandOperation?.cancel()
            commandOperation = nil
        }
        if let item, let command {
            commandOperation = NetworkConnection.sendCommand(item: item, commandToSend: command)
            commandOperation?.resume()
        }
    }

    override func reloadView() {
        defaultSitemap = Preferences.defaultSitemap
        selectSitemap()
    }

    override func viewName() -> String {
        "sitemap"
    }
}

// MARK: - UISearchResultsUpdating

extension OpenHABSitemapViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        filterContentForSearchText(searchController.searchBar.text)
    }
}

// MARK: - ColorPickerCellDelegate

extension OpenHABSitemapViewController: ColorPickerCellDelegate {
    func didPressColorButton(_ cell: ColorPickerCell?) {
        let colorPickerViewController = storyboard?.instantiateViewController(withIdentifier: "ColorPickerViewController") as? ColorPickerViewController
        if let cell {
            let widget = relevantPage?.widgets[widgetTableView.indexPath(for: cell)?.row ?? 0]
            colorPickerViewController?.title = widget?.labelText
            colorPickerViewController?.widget = widget
        }
        if let colorPickerViewController {
            navigationController?.pushViewController(colorPickerViewController, animated: true)
        }
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource

extension OpenHABSitemapViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if currentPage != nil {
            if isFiltering {
                return filteredPage?.widgets.count ?? 0
            }
            return currentPage?.widgets.count ?? 0
        } else {
            return 0
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        44.0
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let widget: OpenHABWidget? = relevantPage?.widgets[indexPath.row]
        switch widget?.type {
        case .frame:
            return widget?.label.count ?? 0 > 0 ? 35.0 : 0
        case .image, .chart, .video:
            return UITableView.automaticDimension
        case .webview, .mapview:
            if let height = widget?.height {
                // calculate webview/mapview height and return it. Limited to UIScreen.main.bounds.height
                let heightValue = height * 44
                os_log("Webview/Mapview height would be %g", log: .viewCycle, type: .info, heightValue)
                return min(UIScreen.main.bounds.height, CGFloat(heightValue))
            } else {
                // return default height for webview/mapview as 8 rows
                return 44.0 * 8
            }
        default: return 44.0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let widget: OpenHABWidget? = relevantWidget(indexPath: indexPath)

        let cell: UITableViewCell

        switch widget?.type {
        case .frame:
            cell = tableView.dequeueReusableCell(for: indexPath) as FrameUITableViewCell
        case .switchWidget:
            // Reflecting the discussion held in https://github.com/openhab/openhab-core/issues/952
            if !(widget?.mappings ?? []).isEmpty {
                cell = tableView.dequeueReusableCell(for: indexPath) as SegmentedUITableViewCell
            } else if widget?.item?.isOfTypeOrGroupType(.switchItem) ?? false {
                cell = tableView.dequeueReusableCell(for: indexPath) as SwitchUITableViewCell
            } else if widget?.item?.isOfTypeOrGroupType(.rollershutter) ?? false {
                cell = tableView.dequeueReusableCell(for: indexPath) as RollershutterCell
            } else if !(widget?.mappingsOrItemOptions ?? []).isEmpty {
                cell = tableView.dequeueReusableCell(for: indexPath) as SegmentedUITableViewCell
            } else {
                cell = tableView.dequeueReusableCell(for: indexPath) as SwitchUITableViewCell
            }
        case .setpoint:
            cell = tableView.dequeueReusableCell(for: indexPath) as SetpointCell
        case .slider:
            if let switchSupport = widget?.switchSupport, switchSupport {
                cell = tableView.dequeueReusableCell(for: indexPath) as SliderWithSwitchSupportUITableViewCell
            } else {
                cell = tableView.dequeueReusableCell(for: indexPath) as SliderUITableViewCell
            }
        case .selection:
            cell = tableView.dequeueReusableCell(for: indexPath) as SelectionUITableViewCell
        case .colorpicker:
            cell = tableView.dequeueReusableCell(for: indexPath) as ColorPickerCell
            (cell as? ColorPickerCell)?.delegate = self
        case .image, .chart:
            cell = tableView.dequeueReusableCell(for: indexPath) as NewImageUITableViewCell
            (cell as? NewImageUITableViewCell)?.didLoad = { [weak self] in
                self?.updateWidgetTableView()
            }
        case .video:
            cell = tableView.dequeueReusableCell(for: indexPath) as VideoUITableViewCell
            (cell as? VideoUITableViewCell)?.didLoad = { [weak self] in
                self?.updateWidgetTableView()
            }
        case .webview:
            cell = tableView.dequeueReusableCell(for: indexPath) as WebUITableViewCell
        case .mapview:
            cell = tableView.dequeueReusableCell(for: indexPath) as MapViewTableViewCell
        case .group, .text:
            cell = tableView.dequeueReusableCell(for: indexPath) as GenericUITableViewCell
        default:
            cell = tableView.dequeueReusableCell(for: indexPath) as GenericUITableViewCell
        }

        var iconColor = widget?.iconColor
        if iconColor == nil || iconColor!.isEmpty, traitCollection.userInterfaceStyle == .dark {
            iconColor = "white"
        }
        // No icon is needed for image, video, frame and web widgets
        if widget?.icon != nil, !((cell is NewImageUITableViewCell) || (cell is VideoUITableViewCell) || (cell is FrameUITableViewCell) || (cell is WebUITableViewCell)) {
            if let urlc = Endpoint.icon(
                rootUrl: openHABRootUrl,
                version: appData?.openHABVersion ?? 2,
                icon: widget?.icon,
                state: widget?.iconState() ?? "",
                iconType: iconType,
                iconColor: iconColor!
            ).url {
                var imageRequest = URLRequest(url: urlc)
                imageRequest.timeoutInterval = 10.0
                cell.imageView?.kf.setImage(
                    with: KF.ImageResource(downloadURL: urlc, cacheKey: urlc.path + (urlc.query ?? "")),
                    placeholder: nil,
                    options: [.processor(OpenHABImageProcessor())]
                ) { result in
                    switch result {
                    case .success:
                        DispatchQueue.main.async {
                            cell.setNeedsLayout()
                        }
                    case let .failure(error):
                        os_log("Image loading failed: %{PUBLIC}@", log: .viewCycle, type: .error, error.localizedDescription)
                    }
                }
            }
        }

        if cell is FrameUITableViewCell {
            cell.backgroundColor = .ohSystemGroupedBackground
        } else {
            cell.backgroundColor = .ohSecondarySystemGroupedBackground
        }

        if let cell = cell as? GenericUITableViewCell {
            cell.widget = widget
            cell.displayWidget()
            cell.touchEventDelegate = self
        }

        // Check if this is not the last row in the widgets list
        if indexPath.row < (relevantPage?.widgets.count ?? 1) - 1 {
            let nextWidget: OpenHABWidget? = relevantPage?.widgets[indexPath.row + 1]
            if let type = nextWidget?.type, type.isAny(of: .frame, .image, .video, .webview, .chart) {
                cell.separatorInset = UIEdgeInsets.zero
            } else if !(widget?.type == .frame) {
                cell.separatorInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 0)
            }
        }

        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Prevent the cell from inheriting the Table View's margin settings
        cell.preservesSuperviewLayoutMargins = false

        // Explictly set your cell's layout margins
        cell.layoutMargins = .zero

        (cell as? VideoUITableViewCell)?.play()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let widget: OpenHABWidget? = relevantWidget(indexPath: indexPath)
        if widget?.linkedPage != nil {
            if let link = widget?.linkedPage?.link {
                os_log("Selected %{PUBLIC}@", log: .viewCycle, type: .info, link)
            }

            selectedWidgetRow = indexPath.row
            let newViewController = (storyboard?.instantiateViewController(withIdentifier: "OpenHABPageViewController") as? OpenHABSitemapViewController)!
            newViewController.title = widget?.linkedPage?.title.components(separatedBy: "[")[0]
            newViewController.pageUrl = widget?.linkedPage?.link ?? ""
            newViewController.openHABRootUrl = openHABRootUrl
            navigationController?.pushViewController(newViewController, animated: true)
        } else if widget?.type == .selection {
            selectedWidgetRow = indexPath.row
            let selectedWidget: OpenHABWidget? = relevantWidget(indexPath: indexPath)
            let selectionItemState = selectedWidget?.item?.state
            logger.info("Selected selection widget in status: \(selectionItemState ?? "unknown")")
            let hostingController = UIHostingController(rootView: SelectionView(
                mappings: selectedWidget?.mappingsOrItemOptions ?? [],
                selectionItemState: selectionItemState,
                onSelection: { selectedMappingIndex in
                    let selectedWidget: OpenHABWidget? = self.relevantPage?.widgets[self.selectedWidgetRow]
                    let selectedMapping: OpenHABWidgetMapping? = selectedWidget?.mappingsOrItemOptions[selectedMappingIndex]
                    self.sendCommand(selectedWidget?.item, commandToSend: selectedMapping?.command)
                }
            ))
            hostingController.title = widget?.labelText
            navigationController?.pushViewController(hostingController, animated: true)
        }
        if let index = widgetTableView.indexPathForSelectedRow {
            widgetTableView.deselectRow(at: index, animated: false)
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let cell = cell as? GenericCellCacheProtocol {
            // invalidate cache only if the cell is not visible or the datasource is empty (eg. sitemap change)
            if tableView.indexPathsForVisibleRows == nil || !tableView.indexPathsForVisibleRows!.contains(indexPath) || currentPage == nil || currentPage!.widgets.isEmpty {
                cell.invalidateCache()
            }
        }
    }

    @available(iOS 13.0, *)
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        if let cell = tableView.cellForRow(at: indexPath) as? GenericUITableViewCell, cell.widget.type == .text, let text = cell.widget?.labelValue ?? cell.widget?.labelText, !text.isEmpty {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                let copy = UIAction(title: NSLocalizedString("copy_label", comment: ""), image: UIImage(systemSymbol: .squareAndArrowUp)) { _ in
                    UIPasteboard.general.string = text
                }

                return UIMenu(title: "", children: [copy])
            }
        }

        return nil
    }
}

// MARK: Kingfisher authentication with NSURLCredential

extension OpenHABSitemapViewController: AuthenticationChallengeResponsible {
    // sessionDelegate.onReceiveSessionTaskChallenge
    func downloader(_ downloader: ImageDownloader,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = onReceiveSessionTaskChallenge(with: challenge)
        completionHandler(disposition, credential)
    }

    // sessionDelegate.onReceiveSessionChallenge
    func downloader(_ downloader: ImageDownloader,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = onReceiveSessionChallenge(with: challenge)
        completionHandler(disposition, credential)
    }
}
