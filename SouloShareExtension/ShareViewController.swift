import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var sharedText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        loadSharedContent()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        titleLabel.text = NSLocalizedString("share_extension_title", comment: "")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(activityIndicator)
        stack.addArrangedSubview(makeButton(
            title: NSLocalizedString("share_search_in_soulo", comment: ""),
            image: "magnifyingglass",
            action: #selector(search)
        ))
        stack.addArrangedSubview(makeButton(
            title: NSLocalizedString("share_private_search", comment: ""),
            image: "eye.slash",
            action: #selector(privateSearch)
        ))
        stack.addArrangedSubview(makeButton(
            title: NSLocalizedString("cancel", comment: ""),
            image: "xmark",
            action: #selector(cancel)
        ))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        activityIndicator.startAnimating()
    }

    private func makeButton(title: String, image: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 10
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        button.isEnabled = false
        return button
    }

    private func loadSharedContent() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        guard !providers.isEmpty else {
            finishWithError()
            return
        }

        Task {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    contentLoaded(url.absoluteString)
                    return
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    contentLoaded(text)
                    return
                }
            }
            await MainActor.run { self.finishWithError() }
        }
    }

    @MainActor
    private func contentLoaded(_ text: String) {
        sharedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activityIndicator.stopAnimating()
        stack.arrangedSubviews.compactMap { $0 as? UIButton }.forEach { $0.isEnabled = true }
    }

    @objc private func search() { open(.search) }
    @objc private func privateSearch() { open(.privateSearch) }

    private func open(_ kind: SouloSharedAction.Kind) {
        let action = SouloSharedAction(kind: kind, text: sharedText)
        action.store()
        guard let url = action.deepLink else {
            finishWithError()
            return
        }
        extensionContext?.open(url) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func finishWithError() {
        titleLabel.text = NSLocalizedString("share_extension_unsupported", comment: "")
        activityIndicator.stopAnimating()
        stack.arrangedSubviews.compactMap { $0 as? UIButton }.last?.isEnabled = true
    }
}
