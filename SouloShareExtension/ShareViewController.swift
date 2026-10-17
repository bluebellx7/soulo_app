import UIKit
import OSLog

final class ShareViewController: UIViewController {
    private let logger = Logger(subsystem: "com.dkluge.Soulo", category: "ShareInput")
    private let titleLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)
    private var action: SouloSharedAction?
    private var didAppear = false
    private var didAttemptOpen = false
    private var savedForNextOpen = false
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        loadSharedContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
        openIfReady()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        titleLabel.text = NSLocalizedString("intent_open_soulo_title", comment: "")
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("cancel", comment: "")
        configuration.cornerStyle = .large
        doneButton.configuration = configuration
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [activityIndicator, titleLabel, doneButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
        activityIndicator.startAnimating()
    }

    private func loadSharedContent() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        #if DEBUG
        let initialContextPresent = extensionContext != nil
        #endif
        Task { @MainActor in
            let action = await SouloShareContentLoader.action(from: items)
            #if DEBUG
            SouloShareInputDiagnostic.record(["stage": "context", "initialPresent": initialContextPresent,
                "currentPresent": extensionContext != nil, "didAppear": didAppear,
                "rawItemClasses": extensionContext?.inputItems.map { String(reflecting: type(of: $0)) } ?? []])
            #endif
            guard !didFinish else { return }
            if let action { contentLoaded(action) }
            else { showError() }
        }
    }

    private func contentLoaded(_ action: SouloSharedAction) {
        guard !didFinish else { return }
        self.action = action
        openIfReady()
    }

    private func openIfReady() {
        guard didAppear, !didFinish, !didAttemptOpen, let action else { return }
        didAttemptOpen = true
        guard action.store(), let url = action.deepLink else {
            logger.error("Failed to persist the shared action in the App Group.")
            #if DEBUG
            SouloShareInputDiagnostic.record(["stage": "storeFailed"])
            #endif
            showError(messageKey: "save_failed")
            return
        }
        savedForNextOpen = true
        #if DEBUG
        SouloShareInputDiagnostic.record(["stage": "stored"])
        #endif
        doneButton.configuration?.title = NSLocalizedString("done", comment: "")
        guard let extensionContext else { showSavedForNextOpen(); return }
        // Use the browser Open in compatibility path first. Complete the
        // extension immediately after dispatch, as Chromium's extension does.
        if SouloExtensionURLOpener.requestOpen(url, from: self) {
            didFinish = true
            extensionContext.completeRequest(returningItems: nil)
            return
        }
        // A host may omit the callback. Always leave a usable dismissal button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.showSavedForNextOpen()
        }
        // Hosts without an opening responder may still support the context API.
        // If neither route works, retain the App Group request and explain it.
        extensionContext.open(url) { [weak self] success in
            Task { @MainActor in
                guard let self, !self.didFinish else { return }
                if success { self.didFinish = true; extensionContext.completeRequest(returningItems: nil) }
                else { self.showSavedForNextOpen() }
            }
        }
    }

    private func showSavedForNextOpen() {
        guard !didFinish else { return }
        titleLabel.text = NSLocalizedString("share_saved_for_open", comment: "")
        activityIndicator.stopAnimating()
        doneButton.configuration?.title = NSLocalizedString("done", comment: "")
    }

    private func showError(messageKey: String = "share_extension_unsupported") {
        guard !didFinish else { return }
        titleLabel.text = NSLocalizedString(messageKey, comment: "")
        activityIndicator.stopAnimating()
        doneButton.configuration?.title = NSLocalizedString("cancel", comment: "")
    }

    @objc private func finish() {
        guard !didFinish else { return }
        didFinish = true
        if savedForNextOpen {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            if let action { SouloSharedAction.discardPending(matchingID: action.id) }
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
