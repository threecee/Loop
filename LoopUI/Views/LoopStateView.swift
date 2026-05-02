//
//  LoopStateView.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/7/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit

final class LoopStateView: UIView {
    var firstDataUpdate = true
    
    override func tintColorDidChange() {
        super.tintColorDidChange()

        updateTintColor()
    }

    private func updateTintColor() {
        shapeLayer.strokeColor = tintColor.cgColor
    }

    var open = false {
        didSet {
            if open != oldValue {
                shapeLayer.path = drawPath()
            }
        }
    }

    override class var layerClass : AnyClass {
        return CAShapeLayer.self
    }

    private var shapeLayer: CAShapeLayer {
        return layer as! CAShapeLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        shapeLayer.lineWidth = 8
        shapeLayer.fillColor = UIColor.clear.cgColor
        updateTintColor()

        shapeLayer.path = drawPath()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        shapeLayer.lineWidth = 8
        shapeLayer.fillColor = UIColor.clear.cgColor
        updateTintColor()

        shapeLayer.path = drawPath()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        shapeLayer.path = drawPath()
        innerLayer.path = drawInnerPath()
        // Inner layer frame doesn't need updating because we draw an absolute path
        // from bounds.mid each layout.
    }

    private func drawPath(lineWidth: CGFloat? = nil) -> CGPath {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let lineWidth = lineWidth ?? shapeLayer.lineWidth
        let radius = min(bounds.width / 2, bounds.height / 2) - lineWidth / 2

        let startAngle = open ? -CGFloat.pi / 4 : 0
        let endAngle = open ? 5 * CGFloat.pi / 4 : 2 * CGFloat.pi

        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )

        return path.cgPath
    }

    private static let AnimationKey = "com.loudnate.Naterade.breatheAnimation"
    private static let PulseAnimationKey = "handoffPulse"

    /// B.7: when true, render the inner driver indicator (small white-filled
    /// circle at center) showing this device is currently driving the pod.
    /// When false, the inner indicator is hidden.
    var isThisDeviceDriving: Bool = false {
        didSet {
            if isThisDeviceDriving != oldValue { updateInnerIndicator() }
        }
    }

    /// B.7: when true, the inner driver indicator pulses (opacity breathe)
    /// to signal a handoff transition is in progress. When false, the pulse
    /// animation is removed. Independent of `isThisDeviceDriving` — the
    /// animation is added either way (when not driving, the layer is hidden
    /// so the user doesn't see it).
    var isHandoffPending: Bool = false {
        didSet {
            if isHandoffPending != oldValue { updateInnerIndicator() }
        }
    }

    /// Inner indicator layer. Hidden by default until `isThisDeviceDriving`
    /// flips to true.
    private lazy var innerLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.white.cgColor
        layer.strokeColor = UIColor.clear.cgColor
        layer.isHidden = true
        self.layer.addSublayer(layer)
        return layer
    }()

    /// Test-only accessor for the inner layer.
    internal var innerLayerForTesting: CAShapeLayer { innerLayer }

    private func updateInnerIndicator() {
        innerLayer.path = drawInnerPath()
        innerLayer.isHidden = !isThisDeviceDriving

        if isHandoffPending {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.4
            pulse.duration = 0.8
            pulse.repeatCount = .greatestFiniteMagnitude
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            innerLayer.add(pulse, forKey: Self.PulseAnimationKey)
        } else {
            innerLayer.removeAnimation(forKey: Self.PulseAnimationKey)
        }
    }

    private func drawInnerPath() -> CGPath {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outerRadius = min(bounds.width / 2, bounds.height / 2) - shapeLayer.lineWidth / 2
        let innerRadius = outerRadius / 4
        let path = UIBezierPath(
            arcCenter: center,
            radius: innerRadius,
            startAngle: 0,
            endAngle: 2 * CGFloat.pi,
            clockwise: true
        )
        return path.cgPath
    }

    var animated: Bool = false {
        didSet {
            if animated != oldValue {
                if animated {
                    let path = CABasicAnimation(keyPath: "path")
                    path.fromValue = shapeLayer.path ?? drawPath()
                    path.toValue = drawPath(lineWidth: 16)

                    let width = CABasicAnimation(keyPath: "lineWidth")
                    width.fromValue = shapeLayer.lineWidth
                    width.toValue = 10

                    let group = CAAnimationGroup()
                    group.animations = [path, width]
                    group.duration = firstDataUpdate ? 0 : 1
                    group.repeatCount = HUGE
                    group.autoreverses = true
                    group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                    shapeLayer.add(group, forKey: type(of: self).AnimationKey)
                } else {
                    shapeLayer.removeAnimation(forKey: type(of: self).AnimationKey)
                }
            }
            firstDataUpdate = false
        }
    }
}

