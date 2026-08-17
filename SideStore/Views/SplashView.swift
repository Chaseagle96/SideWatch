//
//  SplashView.swift
//  SideStore
//
//  Created by Magesh K on 14/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

final class SplashView: UIView {
    let iconView    = UIImageView()
    let titleLabel  = UILabel()
    private let statusLabel = UILabel()
    private var iconContainer: UIView!
    private var animationsStarted = false
    private var currentBaseStatus: String = ""
    private var dotCount = 1
    private var dotTimer: Timer?

    // MARK: - Init

    init(frame: CGRect, appName: String) {
        super.init(frame: frame)
        debugLog("[SplashView] init — splash screen presented")
        backgroundColor = .systemBackground
        setupIcon()
        setupTitle(appName: appName)
        setupStatus()
        // NOTE: animations are started in didMoveToWindow() once the layer is in the render tree
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !animationsStarted else { return }
        animationsStarted = true
        startAnimations()
    }

    deinit {
        debugLog("[SplashView] deinit — splash screen removed from memory")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            debugLog("[SplashView] willMove(toSuperview: nil) — splash screen being removed from view hierarchy")
            stopAnimations()
        }
    }

    // MARK: - Public

    @MainActor
    func updateStatus(_ text: String) {
        let cleanText = text.trimmingCharacters(in: CharacterSet(charactersIn: ".… "))
        self.currentBaseStatus = cleanText
        self.renderStatus()
        debugLog("[SplashView] status: \(text)")
    }

    private func renderStatus() {
        guard !currentBaseStatus.isEmpty else {
            statusLabel.text = ""
            return
        }
        let dots = String(repeating: ".", count: dotCount)
        statusLabel.text = "\(currentBaseStatus)\(dots)"
    }

    // MARK: - Animations

    private func startAnimations() {
        startBreatheAnimation()
        startDotAnimation()
    }

    private func stopAnimations() {
        iconContainer?.layer.removeAnimation(forKey: "breathe")
        stopDotAnimation()
    }

    private func startDotAnimation() {
        dotTimer?.invalidate()
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dotCount = (self.dotCount % 3) + 1
            self.renderStatus()
        }
    }

    private func stopDotAnimation() {
        dotTimer?.invalidate()
        dotTimer = nil
    }

    private func startBreatheAnimation() {
        // Gently pulse scale 1.0 → 1.05 → 1.0, no color, no shadow artifacts
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue  = 1.0
        scale.toValue    = 1.05
        scale.duration   = 1.8
        scale.autoreverses  = true
        scale.repeatCount   = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconContainer.layer.add(scale, forKey: "breathe")
    }


    // MARK: - Layout setup

    private func setupIcon() {
        iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.shadowColor   = UIColor.black.cgColor
        iconContainer.layer.shadowOpacity = 0.25
        iconContainer.layer.shadowOffset  = CGSize(width: 0, height: 4)
        iconContainer.layer.shadowRadius  = 8
        addSubview(iconContainer)

        iconView.image       = UIImage(named: "AppIcon") ?? UIImage(named: "AppIcon60x60") ?? UIImage(systemName: "app.fill")
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.layer.cornerRadius = 24
        iconView.clipsToBounds      = true
        iconContainer.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            iconContainer.widthAnchor.constraint(equalToConstant: 120),
            iconContainer.heightAnchor.constraint(equalToConstant: 120),

            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor)
        ])
    }

    private func setupTitle(appName: String) {
        titleLabel.text          = appName
        titleLabel.font          = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor     = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    private func setupStatus() {
        statusLabel.text          = ""
        statusLabel.font          = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor     = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 32),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }
}
