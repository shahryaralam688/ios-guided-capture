/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A wrapper for AR QuickLook viewer that shows the reconstructed USDZ model
 file directly.
*/

import ARKit
import RealityKit
import QuickLook
import SwiftUI
import UIKit
import os

struct ModelView: View {
    let modelFile: URL
    let endCaptureCallback: () -> Void

    var body: some View {
        ARInteractiveModelViewer(modelFile: modelFile, endCaptureCallback: endCaptureCallback)
    }
}

private struct ARInteractiveModelViewer: UIViewControllerRepresentable {
    let modelFile: URL
    let endCaptureCallback: () -> Void

    func makeUIViewController(context: Context) -> ARInteractiveModelViewController {
        ARInteractiveModelViewController(modelFile: modelFile, endCaptureCallback: endCaptureCallback)
    }

    func updateUIViewController(_ uiViewController: ARInteractiveModelViewController, context: Context) {}
}

private final class ARInteractiveModelViewController: UIViewController {
    static let logger = Logger(subsystem: GuidedCaptureSampleApp.subsystem,
                               category: "ARInteractiveModelViewController")

    private let modelFile: URL
    private let endCaptureCallback: () -> Void

    private var arView: ARView!
    private var modelRoot: Entity?
    private var modelAnchor: AnchorEntity?

    private var holoDisplayLink: CADisplayLink?
    private var holoStartTime: CFTimeInterval?
    private var holoBaseTransform: Transform?

    private var isHoloAnimating: Bool = false

    init(modelFile: URL, endCaptureCallback: @escaping () -> Void) {
        self.modelFile = modelFile
        self.endCaptureCallback = endCaptureCallback
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        arView = ARView(frame: .zero)
        arView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(arView)
        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        configureSession()
        addDoneButton()
        addGestureRecognizers()
        loadAndPlaceModel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopHoloAnimation()
        arView.session.pause()
    }

    private func configureSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        arView.session.run(config)
    }

    private func addDoneButton() {
        let button = UIButton(type: .system)
        button.setTitle("Done", for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
    }

    @objc private func doneTapped() {
        endCaptureCallback()
        dismiss(animated: true)
    }

    private func addGestureRecognizers() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        arView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: arView)
        if let entity = arView.entity(at: location), entity.isDescendant(of: modelRoot) {
            startHoloAnimation()
            return
        }
    }

    private func loadAndPlaceModel() {
        do {
            let entity = try Entity.load(contentsOf: modelFile)
            entity.generateCollisionShapes(recursive: true)
            enhanceModelAppearance(entity)

            let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -0.5))
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)

            modelRoot = entity
            modelAnchor = anchor

            addLocalLights(around: entity)
            ARInteractiveModelViewController.logger.log("Loaded USDZ model for interactive AR viewer")
        } catch {
            ARInteractiveModelViewController.logger.error("Failed to load USDZ model: \(error.localizedDescription)")
        }
    }

    private func addLocalLights(around root: Entity) {
        var key = PointLightComponent()
        key.intensity = 5000
        key.attenuationRadius = 2.0
        key.color = UIColor.white

        let keyEntity = Entity()
        keyEntity.components.set(key)
        keyEntity.position = SIMD3<Float>(0.15, 0.25, 0.15)
        root.addChild(keyEntity)

        var rim = SpotLightComponent()
        rim.intensity = 8000
        rim.attenuationRadius = 3.0
        rim.innerAngleInDegrees = 15
        rim.outerAngleInDegrees = 35
        rim.color = UIColor.cyan

        let rimEntity = Entity()
        rimEntity.components.set(rim)
        rimEntity.position = SIMD3<Float>(-0.15, 0.2, 0.15)
        rimEntity.look(at: .zero, from: rimEntity.position, relativeTo: root)
        root.addChild(rimEntity)
    }

    private func enhanceModelAppearance(_ root: Entity) {
        root.visit { entity in
            guard let model = entity as? ModelEntity else { return }

            // Keep material edits minimal and compatible across RealityKit versions.
            // Local lights (added separately) are the primary "holo" brightness boost.
            let existing = model.model?.materials ?? []
            if existing.isEmpty {
                return
            }

            var newMaterials: [RealityKit.Material] = []
            newMaterials.reserveCapacity(existing.count)

            for material in existing {
                newMaterials.append(material)
            }

            model.model?.materials = newMaterials
        }
    }

    private func startHoloAnimation() {
        guard !isHoloAnimating, let root = modelRoot else { return }
        isHoloAnimating = true

        holoBaseTransform = root.transform
        holoStartTime = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(stepHoloAnimation))
        link.add(to: .main, forMode: .common)
        holoDisplayLink = link
    }

    @objc private func stepHoloAnimation() {
        guard let start = holoStartTime,
              let root = modelRoot,
              let base = holoBaseTransform else {
            stopHoloAnimation()
            return
        }

        let elapsed = CACurrentMediaTime() - start
        let duration: Double = 2.6

        if elapsed >= duration {
            root.transform = base
            stopHoloAnimation()
            return
        }

        let t = Float(elapsed)
        let yawAmplitude: Float = .pi / 10.0
        let orbitRadius: Float = 0.015
        let omega: Float = 2.0 * .pi * 1.2

        let yaw = yawAmplitude * sin(omega * t)
        let offsetX = orbitRadius * sin(omega * t)
        let offsetZ = orbitRadius * cos(omega * t)

        var updated = base
        updated.rotation = simd_mul(base.rotation, simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
        updated.translation = base.translation + SIMD3<Float>(offsetX, 0, offsetZ)
        root.transform = updated
    }

    private func stopHoloAnimation() {
        holoDisplayLink?.invalidate()
        holoDisplayLink = nil
        holoStartTime = nil
        isHoloAnimating = false
    }
}

private extension Entity {
    func isDescendant(of ancestor: Entity?) -> Bool {
        guard let ancestor else { return false }
        if self === ancestor { return true }
        return parent?.isDescendant(of: ancestor) ?? false
    }

    func visit(_ block: (Entity) -> Void) {
        block(self)
        for child in children {
            child.visit(block)
        }
    }
}

private struct ARQuickLookController: UIViewControllerRepresentable {
    static let logger = Logger(subsystem: GuidedCaptureSampleApp.subsystem,
                                category: "ARQuickLookController")

    let modelFile: URL
    let endCaptureCallback: () -> Void

    func makeUIViewController(context: Context) -> QLPreviewControllerWrapper {
        let controller = QLPreviewControllerWrapper()
        controller.qlvc.dataSource = context.coordinator
        controller.qlvc.delegate = context.coordinator
        return controller
    }

    func makeCoordinator() -> ARQuickLookController.Coordinator {
        return Coordinator(parent: self)
    }

    func updateUIViewController(_ uiViewController: QLPreviewControllerWrapper, context: Context) {}

    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: ARQuickLookController

        init(parent: ARQuickLookController) {
            self.parent = parent
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.modelFile as QLPreviewItem
        }

        func previewControllerWillDismiss(_ controller: QLPreviewController) {
            ARQuickLookController.logger.log("Exiting ARQL ...")
            parent.endCaptureCallback()
        }
    }
}

private class QLPreviewControllerWrapper: UIViewController {
    let qlvc = QLPreviewController()
    var qlPresented = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !qlPresented {
            present(qlvc, animated: false, completion: nil)
            qlPresented = true
        }
    }
}
