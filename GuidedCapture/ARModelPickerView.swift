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

    private var keyLightEntity: Entity?
    private var rimLightEntity: Entity?
    private var originalKeyIntensity: Float?
    private var originalRimIntensity: Float?

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var baseTransform: Transform?
    private var isAnimating: Bool = false

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

        addCoachingOverlay()

        addDoneButton()
        loadModel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
            // Create a pivot that is centered on the model's visual bounds.
            // Rotating the pivot will spin the model around its own center (not an offset origin).
            let bounds = entity.visualBounds(relativeTo: nil)
            let center = bounds.center

            let pivot = ModelEntity()
            entity.position = -center
            pivot.addChild(entity)

            // Ensure pivot is gesture-capable (ModelEntity conforms to HasCollision, but needs collision shapes to hit-test reliably).
            pivot.generateCollisionShapes(recursive: true)

            modelRoot = entity
            modelPivot = pivot
            gestureTarget = pivot

            addLocalLights(around: entity)

            // QuickLook-style placement: automatically attach the model to a horizontal plane anchor.
            // This will place the model as soon as ARKit detects a surface.
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

                if let gestureTarget {
                    arView.installGestures([.translation, .rotation, .scale], for: gestureTarget)
                }
            }
        } catch {
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

        keyLightEntity = keyEntity
        originalKeyIntensity = key.intensity

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

        rimLightEntity = rimEntity
        originalRimIntensity = rim.intensity
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
            if isAnimating {
                stopAnimationEarlyAndHideDetails()
            } else {
                startAnimation()
            }
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
