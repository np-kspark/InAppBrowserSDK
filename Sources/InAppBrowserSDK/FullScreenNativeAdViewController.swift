import UIKit
import AVFoundation
import GoogleMobileAds

final class FullScreenNativeAdViewController: UIViewController {

    private static let maxAds = 5
    private static let timeoutSeconds: TimeInterval = 10

    // MARK: - Config

    private let adUnitId: String
    private let startMuted: Bool

    // MARK: - State

    private var adList: [NativeAd] = []
    private var currentIndex = 0
    private var adLoader: AdLoader?
    private var timeoutTask: Task<Void, Never>?
    private var didStartLoading = false

    // MARK: - UI

    private let adContainer = UIView()
    private let adCountLabel = UILabel()
    private let nextButton = UIButton(type: .system)

    // MARK: - Init

    init(adUnitId: String, startMuted: Bool) {
        self.adUnitId = adUnitId
        self.startMuted = startMuted
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartLoading else { return }
        didStartLoading = true
        loadAds()
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        guard !startMuted else { return }
        MobileAds.shared.audioVideoManager.isAudioSessionApplicationManaged = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Layout

    private func buildLayout() {
        let safe = view.safeAreaLayoutGuide

        let bottomBar = UIView()
        bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 64),
        ])

        adCountLabel.text = "로딩 중..."
        adCountLabel.textColor = UIColor.white.withAlphaComponent(0.67)
        adCountLabel.font = .systemFont(ofSize: 13)

        nextButton.setTitle("다음 ›", for: .normal)
        nextButton.setTitleColor(.white, for: .normal)
        nextButton.setTitleColor(UIColor.white.withAlphaComponent(0.4), for: .disabled)
        nextButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        nextButton.backgroundColor = UIColor(red: 0x62 / 255.0, green: 0x00 / 255.0, blue: 0xEE / 255.0, alpha: 1)
        nextButton.layer.cornerRadius = 6
        nextButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        nextButton.isEnabled = false
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        let barStack = UIStackView(arrangedSubviews: [adCountLabel, UIView(), nextButton])
        barStack.axis = .horizontal
        barStack.alignment = .center
        barStack.spacing = 12
        barStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(barStack)
        NSLayoutConstraint.activate([
            barStack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 20),
            barStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            barStack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            barStack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
        ])

        adContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adContainer)
        NSLayoutConstraint.activate([
            adContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 56),
            adContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            adContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            adContainer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
        ])

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 18)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 48),
            closeButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: - Ad Loading

    private func loadAds() {
        configureAudioSession()

        let videoOptions = VideoOptions()
        videoOptions.shouldStartMuted = startMuted

        let mediaOptions = NativeAdMediaAdLoaderOptions()
        mediaOptions.mediaAspectRatio = .any

        let multipleAdsOptions = MultipleAdsAdLoaderOptions()
        multipleAdsOptions.numberOfAds = Self.maxAds

        let loader = AdLoader(
            adUnitID: adUnitId,
            rootViewController: self,
            adTypes: [.native],
            options: [videoOptions, mediaOptions, multipleAdsOptions]
        )
        loader.delegate = self
        adLoader = loader

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.adList.isEmpty {
                self.adCountLabel.text = "광고 로딩 실패"
            }
        }

        loader.load(AdManagerRequest())
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // MARK: - Show / Next

    private func showAd(at index: Int) {
        guard index >= 0, index < adList.count else { return }
        currentIndex = index
        adContainer.subviews.forEach { $0.removeFromSuperview() }
        populateNativeAdView(adList[index])
        updateCountUI()
    }

    @objc private func nextTapped() {
        if currentIndex + 1 < adList.count {
            showAd(at: currentIndex + 1)
        }
    }

    private func updateCountUI() {
        let total = adList.count
        adCountLabel.text = "\(currentIndex + 1) / \(total)"
        let hasNext = currentIndex + 1 < total
        nextButton.isEnabled = hasNext
        nextButton.setTitle(hasNext ? "다음 ›" : "마지막", for: .normal)
    }

    // MARK: - Populate

    private func populateNativeAdView(_ nativeAd: NativeAd) {
        let adView = NativeAdView()
        adView.translatesAutoresizingMaskIntoConstraints = false

        let mediaView = MediaView()
        mediaView.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        mediaView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        mediaView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let iconView = UIImageView()
        iconView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
        ])

        let headlineLabel = UILabel()
        headlineLabel.textColor = .white
        headlineLabel.font = .boldSystemFont(ofSize: 15)
        headlineLabel.numberOfLines = 2

        let iconHeadlineStack = UIStackView(arrangedSubviews: [iconView, headlineLabel])
        iconHeadlineStack.axis = .horizontal
        iconHeadlineStack.alignment = .center
        iconHeadlineStack.spacing = 8

        let bodyLabel = UILabel()
        bodyLabel.textColor = UIColor(white: 0.8, alpha: 1)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.numberOfLines = 2

        let ctaButton = UIButton(type: .custom)
        ctaButton.setTitleColor(.white, for: .normal)
        ctaButton.titleLabel?.font = .boldSystemFont(ofSize: 15)
        ctaButton.backgroundColor = UIColor(red: 0x62 / 255.0, green: 0x00 / 255.0, blue: 0xEE / 255.0, alpha: 1)
        ctaButton.layer.cornerRadius = 8
        ctaButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let infoStack = UIStackView(arrangedSubviews: [iconHeadlineStack, bodyLabel, ctaButton])
        infoStack.axis = .vertical
        infoStack.spacing = 8
        infoStack.isLayoutMarginsRelativeArrangement = true
        infoStack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)

        let rootStack = UIStackView(arrangedSubviews: [mediaView, infoStack])
        rootStack.axis = .vertical
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        adView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: adView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: adView.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: adView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
        ])

        adContainer.addSubview(adView)
        NSLayoutConstraint.activate([
            adView.topAnchor.constraint(equalTo: adContainer.topAnchor),
            adView.bottomAnchor.constraint(equalTo: adContainer.bottomAnchor),
            adView.leadingAnchor.constraint(equalTo: adContainer.leadingAnchor),
            adView.trailingAnchor.constraint(equalTo: adContainer.trailingAnchor),
        ])
        adContainer.layoutIfNeeded()

        adView.mediaView = mediaView
        adView.headlineView = headlineLabel
        adView.bodyView = bodyLabel
        adView.callToActionView = ctaButton
        adView.iconView = iconView

        headlineLabel.text = nativeAd.headline

        bodyLabel.text = nativeAd.body
        bodyLabel.isHidden = nativeAd.body == nil

        ctaButton.setTitle(nativeAd.callToAction, for: .normal)
        ctaButton.isHidden = nativeAd.callToAction == nil
        ctaButton.isUserInteractionEnabled = false

        iconView.image = nativeAd.icon?.image
        iconView.isHidden = nativeAd.icon == nil

        mediaView.mediaContent = nativeAd.mediaContent

        adView.nativeAd = nativeAd
    }

    // MARK: - Close

    @objc private func closeTapped() {
        cancelTimeout()
        adList.removeAll()
        adLoader = nil
        if !startMuted {
            MobileAds.shared.audioVideoManager.isAudioSessionApplicationManaged = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        dismiss(animated: true)
    }
}

// MARK: - NativeAdLoaderDelegate

extension FullScreenNativeAdViewController: NativeAdLoaderDelegate {

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        adList.append(nativeAd)
        if adList.count == 1 {
            cancelTimeout()
            showAd(at: 0)
        } else {
            updateCountUI()
        }
    }

    func adLoaderDidFinishLoading(_ adLoader: AdLoader) {
        self.adLoader = nil
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        if adList.isEmpty {
            cancelTimeout()
            adCountLabel.text = "광고 없음"
        }
    }
}
