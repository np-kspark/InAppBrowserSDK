import UIKit
import GoogleMobileAds

public final class DirectAdViewController: UIViewController {

    // MARK: - RewardTrigger

    public enum RewardTrigger {
        case visitDuration
        case closeButton
    }

    // MARK: - Config

    struct Config {
        let advertiserName: String
        let headline: String
        let imageUrl: String
        let clickUrl: String
        let visitSeconds: TimeInterval
        let trigger: RewardTrigger
        let isEvent: Bool
        let ctaVisitText: String
        let ctaEventText: String
        let ctaRewardText: String
        let eventId: String
    }

    // MARK: - Colors

    private enum C {
        static let active    = UIColor(red: 0x05/255.0, green: 0x96/255.0, blue: 0x69/255.0, alpha: 1)
        static let inactive  = UIColor(red: 0xCF/255.0, green: 0xD5/255.0, blue: 0xE0/255.0, alpha: 1)
        static let lineOff   = UIColor(red: 0xE5/255.0, green: 0xE9/255.0, blue: 0xF2/255.0, alpha: 1)
        static let primary   = UIColor(red: 0x1A/255.0, green: 0x1D/255.0, blue: 0x29/255.0, alpha: 1)
        static let secondary = UIColor(red: 0x6B/255.0, green: 0x72/255.0, blue: 0x80/255.0, alpha: 1)
        static let caption   = UIColor(red: 0x8B/255.0, green: 0x90/255.0, blue: 0x9C/255.0, alpha: 1)
        static let dismiss   = UIColor(red: 0xAA/255.0, green: 0xB0/255.0, blue: 0xBC/255.0, alpha: 1)
        static let tagBg     = UIColor(red: 0x9C/255.0, green: 0xA3/255.0, blue: 0xAF/255.0, alpha: 1)
        static let closeBg   = UIColor(red: 0xF0/255.0, green: 0xF1/255.0, blue: 0xF4/255.0, alpha: 1)
        static let closeTxt  = UIColor(red: 0x92/255.0, green: 0x98/255.0, blue: 0xA4/255.0, alpha: 1)
        static let infoBorder = UIColor(red: 0xB0/255.0, green: 0xB6/255.0, blue: 0xC0/255.0, alpha: 1)
        static let stepLabel = UIColor(red: 0x92/255.0, green: 0x98/255.0, blue: 0xA4/255.0, alpha: 1)
        static let divider   = UIColor(red: 0xF1/255.0, green: 0xF2/255.0, blue: 0xF5/255.0, alpha: 1)
        static let imageBg   = UIColor(red: 0xEE/255.0, green: 0xF1/255.0, blue: 0xF8/255.0, alpha: 1)
    }

    // MARK: - State

    private let config: Config
    private let trackingAd: CustomNativeAd?
    private let participationChecker: ((String) async -> Bool)?
    private let onRewardGranted: () -> Void
    private let onDismiss: () -> Void

    private var remainingTime: TimeInterval
    private var clickTime: Date?
    private var isWaitingForReturn = false
    private var hasReportedClick = false
    private var hasVisited = false
    private var isRewardReady = false
    private var hasRecordedImpression = false

    // MARK: - UI

    private var adImageView: UIImageView!
    private var ctaButton: UIButton!
    private var ctaCaption: UILabel!
    private var stepDot2: UILabel!
    private var stepDot3: UILabel!
    private var stepLine1: UIView!
    private var stepLine2: UIView!

    // MARK: - Init

    init(
        config: Config,
        trackingAd: CustomNativeAd?,
        participationChecker: ((String) async -> Bool)?,
        onRewardGranted: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.config = config
        self.trackingAd = trackingAd
        self.participationChecker = participationChecker
        self.onRewardGranted = onRewardGranted
        self.onDismiss = onDismiss
        self.remainingTime = config.visitSeconds
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    private var ctaVisit: String  { config.ctaVisitText.isEmpty  ? "사이트 방문하기" : config.ctaVisitText }
    private var ctaEvent: String  { config.ctaEventText.isEmpty  ? "이벤트 참여하기" : config.ctaEventText }
    private var ctaReward: String { config.ctaRewardText.isEmpty ? "보상 받기"      : config.ctaRewardText }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        buildCard()
        loadImage()

        if !config.isEvent {
            recordImpressionOnce()
        }
    }

    // MARK: - Layout

    private var imageSize: CGSize {
        let screenW = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let w: CGFloat = screenW >= 360 ? 300 : screenW - 60
        return CGSize(width: w, height: (w * 250 / 300).rounded())
    }

    private func buildCard() {
        let cardW = imageSize.width + 40

        let card = UIView()
        card.backgroundColor = .white
        card.layer.cornerRadius = 22
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: cardW),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        stack.addArrangedSubview(buildTopBar())
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(buildProgress())
        stack.addArrangedSubview(buildImageArea())
        stack.addArrangedSubview(buildTextArea())
        stack.addArrangedSubview(buildCtaArea())
        stack.addArrangedSubview(buildDismissLink())
    }

    private func buildTopBar() -> UIView {
        let bar = UIView()
        bar.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let adTag = UILabel()
        adTag.text = "광고"
        adTag.font = .boldSystemFont(ofSize: 10)
        adTag.textColor = .white
        adTag.backgroundColor = C.tagBg
        adTag.textAlignment = .center
        adTag.layer.cornerRadius = 4
        adTag.clipsToBounds = true
        adTag.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(adTag)

        let info = UILabel()
        info.text = "i"
        info.font = .boldSystemFont(ofSize: 10)
        info.textColor = C.caption
        info.textAlignment = .center
        info.layer.cornerRadius = 8
        info.layer.borderWidth = 1
        info.layer.borderColor = C.infoBorder.cgColor
        info.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(info)

        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.setTitleColor(C.closeTxt, for: .normal)
        close.titleLabel?.font = .boldSystemFont(ofSize: 14)
        close.backgroundColor = C.closeBg
        close.layer.cornerRadius = 14
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        bar.addSubview(close)

        NSLayoutConstraint.activate([
            adTag.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            adTag.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            adTag.widthAnchor.constraint(equalToConstant: 34),
            adTag.heightAnchor.constraint(equalToConstant: 18),

            info.leadingAnchor.constraint(equalTo: adTag.trailingAnchor, constant: 6),
            info.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            info.widthAnchor.constraint(equalToConstant: 16),
            info.heightAnchor.constraint(equalToConstant: 16),

            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
        ])
        return bar
    }

    private func buildProgress() -> UIView {
        let container = UIView()
        container.heightAnchor.constraint(equalToConstant: 74).isActive = true

        let visitSec = max(1, Int(config.visitSeconds))
        let step2Label = (config.isEvent || config.trigger == .closeButton) ? "방문" : "\(visitSec)초 체류"

        let step1 = makeStep(text: "1", label: "클릭", active: true)
        let line1 = makeStepLine(color: C.active)
        let step2 = makeStep(text: "2", label: step2Label, active: false)
        let line2 = makeStepLine(color: C.lineOff)
        let step3 = makeStep(text: "✓", label: "보상", active: false)

        stepDot2 = step2.1
        stepDot3 = step3.1
        stepLine1 = line1.1
        stepLine2 = line2.1

        let row = UIStackView(arrangedSubviews: [step1.0, line1.0, step2.0, line2.0, step3.0])
        row.axis = .horizontal
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            line1.0.widthAnchor.constraint(equalTo: line2.0.widthAnchor),
        ])
        return container
    }

    private func makeStep(text: String, label: String, active: Bool) -> (UIView, UILabel) {
        let dot = UILabel()
        dot.text = text
        dot.font = .boldSystemFont(ofSize: 11)
        dot.textColor = .white
        dot.textAlignment = .center
        dot.backgroundColor = active ? C.active : C.inactive
        dot.layer.cornerRadius = 12
        dot.clipsToBounds = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 24).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let lbl = UILabel()
        lbl.text = label
        lbl.font = .boldSystemFont(ofSize: 10)
        lbl.textColor = C.stepLabel
        lbl.textAlignment = .center

        let v = UIStackView(arrangedSubviews: [dot, lbl])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 4
        return (v, dot)
    }

    private func makeStepLine(color: UIColor) -> (UIView, UIView) {
        let container = UIView()
        container.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        container.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)

        let line = UIView()
        line.backgroundColor = color
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -6),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 6),
            line.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            line.heightAnchor.constraint(equalToConstant: 2),
        ])
        return (container, line)
    }

    private func activateStep2() {
        stepDot2?.backgroundColor = C.active
        stepLine1?.backgroundColor = C.active
    }

    private func activateStep3() {
        stepDot3?.backgroundColor = C.active
        stepLine2?.backgroundColor = C.active
    }

    private func buildImageArea() -> UIView {
        let wrapper = UIView()

        adImageView = UIImageView()
        adImageView.backgroundColor = C.imageBg
        adImageView.contentMode = .scaleAspectFill
        adImageView.layer.cornerRadius = 12
        adImageView.clipsToBounds = true
        adImageView.isUserInteractionEnabled = true
        adImageView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(imageTapped)))
        adImageView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(adImageView)

        NSLayoutConstraint.activate([
            adImageView.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 12),
            adImageView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            adImageView.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            adImageView.widthAnchor.constraint(equalToConstant: imageSize.width),
            adImageView.heightAnchor.constraint(equalToConstant: imageSize.height),
        ])
        return wrapper
    }

    private func loadImage() {
        guard let url = URL(string: config.imageUrl), !config.imageUrl.isEmpty else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            self?.adImageView.image = image
        }
    }

    private func buildTextArea() -> UIView {
        let wrapper = UIView()

        let name = UILabel()
        name.text = config.advertiserName
        name.font = .boldSystemFont(ofSize: 14)
        name.textColor = C.primary
        name.numberOfLines = 1

        let headline = UILabel()
        headline.text = config.headline
        headline.font = .systemFont(ofSize: 13)
        headline.textColor = C.secondary
        headline.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [name, headline])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)

        name.isHidden = config.advertiserName.isEmpty
        headline.isHidden = config.headline.isEmpty

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -20),
        ])
        return wrapper
    }

    private func buildCtaArea() -> UIView {
        let wrapper = UIView()

        ctaButton = UIButton(type: .system)
        ctaButton.setTitle(config.isEvent ? ctaEvent : ctaVisit, for: .normal)
        ctaButton.setTitleColor(.white, for: .normal)
        ctaButton.titleLabel?.font = .boldSystemFont(ofSize: 15)
        ctaButton.backgroundColor = C.active
        ctaButton.layer.cornerRadius = 12
        ctaButton.addTarget(self, action: #selector(ctaTapped), for: .touchUpInside)

        ctaCaption = UILabel()
        let secs = max(1, Int(config.visitSeconds))
        ctaCaption.text = "\(secs)초 이상 머문 뒤 지급"
        ctaCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        ctaCaption.textColor = C.caption
        ctaCaption.textAlignment = .center
        ctaCaption.isHidden = (config.trigger == .closeButton || config.isEvent)

        let stack = UIStackView(arrangedSubviews: [ctaButton, ctaCaption])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)

        NSLayoutConstraint.activate([
            ctaButton.heightAnchor.constraint(equalToConstant: 50),

            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -20),
        ])
        return wrapper
    }

    private func buildDismissLink() -> UIView {
        let wrapper = UIView()

        let btn = UIButton(type: .system)
        let attr = NSAttributedString(
            string: "보상 없이 닫기",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: C.dismiss,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        btn.setAttributedTitle(attr, for: .normal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(dismissLinkTapped), for: .touchUpInside)
        wrapper.addSubview(btn)

        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            btn.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -16),
            btn.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            btn.heightAnchor.constraint(equalToConstant: 24),
        ])
        return wrapper
    }

    private func makeDivider() -> UIView {
        let v = UIView()
        v.backgroundColor = C.divider
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: - Actions

    @objc private func ctaTapped() {
        if isRewardReady {
            if let trackingAd {
                trackingAd.customClickHandler = { _ in }
                trackingAd.performClickOnAsset(withKey: "Direct_Ad_Landing_Url")
            }
            activateStep3()
            dismiss(animated: true, completion: onRewardGranted)
        } else {
            openExternalUrl(config.clickUrl)
        }
    }

    @objc private func imageTapped() {
        guard !isRewardReady else { return }
        openExternalUrl(config.clickUrl)
    }

    @objc private func closeTapped() {
        if isRewardReady {
            dismiss(animated: true, completion: onRewardGranted)
        } else if !config.isEvent, hasVisited, remainingTime > 0 {
            let secs = Int(ceil(remainingTime))
            ctaCaption?.isHidden = false
            ctaCaption?.text = "\(secs)초 더 머물고 보상받기"
        } else {
            dismiss(animated: true, completion: onDismiss)
        }
    }

    @objc private func dismissLinkTapped() {
        dismiss(animated: true, completion: onDismiss)
    }

    // MARK: - Visit Tracking

    private func openExternalUrl(_ urlString: String) {
        guard !hasReportedClick else { return }
        var urlStr = urlString
        guard !urlStr.isEmpty else { return }
        if !urlStr.hasPrefix("http://") && !urlStr.hasPrefix("https://") {
            urlStr = "https://\(urlStr)"
        }
        guard let url = URL(string: urlStr) else { return }

        hasReportedClick = true
        hasVisited = true
        clickTime = Date()
        isWaitingForReturn = true
        activateStep2()

        UIApplication.shared.open(url) { [weak self] success in
            guard let self, !success else { return }
            self.hasReportedClick = false
            self.isWaitingForReturn = false
            self.clickTime = nil
            self.hasVisited = false
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.hasReportedClick = false
        }
    }

    func checkVisitDuration() {
        guard isWaitingForReturn, let clickTime else { return }

        let elapsed = Date().timeIntervalSince(clickTime)
        self.clickTime = nil
        isWaitingForReturn = false
        hasReportedClick = false

        if config.isEvent {
            setCtaChecking()
            checkParticipationAndProceed()
            return
        }

        remainingTime = max(0, remainingTime - elapsed)
        if remainingTime <= 0 {
            setCtaChecking()
            checkParticipationAndProceed()
        } else if config.trigger == .visitDuration {
            let secs = Int(ceil(remainingTime))
            ctaCaption?.isHidden = false
            ctaCaption?.text = "\(secs)초 더 머물고 보상받기"
        }
    }

    // MARK: - Reward

    private func setCtaChecking() {
        ctaButton?.isEnabled = false
        ctaButton?.setTitle("확인 중...", for: .normal)
    }

    private func checkParticipationAndProceed() {
        guard let participationChecker, !config.eventId.isEmpty else {
            if config.isEvent {
                showParticipationNotConfirmed()
            } else {
                activateReward()
            }
            return
        }
        let eventId = config.eventId
        Task { [weak self] in
            let participated = await participationChecker(eventId)
            guard let self else { return }
            if participated {
                self.showAlreadyParticipated()
            } else if self.config.isEvent {
                self.showParticipationNotConfirmed()
            } else {
                self.activateReward()
            }
        }
    }

    private func activateReward() {
        isRewardReady = true
        activateStep3()
        ctaButton?.isEnabled = true
        ctaButton?.setTitle(ctaReward, for: .normal)
        ctaCaption?.isHidden = true
    }

    private func showParticipationNotConfirmed() {
        ctaButton?.isEnabled = true
        ctaButton?.setTitle(config.isEvent ? ctaEvent : ctaVisit, for: .normal)
        if config.trigger != .closeButton && !config.isEvent {
            ctaCaption?.isHidden = false
        }
    }

    private func showAlreadyParticipated() {
        recordImpressionOnce()
        activateReward()
    }

    private func recordImpressionOnce() {
        guard !hasRecordedImpression, let trackingAd else { return }
        hasRecordedImpression = true
        trackingAd.recordImpression()
    }

}
