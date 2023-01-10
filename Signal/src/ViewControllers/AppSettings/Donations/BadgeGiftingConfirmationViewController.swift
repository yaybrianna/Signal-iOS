//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import PassKit
import SignalMessaging
import SignalServiceKit
import UIKit

class BadgeGiftingConfirmationViewController: OWSTableViewController2 {
    typealias PaymentMethodsConfiguration = SubscriptionManager.DonationConfiguration.PaymentMethodsConfiguration

    // MARK: - View state

    private let badge: ProfileBadge
    private let price: FiatMoney
    private let paymentMethodsConfiguration: PaymentMethodsConfiguration
    private let thread: TSContactThread

    private var previouslyRenderedDisappearingMessagesDuration: UInt32?

    public init(
        badge: ProfileBadge,
        price: FiatMoney,
        paymentMethodsConfiguration: PaymentMethodsConfiguration,
        thread: TSContactThread
    ) {
        self.badge = badge
        self.price = price
        self.paymentMethodsConfiguration = paymentMethodsConfiguration
        self.thread = thread
    }

    private class func showRecipientIsBlockedError() {
        OWSActionSheets.showActionSheet(
            title: NSLocalizedString(
                "DONATION_ON_BEHALF_OF_A_FRIEND_RECIPIENT_IS_BLOCKED_ERROR_TITLE",
                comment: "Users can donate on a friend's behalf. This is the title for an error message that appears if the try to do this, but the recipient is blocked."
            ),
            message: NSLocalizedString(
                "DONATION_ON_BEHALF_OF_A_FRIEND_RECIPIENT_IS_BLOCKED_ERROR_BODY",
                comment: "Users can donate on a friend's behalf. This is the error message that appears if the try to do this, but the recipient is blocked."
            )
        )
    }

    // MARK: - Callbacks

    public override func viewDidLoad() {
        self.shouldAvoidKeyboard = true

        super.viewDidLoad()

        databaseStorage.appendDatabaseChangeDelegate(self)

        title = NSLocalizedString(
            "DONATION_ON_BEHALF_OF_A_FRIEND_CONFIRMATION_SCREEN_TITLE",
            comment: "Users can donate on a friend's behalf. This is the title on the screen where users confirm the donation, and can write a message for the friend."
        )

        updateTableContents()
        setUpBottomFooter()

        tableView.keyboardDismissMode = .onDrag
    }

    public override func themeDidChange() {
        super.themeDidChange()
        setUpBottomFooter()
    }

    private func isRecipientBlocked(transaction: SDSAnyReadTransaction) -> Bool {
        self.blockingManager.isAddressBlocked(self.thread.contactAddress, transaction: transaction)
    }

    private func isRecipientBlockedWithSneakyTransaction() -> Bool {
        databaseStorage.read { self.isRecipientBlocked(transaction: $0) }
    }

    /// Queries the database to see if the recipient can receive gift badges.
    private func canReceiveGiftBadgesViaDatabase() -> Bool {
        databaseStorage.read { transaction -> Bool in
            self.profileManager.getUserProfile(for: self.thread.contactAddress, transaction: transaction)?.canReceiveGiftBadges ?? false
        }
    }

    enum ProfileFetchError: Error { case timeout }

    /// Fetches the recipient's profile, then queries the database to see if they can receive gift badges.
    /// Times out after 30 seconds.
    private func canReceiveGiftBadgesViaProfileFetch() -> Promise<Bool> {
        firstly {
            ProfileFetcherJob.fetchProfilePromise(address: self.thread.contactAddress, ignoreThrottling: true)
        }.timeout(seconds: 30) {
            ProfileFetchError.timeout
        }.map { [weak self] _ in
            self?.canReceiveGiftBadgesViaDatabase() ?? false
        }
    }

    /// Look up whether the recipient can receive gift badges.
    /// If the operation takes more half a second, we show a spinner.
    /// We first consult the database.
    /// If they are capable there, we don't need to fetch their profile.
    /// If they aren't (or we have no profile saved), we fetch the profile because we might have stale data.
    private func canReceiveGiftBadgesWithUi() -> Promise<Bool> {
        if canReceiveGiftBadgesViaDatabase() {
            return Promise.value(true)
        }

        let (resultPromise, resultFuture) = Promise<Bool>.pending()

        ModalActivityIndicatorViewController.present(fromViewController: self,
                                                     canCancel: false,
                                                     presentationDelay: 0.5) { modal in
            firstly {
                self.canReceiveGiftBadgesViaProfileFetch()
            }.done(on: .main) { canReceiveGiftBadges in
                modal.dismiss { resultFuture.resolve(canReceiveGiftBadges) }
            }.catch(on: .main) { error in
                modal.dismiss { resultFuture.reject(error) }
            }
        }

        return resultPromise
    }

    private enum SafetyNumberConfirmationResult {
        case userDidNotConfirmSafetyNumberChange
        case userConfirmedSafetyNumberChangeOrNoChangeWasNeeded
    }

    private func showSafetyNumberConfirmationIfNecessary() -> (needsUserInteraction: Bool, promise: Promise<SafetyNumberConfirmationResult>) {
        let (promise, future) = Promise<SafetyNumberConfirmationResult>.pending()

        let needsUserInteraction = SafetyNumberConfirmationSheet.presentIfNecessary(address: thread.contactAddress,
                                                                                    confirmationText: SafetyNumberStrings.confirmSendButton) { didConfirm in
            future.resolve(didConfirm ? .userConfirmedSafetyNumberChangeOrNoChangeWasNeeded : .userDidNotConfirmSafetyNumberChange)
        }
        if needsUserInteraction {
            Logger.info("[Gifting] Showing safety number confirmation sheet")
        } else {
            Logger.info("[Gifting] Not showing safety number confirmation sheet; it was not needed")
            future.resolve(.userConfirmedSafetyNumberChangeOrNoChangeWasNeeded)
        }

        return (needsUserInteraction: needsUserInteraction, promise: promise)
    }

    private func checkRecipientAndPresentChoosePaymentMethodSheet() {
        // We want to resign this SOMETIME before this VC dismisses and switches to the chat.
        // In addition to offering slightly better UX, resigning first responder status prevents it
        // from eating events after the VC is dismissed.
        messageTextView.resignFirstResponder()

        guard !isRecipientBlockedWithSneakyTransaction() else {
            Logger.warn("[Gifting] Not requesting Apple Pay because recipient is blocked")
            Self.showRecipientIsBlockedError()
            return
        }

        firstly(on: .main) { [weak self] () -> Promise<Bool> in
            guard let self = self else {
                throw SendGiftBadgeError.userCanceledBeforeChargeCompleted
            }
            return self.canReceiveGiftBadgesWithUi()
        }.then(on: .main) { [weak self] canReceiveGiftBadges -> Promise<SafetyNumberConfirmationResult> in
            guard let self = self else {
                throw SendGiftBadgeError.userCanceledBeforeChargeCompleted
            }
            guard canReceiveGiftBadges else {
                throw SendGiftBadgeError.cannotReceiveGiftBadges
            }
            return self.showSafetyNumberConfirmationIfNecessary().promise
        }.done(on: .main) { [weak self] safetyNumberConfirmationResult in
            guard let self = self else {
                throw SendGiftBadgeError.userCanceledBeforeChargeCompleted
            }

            switch safetyNumberConfirmationResult {
            case .userDidNotConfirmSafetyNumberChange:
                throw SendGiftBadgeError.userCanceledBeforeChargeCompleted
            case .userConfirmedSafetyNumberChangeOrNoChangeWasNeeded:
                break
            }

            let recipientFullName = self.databaseStorage.read { transaction in
                self.contactsManager.displayName(for: self.thread, transaction: transaction)
            }

            let sheet = DonateChoosePaymentMethodSheet(
                amount: self.price,
                badge: self.badge,
                donationMode: .gift(recipientFullName: recipientFullName),
                supportedPaymentMethods: DonationUtilities.supportedDonationPaymentMethods(
                    forDonationMode: .gift,
                    usingCurrency: self.price.currencyCode,
                    withConfiguration: self.paymentMethodsConfiguration,
                    localNumber: Self.tsAccountManager.localNumber
                )
            ) { [weak self] (sheet, paymentMethod) in
                sheet.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    switch paymentMethod {
                    case .applePay:
                        self.startApplePay()
                    case .creditOrDebitCard:
                        // TODO: (GB) Support gifting with card.
                        OWSActionSheets.showErrorAlert(message: "Cards not yet supported.")
                    case .paypal:
                        // TODO: [PayPal] Support gifting with PayPal.
                        OWSActionSheets.showErrorAlert(message: "PayPal not yet supported.")
                    }
                }
            }

            self.present(sheet, animated: true)
        }.catch { error in
            if let error = error as? SendGiftBadgeError {
                Logger.warn("[Gifting] Error \(error)")
                switch error {
                case .userCanceledBeforeChargeCompleted:
                    return
                case .cannotReceiveGiftBadges:
                    OWSActionSheets.showActionSheet(
                        title: NSLocalizedString(
                            "DONATION_ON_BEHALF_OF_A_FRIEND_RECIPIENT_CANNOT_RECEIVE_DONATION_ERROR_TITLE",
                            comment: "Users can donate on a friend's behalf. If the friend cannot receive these donations, an error dialog will be shown. This is the title of that error dialog."
                        ),
                        message: NSLocalizedString(
                            "DONATION_ON_BEHALF_OF_A_FRIEND_RECIPIENT_CANNOT_RECEIVE_DONATION_ERROR_BODY",
                            comment: "Users can donate on a friend's behalf. If the friend cannot receive these donations, this error message will be shown."
                        )
                    )
                    return
                default:
                    break
                }
            }

            owsFailDebugUnlessNetworkFailure(error)
            OWSActionSheets.showActionSheet(
                title: NSLocalizedString(
                    "DONATION_ON_BEHALF_OF_A_FRIEND_GENERIC_SEND_ERROR_TITLE",
                    comment: "Users can donate on a friend's behalf. If something goes wrong during this donation, such as a network error, an error dialog is shown. This is the title of that dialog."
                ),
                message: NSLocalizedString(
                    "DONATION_ON_BEHALF_OF_A_FRIEND_GENERIC_SEND_ERROR_BODY",
                    comment: "Users can donate on a friend's behalf. If something goes wrong during this donation, such as a network error, this error message is shown."
                )
            )
        }
    }

    // MARK: - Table contents

    private lazy var avatarViewDataSource: ConversationAvatarDataSource = .thread(self.thread)

    private lazy var messageTextView: TextViewWithPlaceholder = {
        let view = TextViewWithPlaceholder()
        view.placeholderText = NSLocalizedString(
            "DONATE_ON_BEHALF_OF_A_FRIEND_ADDITIONAL_MESSAGE_PLACEHOLDER",
            comment: "Users can donate on a friend's behalf and can optionally add a message. This is the placeholder in the text field for that additional message."
        )
        view.returnKeyType = .done
        view.delegate = self
        return view
    }()

    private var messageText: String {
        (messageTextView.text ?? "").ows_stripped()
    }

    private func updateTableContents() {
        let badge = badge
        let price = price
        let avatarViewDataSource = avatarViewDataSource
        let thread = thread
        let messageTextView = messageTextView

        let avatarView = ConversationAvatarView(
            sizeClass: .thirtySix,
            localUserDisplayMode: .asUser,
            badged: true
        )

        let (recipientName, disappearingMessagesDuration) = databaseStorage.read { transaction -> (String, UInt32) in
            avatarView.update(transaction) { config in
                config.dataSource = avatarViewDataSource
            }

            let recipientName = self.contactsManager.displayName(for: thread, transaction: transaction)
            let disappearingMessagesDuration = thread.disappearingMessagesDuration(with: transaction)
            return (recipientName, disappearingMessagesDuration)
        }

        let badgeSection = OWSTableSection()
        badgeSection.add(.init(customCellBlock: { [weak self] in
            guard let self = self else { return UITableViewCell() }
            let cell = AppSettingsViewsUtil.newCell(cellOuterInsets: self.cellOuterInsets)

            let badgeCellView = GiftBadgeCellView(badge: badge, price: price)
            cell.contentView.addSubview(badgeCellView)
            badgeCellView.autoPinEdgesToSuperviewMargins()

            return cell
        }))

        let recipientSection = OWSTableSection()
        recipientSection.add(.init(customCellBlock: { [weak self] in
            guard let self = self else { return UITableViewCell() }
            let cell = AppSettingsViewsUtil.newCell(cellOuterInsets: self.cellOuterInsets)

            let nameLabel = UILabel()
            nameLabel.text = recipientName
            nameLabel.font = .ows_dynamicTypeBody
            nameLabel.numberOfLines = 0
            nameLabel.minimumScaleFactor = 0.5

            let avatarAndNameView = UIStackView(arrangedSubviews: [avatarView, nameLabel])
            avatarAndNameView.spacing = ContactCellView.avatarTextHSpacing

            let contactCellView = UIStackView()
            contactCellView.distribution = .equalSpacing

            contactCellView.addArrangedSubview(avatarAndNameView)

            if disappearingMessagesDuration != 0 {
                let iconView = UIImageView(image: Theme.iconImage(.settingsTimer))
                iconView.contentMode = .scaleAspectFit

                let disappearingMessagesTimerLabelView = UILabel()
                disappearingMessagesTimerLabelView.text = NSString.formatDurationSeconds(
                    disappearingMessagesDuration,
                    useShortFormat: true
                )
                disappearingMessagesTimerLabelView.font = .ows_dynamicTypeBody2
                disappearingMessagesTimerLabelView.textAlignment = .center
                disappearingMessagesTimerLabelView.minimumScaleFactor = 0.8

                let disappearingMessagesTimerView = UIStackView(arrangedSubviews: [
                    iconView,
                    disappearingMessagesTimerLabelView
                ])
                disappearingMessagesTimerView.spacing = 4

                contactCellView.addArrangedSubview(disappearingMessagesTimerView)
            }

            cell.contentView.addSubview(contactCellView)
            contactCellView.autoPinEdgesToSuperviewMargins()

            return cell
        }))

        let messageInfoSection = OWSTableSection()
        messageInfoSection.hasBackground = false
        messageInfoSection.add(.init(customCellBlock: { [weak self] in
            guard let self = self else { return UITableViewCell() }
            let cell = AppSettingsViewsUtil.newCell(cellOuterInsets: self.cellOuterInsets)

            let messageInfoLabel = UILabel()
            messageInfoLabel.text = NSLocalizedString(
                "DONATE_ON_BEHALF_OF_A_FRIEND_ADDITIONAL_MESSAGE_INFO",
                comment: "Users can donate on a friend's behalf and can optionally add a message. This is tells users about that optional message."
            )
            messageInfoLabel.font = .ows_dynamicTypeBody2
            messageInfoLabel.textColor = Theme.primaryTextColor
            messageInfoLabel.numberOfLines = 0
            cell.contentView.addSubview(messageInfoLabel)
            messageInfoLabel.autoPinEdgesToSuperviewMargins()

            return cell
        }))

        let messageTextSection = OWSTableSection()
        messageTextSection.add(.init(customCellBlock: { [weak self] in
            guard let self = self else { return UITableViewCell() }
            let cell = AppSettingsViewsUtil.newCell(cellOuterInsets: self.cellOuterInsets)

            cell.contentView.addSubview(messageTextView)
            messageTextView.autoPinEdgesToSuperviewMargins()
            messageTextView.autoSetDimension(.height, toSize: 102, relation: .greaterThanOrEqual)

            return cell
        }))

        var sections: [OWSTableSection] = [
            badgeSection,
            recipientSection,
            messageInfoSection,
            messageTextSection
        ]

        if disappearingMessagesDuration != 0 {
            let disappearingMessagesInfoSection = OWSTableSection()
            disappearingMessagesInfoSection.hasBackground = false
            disappearingMessagesInfoSection.add(.init(customCellBlock: { [weak self] in
                guard let self else { return UITableViewCell() }
                let cell = AppSettingsViewsUtil.newCell(cellOuterInsets: self.cellOuterInsets)

                let disappearingMessagesInfoLabel = UILabel()
                disappearingMessagesInfoLabel.font = .ows_dynamicTypeBody2
                disappearingMessagesInfoLabel.textColor = Theme.secondaryTextAndIconColor
                disappearingMessagesInfoLabel.numberOfLines = 0

                let format = NSLocalizedString(
                    "DONATION_ON_BEHALF_OF_A_FRIEND_DISAPPEARING_MESSAGES_NOTICE_FORMAT",
                    comment: "When users make donations on a friend's behalf, a message is sent. This text tells senders that their message will disappear, if the conversation has disappearing messages enabled. Embeds {{duration}}, such as \"1 week\"."
                )
                let durationString = String.formatDurationLossless(
                    durationSeconds: disappearingMessagesDuration
                )
                disappearingMessagesInfoLabel.text = String(format: format, durationString)

                cell.contentView.addSubview(disappearingMessagesInfoLabel)
                disappearingMessagesInfoLabel.autoPinEdgesToSuperviewMargins()

                return cell
            }))

            sections.append(disappearingMessagesInfoSection)
        }

        contents = OWSTableContents(sections: sections)

        previouslyRenderedDisappearingMessagesDuration = disappearingMessagesDuration
    }

    // MARK: - Footer

    private let bottomFooterStackView = UIStackView()

    open override var bottomFooter: UIView? {
        get { bottomFooterStackView }
        set {}
    }

    private func setUpBottomFooter() {
        bottomFooterStackView.axis = .vertical
        bottomFooterStackView.alignment = .center
        bottomFooterStackView.layer.backgroundColor = self.tableBackgroundColor.cgColor
        bottomFooterStackView.spacing = 16
        bottomFooterStackView.isLayoutMarginsRelativeArrangement = true
        bottomFooterStackView.preservesSuperviewLayoutMargins = true
        bottomFooterStackView.layoutMargins = UIEdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16)
        bottomFooterStackView.removeAllSubviews()

        let amountView: UIStackView = {
            let descriptionLabel = UILabel()
            descriptionLabel.text = NSLocalizedString(
                "DONATION_ON_BEHALF_OF_A_FRIEND_PAYMENT_DESCRIPTION",
                comment: "Users can donate on a friend's behalf. This tells users that this will be a one-time donation."
            )
            descriptionLabel.font = .ows_dynamicTypeBody
            descriptionLabel.numberOfLines = 0

            let priceLabel = UILabel()
            priceLabel.text = DonationUtilities.format(money: price)
            priceLabel.font = .ows_dynamicTypeBody.ows_semibold
            priceLabel.numberOfLines = 0

            let view = UIStackView(arrangedSubviews: [descriptionLabel, priceLabel])
            view.axis = .horizontal
            view.distribution = .equalSpacing
            view.layoutMargins = cellOuterInsets
            view.isLayoutMarginsRelativeArrangement = true

            return view
        }()

        let continueButton = OWSButton(title: CommonStrings.continueButton) { [weak self] in
            self?.checkRecipientAndPresentChoosePaymentMethodSheet()
        }
        continueButton.dimsWhenHighlighted = true
        continueButton.layer.cornerRadius = 8
        continueButton.backgroundColor = .ows_accentBlue
        continueButton.titleLabel?.font = UIFont.ows_dynamicTypeBody.ows_semibold

        for view in [amountView, continueButton] {
            bottomFooterStackView.addArrangedSubview(view)
            view.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)
            view.autoPinWidthToSuperview(withMargin: 23)
        }
    }
}

// MARK: - Database observer delegate

extension BadgeGiftingConfirmationViewController: DatabaseChangeDelegate {
    private func updateDisappearingMessagesTimerWithSneakyTransaction() {
        let durationSeconds = databaseStorage.read { self.thread.disappearingMessagesDuration(with: $0) }
        if previouslyRenderedDisappearingMessagesDuration != durationSeconds {
            updateTableContents()
        }
    }

    func databaseChangesDidUpdate(databaseChanges: DatabaseChanges) {
        if databaseChanges.didUpdate(thread: thread) {
            updateDisappearingMessagesTimerWithSneakyTransaction()
        }
    }

    func databaseChangesDidUpdateExternally() {
        updateDisappearingMessagesTimerWithSneakyTransaction()
    }

    func databaseChangesDidReset() {
        updateDisappearingMessagesTimerWithSneakyTransaction()
    }
}

// MARK: - Text view delegate

extension BadgeGiftingConfirmationViewController: TextViewWithPlaceholderDelegate {
    func textViewDidUpdateSelection(_ textView: TextViewWithPlaceholder) {
        textView.scrollToFocus(in: tableView, animated: true)
    }

    func textViewDidUpdateText(_ textView: TextViewWithPlaceholder) {
        // Kick the tableview so it recalculates sizes
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates(nil) { (_) in
                // And when the size changes have finished, make sure we're scrolled
                // to the focused line
                textView.scrollToFocus(in: self.tableView, animated: false)
            }
        }
    }

    func textView(_ textView: TextViewWithPlaceholder,
                  uiTextView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        if text == "\n" {
            uiTextView.resignFirstResponder()
        }
        return true
    }
}

// MARK: - Apple Pay

extension BadgeGiftingConfirmationViewController: PKPaymentAuthorizationControllerDelegate {
    private struct PreparedPayment {
        let paymentIntent: Stripe.PaymentIntent
        let paymentMethodId: String
    }

    enum SendGiftBadgeError: Error {
        case recipientIsBlocked
        case failedAndUserNotCharged
        case failedAndUserMaybeCharged
        case cannotReceiveGiftBadges
        case userCanceledBeforeChargeCompleted
    }

    func startApplePay() {
        Logger.info("[Gifting] Requesting Apple Pay...")

        let request = DonationUtilities.newPaymentRequest(for: self.price, isRecurring: false)

        let paymentController = PKPaymentAuthorizationController(paymentRequest: request)
        paymentController.delegate = self
        paymentController.present { presented in
            if !presented {
                // This can happen under normal conditions if the user double-taps the button,
                // but may also indicate a problem.
                Logger.warn("[Gifting] Failed to present payment controller")
            }
        }
    }

    private func prepareToPay(authorizedPayment: PKPayment) -> Promise<PreparedPayment> {
        firstly {
            Stripe.createBoostPaymentIntent(
                for: self.price,
                level: .giftBadge(.signalGift)
            )
        }.then { paymentIntent in
            Stripe.createPaymentMethod(with: .applePay(payment: authorizedPayment)).map { paymentMethodId in
                PreparedPayment(paymentIntent: paymentIntent, paymentMethodId: paymentMethodId)
            }
        }
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        var hasCalledCompletion = false
        func wrappedCompletion(_ result: PKPaymentAuthorizationResult) {
            guard !hasCalledCompletion else { return }
            hasCalledCompletion = true
            completion(result)
        }

        firstly(on: .global()) { () -> Promise<PreparedPayment> in
            // Bail if the user is already sending a gift to this person. This unusual case can happen if:
            //
            // 1. The user enqueues a "send gift badge" job for this recipient
            // 2. The app is terminated (e.g., due to a crash)
            // 3. Before the job finishes, the user restarts the app and tries to gift another badge to the same person
            //
            // This *could* happen without a Signal developer making a mistake, if the app is terminated at the right time.
            let isAlreadyGifting = self.databaseStorage.read {
                DonationUtilities.sendGiftBadgeJobQueue.alreadyHasJob(for: self.thread, transaction: $0)
            }
            guard !isAlreadyGifting else {
                Logger.warn("Already sending a gift to this recipient")
                throw SendGiftBadgeError.failedAndUserNotCharged
            }

            // Prepare to pay. We haven't charged the user yet, so we don't need to do anything durably,
            // e.g. a job.
            return firstly { () -> Promise<PreparedPayment> in
                self.prepareToPay(authorizedPayment: payment)
            }.timeout(seconds: 30) {
                Logger.warn("Timed out after preparing gift badge payment")
                return SendGiftBadgeError.failedAndUserNotCharged
            }.recover(on: .global()) { error -> Promise<PreparedPayment> in
                if !(error is SendGiftBadgeError) { owsFailDebugUnlessNetworkFailure(error) }
                throw SendGiftBadgeError.failedAndUserNotCharged
            }
        }.then { [weak self] preparedPayment -> Promise<PreparedPayment> in
            guard let self = self else { throw SendGiftBadgeError.userCanceledBeforeChargeCompleted }

            let safetyNumberConfirmationResult = self.showSafetyNumberConfirmationIfNecessary()
            if safetyNumberConfirmationResult.needsUserInteraction {
                wrappedCompletion(.init(status: .success, errors: nil))
            }

            return safetyNumberConfirmationResult.promise.map { safetyNumberConfirmationResult in
                switch safetyNumberConfirmationResult {
                case .userDidNotConfirmSafetyNumberChange:
                    throw SendGiftBadgeError.userCanceledBeforeChargeCompleted
                case .userConfirmedSafetyNumberChangeOrNoChangeWasNeeded:
                    return preparedPayment
                }
            }
        }.then { [weak self] preparedPayment -> Promise<Void> in
            guard let self = self else { throw SendGiftBadgeError.userCanceledBeforeChargeCompleted }

            // We know our payment processor here is Stripe, since we are in an
            // Apple Pay flow.
            let paymentProcessor: PaymentProcessor = .stripe

            // Durably enqueue a job to (1) do the charge (2) redeem the receipt credential (3) enqueue
            // a gift badge message (and optionally a text message) to the recipient. We also want to
            // update the UI partway through the job's execution, and when it completes.
            let jobRecord = SendGiftBadgeJobQueue.createJob(
                paymentProcessor: paymentProcessor,
                receiptRequest: SubscriptionManager.generateReceiptRequest(),
                amount: self.price,
                paymentIntent: preparedPayment.paymentIntent,
                paymentMethodId: preparedPayment.paymentMethodId,
                thread: self.thread,
                messageText: self.messageText
            )
            let jobId = jobRecord.uniqueId

            let (promise, future) = Promise<Void>.pending()

            var modalActivityIndicatorViewController: ModalActivityIndicatorViewController?
            var shouldDismissActivityIndicator = false
            func presentModalActivityIndicatorIfNotAlreadyPresented() {
                guard modalActivityIndicatorViewController == nil else { return }
                ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { modal in
                    DispatchQueue.main.async {
                        modalActivityIndicatorViewController = modal
                        // Depending on how things are dispatched, we could need the modal closed immediately.
                        if shouldDismissActivityIndicator {
                            modal.dismiss {}
                        }
                    }
                }
            }

            // This is unusual, but can happen if the Apple Pay sheet was dismissed earlier in the process,
            // which can happen if the user needed to confirm a safety number change.
            if hasCalledCompletion {
                presentModalActivityIndicatorIfNotAlreadyPresented()
            }

            var hasCharged = false

            // The happy path is two steps: payment method is charged (showing a spinner), then job finishes (opening the chat).
            //
            // The valid sad paths are:
            // 1. We started charging the card but we don't know whether it succeeded before the job failed
            // 2. The card is "definitively" charged, but then the job fails
            //
            // There are some invalid sad paths that we try to handle, but those indicate Signal bugs.
            let observer = NotificationCenter.default.addObserver(forName: SendGiftBadgeJobQueue.JobEventNotification,
                                                                  object: nil,
                                                                  queue: .main) { notification in
                guard let userInfo = notification.userInfo,
                      let notificationJobId = userInfo["jobId"] as? String,
                      let rawJobEvent = userInfo["jobEvent"] as? Int,
                      let jobEvent = SendGiftBadgeJobQueue.JobEvent(rawValue: rawJobEvent) else {
                    owsFail("Received a gift badge job event with invalid user data")
                }
                guard notificationJobId == jobId else {
                    // This can happen if:
                    //
                    // 1. The user enqueues a "send gift badge" job
                    // 2. The app terminates before it can complete (e.g., due to a crash)
                    // 3. Before the job finishes, the user restarts the app and tries to gift another badge
                    //
                    // This is unusual and may indicate a bug, so we log, but we don't error/crash because it can happen under "normal" circumstances.
                    Logger.warn("Received an event for a different badge gifting job.")
                    return
                }

                switch jobEvent {
                case .jobFailed:
                    future.reject(SendGiftBadgeError.failedAndUserMaybeCharged)
                case .chargeSucceeded:
                    guard !hasCharged else {
                        // This job event can be emitted twice if the job fails (e.g., due to network) after the payment method is charged, and then it's restarted.
                        // That's unusual, but isn't necessarily a bug.
                        Logger.warn("Received a \"charge succeeded\" event more than once")
                        break
                    }
                    hasCharged = true
                    wrappedCompletion(.init(status: .success, errors: nil))
                    controller.dismiss()
                    presentModalActivityIndicatorIfNotAlreadyPresented()
                case .jobSucceeded:
                    future.resolve(())
                }
            }

            try self.databaseStorage.write { transaction in
                // We should already have checked this earlier, but it's possible that the state has changed on another device.
                // We'll also check this inside the job before running it.
                guard !self.isRecipientBlocked(transaction: transaction) else {
                    throw SendGiftBadgeError.recipientIsBlocked
                }

                DonationUtilities.sendGiftBadgeJobQueue.addJob(jobRecord, transaction: transaction)
            }

            func finish() {
                NotificationCenter.default.removeObserver(observer)
                if let modalActivityIndicatorViewController = modalActivityIndicatorViewController {
                    modalActivityIndicatorViewController.dismiss {}
                } else {
                    shouldDismissActivityIndicator = true
                }
            }

            return promise.done(on: .main) {
                owsAssertDebug(hasCharged, "Expected \"charge succeeded\" event")
                finish()
            }.recover(on: .main) { error in
                finish()
                throw error
            }
        }.done { [weak self] in
            // We shouldn't need to dismiss the Apple Pay sheet here, but if the `chargeSucceeded` event was missed, we do our best.
            wrappedCompletion(.init(status: .success, errors: nil))
            guard let self = self else { return }
            SignalApp.shared().presentConversation(for: self.thread, action: .none, animated: false)
            self.dismiss(animated: true) {
                SignalApp.shared().conversationSplitViewControllerForSwift?.present(
                    BadgeGiftingThanksSheet(thread: self.thread, badge: self.badge),
                    animated: true
                )
            }
        }.catch { error in
            guard let error = error as? SendGiftBadgeError else {
                owsFail("\(error)")
            }

            wrappedCompletion(.init(status: .failure, errors: [error]))

            switch error {
            case .userCanceledBeforeChargeCompleted:
                break
            case .recipientIsBlocked:
                Self.showRecipientIsBlockedError()
            case .failedAndUserNotCharged, .cannotReceiveGiftBadges:
                OWSActionSheets.showActionSheet(
                    title: NSLocalizedString(
                        "DONATION_ON_BEHALF_OF_A_FRIEND_PAYMENT_FAILED_ERROR_TITLE",
                        comment: "Users can donate on a friend's behalf. If the payment fails and the user has not been charged, an error dialog will be shown. This is the title of that dialog."
                    ),
                    message: NSLocalizedString(
                        "DONATION_ON_BEHALF_OF_A_FRIEND_PAYMENT_FAILED_ERROR_BODY",
                        comment: "Users can donate on a friend's behalf. If the payment fails and the user has not been charged, this error message is shown."
                    )
                )
            case .failedAndUserMaybeCharged:
                OWSActionSheets.showActionSheet(
                    title: NSLocalizedString(
                        "DONATION_ON_BEHALF_OF_A_FRIEND_PAYMENT_SUCCEEDED_BUT_MESSAGE_FAILED_ERROR_TITLE",
                        comment: "Users can donate on a friend's behalf. If the payment was processed but the donation failed to send, an error dialog will be shown. This is the title of that dialog."
                    ),
                    message: NSLocalizedString(
                        "DONATION_ON_BEHALF_OF_A_FRIEND_PAYMENT_SUCCEEDED_BUT_MESSAGE_FAILED_ERROR_BODY",
                        comment: "Users can donate on a friend's behalf. If the payment was processed but the donation failed to send, this error message will be shown."
                    )
                )
            }
        }
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss()
    }
}
