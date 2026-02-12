//
//  ARModelPickerView 2.swift
//  GuidedCapture
//
//  Created by Shahryar Alam on 11/02/2026.
//  Copyright © 2026 Apple. All rights reserved.
//


import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ARKit
import RealityKit

struct ARModelPickerView: View {
    @State private var isShowingPicker: Bool = false
    @State private var selectedModelURL: IdentifiedURL?
    @State private var isShowingDetails: Bool = false
    @State private var currentModelDetails: ModelDetails?

    var body: some View {
        VStack(spacing: 16) {
            Button("Select 3D Model") {
                isShowingPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $isShowingPicker) {
            USDZDocumentPicker(startingDirectory: Self.defaultStartingDirectory) { url in
                selectedModelURL = IdentifiedURL(url)
                isShowingPicker = false
            }
        }
        .fullScreenCover(item: $selectedModelURL) { url in
            ZStack(alignment: .bottom) {
                ARHoloUSDZViewer(
                    modelFile: url.url,
                    onAnimationStart: { details in
                        currentModelDetails = details
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isShowingDetails = true
                        }
                    },
                    onAnimationEnd: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isShowingDetails = false
                        }
                    },
                    onDone: {
                        selectedModelURL = nil
                    }
                )

                if isShowingDetails, let details = currentModelDetails {
                    ModelDetailsPanel(details: details)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private static var defaultStartingDirectory: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("Scans", isDirectory: true)
    }
}

private struct ModelDetails: Equatable {
    let name: String
    let sizeText: String
    let description: String
}

private struct ModelDetailsPanel: View {
    let details: ModelDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details.name)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(details.sizeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(details.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct IdentifiedURL: Identifiable {
    let id: String
    let url: URL

    init(_ url: URL) {
        self.url = url
        self.id = url.absoluteString
    }
}

private struct USDZDocumentPicker: UIViewControllerRepresentable {
    let startingDirectory: URL?
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let usdzType = UTType(filenameExtension: "usdz") ?? .item
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [usdzType], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        if let startingDirectory {
            picker.directoryURL = startingDirectory
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            onPick(url)
        }
    }
}

private struct ARHoloUSDZViewer: UIViewControllerRepresentable {
    let modelFile: URL
    let onAnimationStart: (ModelDetails) -> Void
    let onAnimationEnd: () -> Void
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> ARHoloUSDZViewController {
        ARHoloUSDZViewController(
            modelFile: modelFile,
            onAnimationStart: onAnimationStart,
            onAnimationEnd: onAnimationEnd,
            onDone: onDone
        )
    }

    func updateUIViewController(_ uiViewController: ARHoloUSDZViewController, context: Context) {}
}

private final class ARHoloUSDZViewController: UIViewController {
    private let modelFile: URL
    private let onAnimationStart: (ModelDetails) -> Void
    private let onAnimationEnd: () -> Void
    private let onDone: () -> Void

    private var arView: ARView!
    private var modelRoot: Entity?
    private var modelPivot: ModelEntity?

    private var gestureTarget: (Entity & HasCollision)?

    private var placementAnchor: AnchorEntity?
    private var isPlaced: Bool = false
    private var isModelEnlarged: Bool = false
    private var originalScale: SIMD3<Float>?
    private var originalTransformBeforeEnlarge: Transform?

    private var isLongPressHoloActive: Bool = false
    private var longPressWorkItems: [DispatchWorkItem] = []
    private var longPressHoloStartTime: CFTimeInterval?
    private var longPressHoloBaseTransform: Transform?
    private var longPressHoloLights: [Entity] = []

    private let liftDistance: Float = 0.3
    private let liftDuration: TimeInterval = 2.5
    private let scaleDuration: TimeInterval = 1.2

    private var keyLightEntity: Entity?
    private var rimLightEntity: Entity?
    private var originalKeyIntensity: Float?
    private var originalRimIntensity: Float?

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var baseTransform: Transform?
    private var isAnimating: Bool = false

    private var hologramOverlayView: HologramOverlayView?
    private var hologramEntity: ModelEntity?
    private var hologramAnchor: AnchorEntity?

    init(
        modelFile: URL,
        onAnimationStart: @escaping (ModelDetails) -> Void,
        onAnimationEnd: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.modelFile = modelFile
        self.onAnimationStart = onAnimationStart
        self.onAnimationEnd = onAnimationEnd
        self.onDone = onDone
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

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        arView.session.run(config)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        arView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(didSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        arView.addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        arView.addGestureRecognizer(longPress)

        addCoachingOverlay()

        addDoneButton()
        loadModel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLongPressHoloAndRestoreIfNeeded()
        stopAnimation()
        arView.session.pause()
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
        onDone()
        dismiss(animated: true)
    }

    private func loadModel() {
        do {
            let entity = try Entity.load(contentsOf: modelFile)
            entity.generateCollisionShapes(recursive: true)
            let bounds = entity.visualBounds(relativeTo: nil)
            let center = bounds.center

            let pivot = ModelEntity()
            entity.position = -center
            pivot.addChild(entity)

            pivot.generateCollisionShapes(recursive: true)

            modelRoot = entity
            modelPivot = pivot
            gestureTarget = pivot

            addLocalLights(around: entity)

            if placementAnchor == nil {
                let planeAnchor: AnchorEntity
                if #available(iOS 13.4, *) {
                    planeAnchor = AnchorEntity(.plane(.horizontal,
                                                     classification: .any,
                                                     minimumBounds: SIMD2<Float>(0.2, 0.2)))
                } else {
                    planeAnchor = AnchorEntity(.plane(.horizontal,
                                                     classification: .any,
                                                     minimumBounds: SIMD2<Float>(0.2, 0.2)))
                }

                planeAnchor.addChild(pivot)
                arView.scene.addAnchor(planeAnchor)

                placementAnchor = planeAnchor
                isPlaced = true

                // Gentle initial rise so the user can clearly see the model settle above the floor.
                // Use RealityKit animation (not UIView.animate) so the entity transform actually animates.
                let parent = pivot.parent
                let finalTransform = pivot.transform
                var startTransform = finalTransform
                startTransform.translation.y -= liftDistance
                pivot.transform = startTransform
                pivot.move(to: finalTransform, relativeTo: parent, duration: liftDuration, timingFunction: .easeInOut)

                if let gestureTarget {
                    arView.installGestures([.translation, .rotation, .scale], for: gestureTarget)
                }
            }
        } catch {
        }
    }

    private func addLocalLights(around root: Entity) {
        var key = PointLightComponent()
        key.intensity = 6000
        key.attenuationRadius = 2.5
        key.color = UIColor.white

        let keyEntity = Entity()
        keyEntity.components.set(key)
        keyEntity.position = SIMD3<Float>(0.2, 0.3, 0.2)
        root.addChild(keyEntity)

        keyLightEntity = keyEntity
        originalKeyIntensity = key.intensity

        var fill = PointLightComponent()
        fill.intensity = 4000
        fill.attenuationRadius = 2.5
        fill.color = UIColor.white

        let fillEntity = Entity()
        fillEntity.components.set(fill)
        fillEntity.position = SIMD3<Float>(-0.2, 0.2, 0.2)
        root.addChild(fillEntity)

        rimLightEntity = fillEntity
        originalRimIntensity = fill.intensity
    }

    private func addCoachingOverlay() {
        let overlay = ARCoachingOverlayView()
        overlay.session = arView.session
        overlay.goal = .horizontalPlane
        overlay.activatesAutomatically = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func didSingleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isPlaced, let modelPivot else { return }
        let location = recognizer.location(in: arView)

        let results = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal)
        guard let first = results.first else {
            return
        }

        let anchor = AnchorEntity(world: first.worldTransform.translation)
        anchor.addChild(modelPivot)
        arView.scene.addAnchor(anchor)

        placementAnchor = anchor
        isPlaced = true

        if let gestureTarget {
            arView.installGestures([.translation, .rotation, .scale], for: gestureTarget)
        }
    }

    @objc private func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard isPlaced, let pivot = modelPivot, let root = modelRoot else { return }
        let location = recognizer.location(in: arView)
        if let tapped = arView.entity(at: location), tapped.isDescendant(of: root) || tapped.isDescendant(of: pivot) {
            showHologramOverlay()
        }
    }

    @objc private func didLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, isPlaced, let pivot = modelPivot, let root = modelRoot else { return }
        let location = recognizer.location(in: arView)
        if let tapped = arView.entity(at: location), tapped.isDescendant(of: root) || tapped.isDescendant(of: pivot) {
            toggleLongPressHolo()
        }
    }

    private func addHoloHDRIAndLights(to root: Entity) {
        // Multiple point lights for holo effect.
        let lightPositions: [(SIMD3<Float>, Float)] = [
            (SIMD3<Float>(0.2, 0.3, 0.2), 5000),
            (SIMD3<Float>(-0.2, 0.3, 0.2), 5000),
            (SIMD3<Float>(0.2, 0.3, -0.2), 5000),
            (SIMD3<Float>(-0.2, 0.3, -0.2), 5000),
            (SIMD3<Float>(0.2, 0, 0.2), 4000),
            (SIMD3<Float>(-0.2, 0, 0.2), 4000),
            (SIMD3<Float>(0.2, 0, -0.2), 4000),
            (SIMD3<Float>(-0.2, 0, -0.2), 4000),
            (SIMD3<Float>(0, 0.4, 0), 6000),
            (SIMD3<Float>(0, -0.1, 0.3), 4000),
            (SIMD3<Float>(0, 0, 0.3), 5000),
            (SIMD3<Float>(0, 0, -0.3), 5000)
        ]

        for (position, intensity) in lightPositions {
            var light = PointLightComponent()
            light.intensity = intensity
            light.attenuationRadius = 3.0
            light.color = UIColor.white

            let entity = Entity()
            entity.components.set(light)
            entity.position = position
            root.addChild(entity)
            longPressHoloLights.append(entity)
        }

        var topLight = DirectionalLightComponent()
        topLight.intensity = 7000
        topLight.color = UIColor.white

        let topEntity = Entity()
        topEntity.components.set(topLight)
        topEntity.look(at: .zero, from: SIMD3<Float>(0, 1, 0), relativeTo: nil)
        root.addChild(topEntity)
        longPressHoloLights.append(topEntity)

        var bottomLight = DirectionalLightComponent()
        bottomLight.intensity = 5000
        bottomLight.color = UIColor.white

        let bottomEntity = Entity()
        bottomEntity.components.set(bottomLight)
        bottomEntity.look(at: .zero, from: SIMD3<Float>(0, -1, 0), relativeTo: nil)
        root.addChild(bottomEntity)
        longPressHoloLights.append(bottomEntity)
    }

    private func removeHoloHDRIAndLights() {
        for light in longPressHoloLights {
            light.removeFromParent()
        }
        longPressHoloLights.removeAll()
    }

    private func toggleLongPressHolo() {
        guard let pivot = modelPivot else { return }

        if isLongPressHoloActive {
            stopLongPressHoloAndRestoreIfNeeded()
            return
        }

        cancelLongPressWorkItems()
        stopAnimation()
        isLongPressHoloActive = true

        originalTransformBeforeEnlarge = pivot.transform
        originalScale = pivot.scale

        // Add HDRI lighting and multiple point lights for holo effect.
        addHoloHDRIAndLights(to: pivot)
        setHoloLightingBoosted(true)

        guard let originalScale else { return }
        let enlargedScale = originalScale * SIMD3<Float>(repeating: 3.0)

        let parent = pivot.parent

        // Step 1: lift slowly.
        let current = pivot.transform
        var lifted = current
        lifted.translation.y += liftDistance
        pivot.move(to: lifted, relativeTo: parent, duration: liftDuration, timingFunction: .easeInOut)

        // Step 2: after lift completes, scale up gradually.
        let scaleWork = DispatchWorkItem { [weak self, weak pivot] in
            guard let self, let pivot else { return }
            var scaled = pivot.transform
            scaled.scale = enlargedScale
            pivot.move(to: scaled, relativeTo: parent, duration: self.scaleDuration, timingFunction: .easeInOut)

            // Step 3: after scaling completes, begin continuous holo motion.
            let startHoloWork = DispatchWorkItem { [weak self, weak pivot] in
                guard let self, let pivot else { return }
                self.longPressHoloBaseTransform = pivot.transform
                self.startLongPressHoloMotionLoop()
            }
            self.longPressWorkItems.append(startHoloWork)
            DispatchQueue.main.asyncAfter(deadline: .now() + self.scaleDuration, execute: startHoloWork)
        }

        longPressWorkItems.append(scaleWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + self.liftDuration, execute: scaleWork)
    }

    private func startLongPressHoloMotionLoop() {
        guard isLongPressHoloActive, displayLink == nil else { return }
        longPressHoloStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepLongPressHolo))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepLongPressHolo() {
        guard isLongPressHoloActive,
              let start = longPressHoloStartTime,
              let pivot = modelPivot,
              let base = longPressHoloBaseTransform else {
            stopAnimation()
            return
        }

        let elapsed = CACurrentMediaTime() - start
        let t = Float(elapsed)

        // Continuous left-to-right rotation + subtle tilt + gentle bob.
        let omega: Float = 2.0 * .pi * 0.5
        let tiltAmplitudeDeg: Float = 8.0
        let bobAmplitude: Float = 0.01

        let yaw = omega * t  // Continuous rotation in one direction only
        let tilt = (tiltAmplitudeDeg * .pi / 180.0) * sin(omega * 0.8 * t)
        let bob = bobAmplitude * sin(omega * 1.2 * t)

        var updated = base
        let yawRot = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let tiltRot = simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0))
        updated.rotation = simd_mul(simd_mul(base.rotation, yawRot), tiltRot)
        updated.translation = base.translation + SIMD3<Float>(0, bob, 0)
        pivot.transform = updated
    }

    private func stopLongPressHoloAndRestoreIfNeeded() {
        guard let pivot = modelPivot else { return }

        cancelLongPressWorkItems()
        isLongPressHoloActive = false
        longPressHoloStartTime = nil
        longPressHoloBaseTransform = nil
        stopAnimation()

        // Remove HDRI lighting and restore original lighting.
        removeHoloHDRIAndLights()
        setHoloLightingBoosted(false)

        if let original = originalTransformBeforeEnlarge {
            let parent = pivot.parent
            pivot.move(to: original, relativeTo: parent, duration: liftDuration, timingFunction: .easeInOut)
        }
    }

    private func cancelLongPressWorkItems() {
        for item in longPressWorkItems {
            item.cancel()
        }
        longPressWorkItems.removeAll()
    }


    private func showHologramOverlay() {
        guard let root = modelRoot else { return }

        let overlay = HologramOverlayView(modelEntity: root, modelFile: modelFile)
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.alpha = 0
        view.addSubview(overlay)

        hologramOverlayView = overlay
        overlay.showHologram { [weak self] in
            self?.hologramOverlayView?.removeFromSuperview()
            self?.hologramOverlayView = nil
        }
    }

    private func stopAnimationEarlyAndHideDetails() {
        if let pivot = modelPivot, let baseTransform {
            pivot.transform = baseTransform
        }
        setHoloLightingBoosted(false)
        stopAnimation()
        onAnimationEnd()
    }

    private func startAnimation() {
        guard !isAnimating, let pivot = modelPivot else { return }
        isAnimating = true
        baseTransform = pivot.transform
        startTime = CACurrentMediaTime()

        setHoloLightingBoosted(true)

        if let details = makeModelDetails() {
            onAnimationStart(details)
        }

        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        guard let startTime,
              let pivot = modelPivot,
              let baseTransform else {
            stopAnimation()
            return
        }

        let elapsed = CACurrentMediaTime() - startTime
        let duration: Double = 2.6

        if elapsed >= duration {
            pivot.transform = baseTransform
            setHoloLightingBoosted(false)
            stopAnimation()
            onAnimationEnd()
            return
        }

        // Premium "holo" motion while staying anchored:
        // - 360 yaw spin with ease-in-out
        // - subtle, very small local float/orbit (does not change the surface anchor)
        let progress = Float(elapsed / duration)
        let eased = 0.5 - 0.5 * cos(.pi * progress)
        let angle = 2.0 * Float.pi * eased

        let t = Float(elapsed)
        let omega: Float = 2.0 * .pi * 1.0
        let orbitRadius: Float = 0.004
        let floatAmplitude: Float = 0.004
        let offsetX = orbitRadius * sin(omega * t)
        let offsetZ = orbitRadius * cos(omega * t)
        let offsetY = floatAmplitude * sin(omega * 0.7 * t)

        var updated = baseTransform
        updated.rotation = simd_mul(baseTransform.rotation, simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)))
        updated.translation = baseTransform.translation + SIMD3<Float>(offsetX, offsetY, offsetZ)
        pivot.transform = updated
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        startTime = nil
        isAnimating = false
    }

    private func makeModelDetails() -> ModelDetails? {
        guard let root = modelRoot else { return nil }
        let bounds = root.visualBounds(relativeTo: nil)
        let extents = bounds.extents

        let widthCM = extents.x * 100
        let heightCM = extents.y * 100
        let depthCM = extents.z * 100

        let name = modelFile.deletingPathExtension().lastPathComponent
        let sizeText = String(format: "Size: %.1f × %.1f × %.1f cm", widthCM, heightCM, depthCM)
        let description = "Tap to preview. Double‑tap to view hologram rotation."

        return ModelDetails(name: name, sizeText: sizeText, description: description)
    }

    private func setHoloLightingBoosted(_ boosted: Bool) {
        if boosted {
            if var key = keyLightEntity?.components[PointLightComponent.self], let originalKeyIntensity {
                key.intensity = originalKeyIntensity * 1.8
                keyLightEntity?.components.set(key)
            }
            if var rim = rimLightEntity?.components[SpotLightComponent.self], let originalRimIntensity {
                rim.intensity = originalRimIntensity * 2.0
                rimLightEntity?.components.set(rim)
            }
        } else {
            if var key = keyLightEntity?.components[PointLightComponent.self], let originalKeyIntensity {
                key.intensity = originalKeyIntensity
                keyLightEntity?.components.set(key)
            }
            if var rim = rimLightEntity?.components[SpotLightComponent.self], let originalRimIntensity {
                rim.intensity = originalRimIntensity
                rimLightEntity?.components.set(rim)
            }
        }
    }
}

private extension Entity {
    func isDescendant(of ancestor: Entity) -> Bool {
        if self === ancestor { return true }
        return parent?.isDescendant(of: ancestor) ?? false
    }

    func firstCollisionCapableDescendant() -> (Entity & HasCollision)? {
        if let selfAsCollision = self as? (Entity & HasCollision) {
            return selfAsCollision
        }
        for child in children {
            if let found = child.firstCollisionCapableDescendant() {
                return found
            }
        }
        return nil
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

private class HologramOverlayView: UIView {
    private var modelEntity: Entity
    private var modelFile: URL
    private var holoARView: ARView!
    private var holoAnchor: AnchorEntity?
    private var holoPivot: ModelEntity?
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var completion: (() -> Void)?
    private var closeButton: UIButton!
    private var detailsPanel: UIView!

    init(modelEntity: Entity, modelFile: URL) {
        self.modelEntity = modelEntity
        self.modelFile = modelFile
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showHologram(completion: @escaping () -> Void) {
        self.completion = completion

        holoARView = ARView(frame: .zero)
        holoARView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(holoARView)
        NSLayoutConstraint.activate([
            holoARView.leadingAnchor.constraint(equalTo: leadingAnchor),
            holoARView.trailingAnchor.constraint(equalTo: trailingAnchor),
            holoARView.topAnchor.constraint(equalTo: topAnchor),
            holoARView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        addCloseButton()
        addDetailsPanel()

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        config.environmentTexturing = .automatic
        holoARView.session.run(config)

        setupHologramModel()

        UIView.animate(withDuration: 0.5) {
            self.alpha = 1
        } completion: { _ in
            self.startHologramAnimation()
        }
    }

    private func addCloseButton() {
        closeButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        let xImage = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        closeButton.setImage(xImage, for: .normal)
        closeButton.tintColor = .white
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
    }

    private func addDetailsPanel() {
        detailsPanel = UIView()
        detailsPanel.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        detailsPanel.layer.cornerRadius = 24
        detailsPanel.layer.borderWidth = 0.5
        detailsPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        detailsPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailsPanel)

        NSLayoutConstraint.activate([
            detailsPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            detailsPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detailsPanel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20),
            detailsPanel.heightAnchor.constraint(equalToConstant: 160)
        ])

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        detailsPanel.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: detailsPanel.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: detailsPanel.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: detailsPanel.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: detailsPanel.bottomAnchor, constant: -16)
        ])

        let dishRow = createDetailRow(title: "Greek Salad", subtitle: "$12.99")
        stackView.addArrangedSubview(dishRow)

        let descRow = createDetailRow(title: "Fresh mixed greens, tomatoes, cucumbers, olives, feta cheese, olive oil", subtitle: nil)
        descRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        stackView.addArrangedSubview(descRow)

        let statsRow = createDetailRow(title: "Portion: Large", subtitle: "320 cal")
        stackView.addArrangedSubview(statsRow)

        let allergyRow = createDetailRow(title: "Allergens:", subtitle: "Dairy • Gluten")
        stackView.addArrangedSubview(allergyRow)
    }

    private func createDetailRow(title: String, subtitle: String?) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.alignment = .center

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.textColor = UIColor.cyan.withAlphaComponent(0.9)

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(subtitleLabel)

        return row
    }

    private func getModelSizeInfo() -> String {
        do {
            let entity = try Entity.load(contentsOf: modelFile)
            let bounds = entity.visualBounds(relativeTo: nil)
            let extents = bounds.extents

            let widthCM = extents.x * 100
            let heightCM = extents.y * 100
            let depthCM = extents.z * 100

            return String(format: "Size: %.1f × %.1f × %.1f cm", widthCM, heightCM, depthCM)
        } catch {
            return "Dimensions unavailable"
        }
    }

    @objc private func closeTapped() {
        stopAnimation()
        UIView.animate(withDuration: 0.3) {
            self.alpha = 0
        } completion: { _ in
            self.completion?()
        }
    }

    private func setupHologramModel() {
        do {
            let entity = try Entity.load(contentsOf: modelFile)
            let bounds = entity.visualBounds(relativeTo: nil)
            let center = bounds.center

            let pivot = ModelEntity()
            entity.position = -center
            pivot.addChild(entity)
            pivot.generateCollisionShapes(recursive: true)

            holoPivot = pivot

            holoAnchor = AnchorEntity(world: SIMD3<Float>(0, 0, -0.5))
            holoAnchor?.addChild(pivot)
            holoARView.scene.addAnchor(holoAnchor!)

            let scaleFactor = calculateOptimalScale(for: bounds)
            pivot.scale = SIMD3<Float>(repeating: scaleFactor)

            applyHologramMaterial(to: pivot)
            addHDRIAndLights(to: pivot)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
            doubleTap.numberOfTapsRequired = 2
            holoARView.addGestureRecognizer(doubleTap)

        } catch {
            print("Failed to load model for hologram: \(error)")
        }
    }

    private func calculateOptimalScale(for bounds: BoundingBox) -> Float {
        let maxExtent = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        let targetSize: Float = 0.3
        return targetSize / maxExtent
    }

    private func applyHologramMaterial(to entity: ModelEntity) {
        var material = SimpleMaterial()
        material.color = .init(tint: .white.withAlphaComponent(0.9))
        material.metallic = .float(0.7)
        material.roughness = .float(0.3)
        entity.model?.materials = [material]

        var glowMaterial = UnlitMaterial()
        glowMaterial.color = .init(tint: UIColor.white.withAlphaComponent(0.2))
        entity.model?.materials.append(glowMaterial)
    }

    private func addHDRIAndLights(to root: Entity) {
        let lightPositions: [(SIMD3<Float>, Float)] = [
            (SIMD3<Float>(0.2, 0.3, 0.2), 5000),
            (SIMD3<Float>(-0.2, 0.3, 0.2), 5000),
            (SIMD3<Float>(0.2, 0.3, -0.2), 5000),
            (SIMD3<Float>(-0.2, 0.3, -0.2), 5000),
            (SIMD3<Float>(0.2, 0, 0.2), 4000),
            (SIMD3<Float>(-0.2, 0, 0.2), 4000),
            (SIMD3<Float>(0.2, 0, -0.2), 4000),
            (SIMD3<Float>(-0.2, 0, -0.2), 4000),
            (SIMD3<Float>(0, 0.4, 0), 6000),
            (SIMD3<Float>(0, -0.1, 0.3), 4000),
            (SIMD3<Float>(0, 0, 0.3), 5000),
            (SIMD3<Float>(0, 0, -0.3), 5000)
        ]

        for (position, intensity) in lightPositions {
            var light = PointLightComponent()
            light.intensity = intensity
            light.attenuationRadius = 3.0
            light.color = UIColor.white

            let entity = Entity()
            entity.components.set(light)
            entity.position = position
            root.addChild(entity)
        }

        var topLight = DirectionalLightComponent()
        topLight.intensity = 7000
        topLight.color = UIColor.white

        let topEntity = Entity()
        topEntity.components.set(topLight)
        topEntity.look(at: .zero, from: SIMD3<Float>(0, 1, 0), relativeTo: nil)
        root.addChild(topEntity)

        var bottomLight = DirectionalLightComponent()
        bottomLight.intensity = 5000
        bottomLight.color = UIColor.white

        let bottomEntity = Entity()
        bottomEntity.components.set(bottomLight)
        bottomEntity.look(at: .zero, from: SIMD3<Float>(0, -1, 0), relativeTo: nil)
        root.addChild(bottomEntity)
    }

    private func startHologramAnimation() {
        guard let pivot = holoPivot else { return }

        startTime = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(stepAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepAnimation() {
        guard let startTime = startTime,
              let pivot = holoPivot else {
            stopAnimation()
            return
        }

        let elapsed = CACurrentMediaTime() - startTime

        let cycleDuration: Double = 3.5
        let pauseDuration: Double = 0.4
        let totalCycle = cycleDuration + pauseDuration

        let cycleProgress = elapsed.truncatingRemainder(dividingBy: totalCycle)
        var rotationProgress: Float = 0

        if cycleProgress < cycleDuration {
            rotationProgress = Float(cycleProgress / cycleDuration)
        } else {
            rotationProgress = 1.0
        }

        let eased = 0.5 - 0.5 * cos(.pi * rotationProgress)
        let fullRotations = Float(elapsed / cycleDuration)
        let currentRotation = 2.0 * Float.pi * fullRotations + 2.0 * Float.pi * eased

        let floatElapsed = Float(elapsed)
        let floatFreq: Float = 2.5
        let floatAmp: Float = 0.02
        let floatOffset = floatAmp * sin(floatFreq * floatElapsed)

        let tiltAngle = Float(10.0 + 5.0 * sin(floatFreq * 0.5 * floatElapsed))

        var transform = Transform()
        let rotationY = simd_quatf(angle: currentRotation, axis: SIMD3<Float>(0, 1, 0))
        let rotationX = simd_quatf(angle: tiltAngle * .pi / 180.0, axis: SIMD3<Float>(1, 0, 0))
        transform.rotation = simd_mul(rotationY, rotationX)
        transform.translation = SIMD3<Float>(0, floatOffset, 0)
        transform.scale = pivot.scale

        pivot.transform = transform
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        startTime = nil
    }

    override func removeFromSuperview() {
        stopAnimation()
        super.removeFromSuperview()
    }
}
