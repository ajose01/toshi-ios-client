// Copyright (c) 2018 Token Browser, Inc
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

import UIKit
import UserNotifications
import CameraScanner

let TabBarItemTitleOffset: CGFloat = -3.0

class TabBarController: UITabBarController, OfflineAlertDisplaying {
    let offlineAlertView = defaultOfflineAlertView()

    var paymentRouter: PaymentRouter?
    var paidUserInfo: ProfileInfo?

    enum Tab: Int {
        case browsing
        case messaging
        case wallet
        case me
    }

    var currentNavigationController: UINavigationController? {
        return selectedViewController as? UINavigationController
    }

    private var chatAPIClient: ChatAPIClient {
        return ChatAPIClient.shared
    }

    private var idAPIClient: IDAPIClient {
        return IDAPIClient.shared
    }

    private(set) lazy var reachabilityManager: ReachabilityManager = {
        let reachabilityManager = ReachabilityManager()
        reachabilityManager.delegate = self

        return reachabilityManager
    }()

    lazy var scannerController: ScannerViewController = {
        let controller = ScannerController(instructions: Localized.qr_scanner_instructions, types: [.qrCode])
        controller.delegate = self

        return controller
    }()

    lazy var messagingController: ChatsNavigationController = {
        let chatsViewController = ChatsViewController(style: .grouped, target: .chatsMainPage)
        let messagingController = ChatsNavigationController(rootViewController: chatsViewController)

        if Yap.isUserSessionSetup, let address = UserDefaultsWrapper.selectedThreadAddress, let thread = chatsViewController.thread(withAddress: address) {
            messagingController.viewControllers = [chatsViewController, ChatViewController(thread: thread)]
        }

        return messagingController
    }()

    lazy var dappsViewController = DappsNavigationController(rootViewController: DappsViewController())
    lazy var settingsController = SettingsNavigationController(rootViewController: SettingsController())
    lazy var walletController = WalletNavigationController(rootViewController: WalletViewController())

    init() {
        super.init(nibName: nil, bundle: nil)

        delegate = self
        reachabilityManager.register()

        setupOfflineAlertView(hidden: true)
        tabBar.accessibilityIdentifier = AccessibilityIdentifier.mainTabBar.rawValue
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not implemented here")
    }

    @objc func setupControllers() {
        viewControllers = [
            self.dappsViewController,
            self.messagingController,
            self.walletController,
            self.settingsController
        ]

        view.tintColor = Theme.tintColor
        view.backgroundColor = Theme.viewBackgroundColor

        tabBar.barTintColor = Theme.viewBackgroundColor
        tabBar.unselectedItemTintColor = Theme.unselectedItemTintColor

        selectedIndex = UserDefaultsWrapper.tabBarSelectedIndex
    }

    func openPaymentMessage(to address: String, parameters: [String: Any]? = nil, transaction: String?) {
        dismiss(animated: false) {

            ChatInteractor.getOrCreateThread(for: address)

            DispatchQueue.main.async {
                self.displayMessage(forAddress: address) { controller in
                    if let chatViewController = controller as? ChatViewController, let parameters = parameters {
                        chatViewController.sendPayment(with: parameters, transaction: transaction)
                    }
                }
            }
        }
    }

    func displayMessage(forAddress address: String, forBot: Bool = false, completion: ((Any?) -> Void)? = nil) {
        if let index = viewControllers?.index(of: messagingController) {
            selectedIndex = index
        }

        messagingController.openThread(withAddress: address, forBot: forBot, completion: completion)
    }

    public func openThread(_ thread: TSThread, animated: Bool = true) {
        messagingController.openThread(thread, animated: animated)
    }

    func `switch`(to tab: Tab) {
        selectedIndex = tab.rawValue
    }

    func triggerWalletTabReloadIfNeeded(basedOn userInfo: [AnyHashable: Any]) {

        guard WalletDatasource.shouldReload(basedOn: userInfo) else { return }

        guard let walletViewController = walletController.viewControllers.first as? WalletViewController else { return }
        weak var weakController = walletViewController
        walletViewController.triggerReload { success in

            guard success else { return }
            weakController?.restartTimerIfNeeded()
        }
    }

    @objc func openDeepLinkURL(_ url: URL) {
        if url.user == "username" {
            guard let username = url.host else { return }

            idAPIClient.retrieveUser(username: username) { [weak self] profile, _ in
                guard let profile = profile else { return }
                
                let contactController = ProfileViewController(profile: profile)
                (self?.selectedViewController as? UINavigationController)?.pushViewController(contactController, animated: true)
            }
        }
    }
}

extension TabBarController: UITabBarControllerDelegate {

    func tabBarController(_: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController != dappsViewController {

            guard let dappsViewController = dappsViewController.viewControllers.first as? DappsViewController else { return true }

            // Dismiss search on Dapps controller ?
            dappsViewController.navigationController?.popToRootViewController(animated: false)
        }

        guard viewController != walletController,
            let walletViewController = walletController.viewControllers.first as? WalletViewController else { return true }
        walletViewController.invalidateReloadIfNeeded()

        return true
    }

    func tabBarController(_: UITabBarController, didSelect viewController: UIViewController) {
        SoundPlayer.playSound(type: .menuButton)

        automaticallyAdjustsScrollViewInsets = viewController.automaticallyAdjustsScrollViewInsets

        if let index = self.viewControllers?.index(of: viewController) {
            UserDefaultsWrapper.tabBarSelectedIndex = index
        }
    }
}

extension TabBarController: ScannerViewControllerDelegate {

    func scannerViewControllerDidCancel(_: ScannerViewController) {
        dismiss(animated: true)
    }

    func scannerViewController(_ controller: ScannerViewController, didScanResult result: String) {
        
        guard reachabilityManager.reachability?.currentReachabilityStatus != .notReachable else {
            let alert = UIAlertController(title: Localized.error_alert_title, message: Localized.offline_alert_message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Localized.alert_ok_action_title, style: .cancel, handler: { _ in
                self.scannerController.startScanning()
            }))
            
            Navigator.presentModally(alert)
            
            return
        }
        
        if let intent = QRCodeIntent(result: result) {
            switch intent {
            case .webSignIn(let loginToken):
                idAPIClient.adminLogin(loginToken: loginToken) {[weak self] _, _ in
                    SoundPlayer.playSound(type: .scanned)
                    self?.dismiss(animated: true)
                }
            case .paymentRequest(let weiValue, let address, let username, _):

                let valueInWei = NSDecimalNumber(hexadecimalString: weiValue)
                let fiatValueString = EthereumConverter.fiatValueString(forWei: valueInWei, exchangeRate: ExchangeRateClient.exchangeRate)
                let ethValueString = EthereumConverter.ethereumValueString(forWei: valueInWei)

                if let username = username {
                    let confirmationText = String(format: Localized.payment_request_confirmation_warning_message, fiatValueString, ethValueString, username)
                    proceedToPayment(username: username, weiValue: weiValue, confirmationText: confirmationText)
                } else if let address = address {
                    let confirmationText = String(format: Localized.payment_request_confirmation_warning_message, fiatValueString, ethValueString, address)
                    proceedToPayment(address: address, weiValue: weiValue, confirmationText: confirmationText)
                }
            default:
                scannerController.startScanning()
            }
        } else {
            scannerController.startScanning()
        }
    }

    private func proceedToPayment(address: String, weiValue: String?, confirmationText: String) {
        let userInfo = ProfileInfo(address: address, paymentAddress: address, avatarPath: nil, name: nil, username: address, isLocal: false)
        var parameters = [PaymentParameters.from: Cereal.shared.paymentAddress, PaymentParameters.to: address]
        parameters[PaymentParameters.value] = weiValue

        proceedToPayment(userInfo: userInfo, parameters: parameters, confirmationText: confirmationText)
    }

    private func proceedToPayment(username: String, weiValue: String?, confirmationText: String) {
        idAPIClient.retrieveUser(username: username) { [weak self] profile, _ in
            if let profile = profile, let paymentAddress = profile.paymentAddress, let validWeiValue = weiValue {
                let parameters = [PaymentParameters.from: Cereal.shared.paymentAddress,
                                  PaymentParameters.to: paymentAddress,
                                  PaymentParameters.value: validWeiValue]

                self?.proceedToPayment(userInfo: profile.userInfo, parameters: parameters, confirmationText: confirmationText)
            } else {
                self?.scannerController.startScanning()
            }
        }
    }

    private func proceedToPayment(userInfo: ProfileInfo, parameters: [String: Any], confirmationText: String) {

        self.paidUserInfo = userInfo

        if let scannerController = self.scannerController as? ScannerController {
            scannerController.setStatusBarHidden()

            SoundPlayer.playSound(type: .scanned)

            self.paymentRouter = PaymentRouter(parameters: parameters)
            self.paymentRouter?.delegate = self
            self.paymentRouter?.present()

        } else {
            scannerController.startScanning()
        }
    }
}

extension TabBarController: PaymentRouterDelegate {

    func paymentRouterDidSucceedPayment(_ paymentRouter: PaymentRouter, parameters: [String: Any], transactionHash: String?, unsignedTransaction: String?, recipientInfo: ProfileInfo?, error: ToshiError?) {
        scannerController.startScanning()
    }
}

extension TabBarController: ReachabilityDelegate {
    func reachabilityDidChange(toConnected connected: Bool) {

        if connected {
            hideOfflineAlertView()
        } else {
            showOfflineAlertView()
        }
    }
}
