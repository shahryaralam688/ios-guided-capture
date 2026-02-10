import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ARKit
import RealityKit

struct ARModelPickerView: View {
    @State private var isShowingPicker: Bool = false
    @State private var selectedModelURL: IdentifiedURL?

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
            ARHoloUSDZViewer(modelFile: url.url) {
                selectedModelURL = nil
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
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> ARHoloUSDZViewController {
        ARHoloUSDZViewController(modelFile: modelFile, onDone: onDone)
    }

    func updateUIViewController(_ uiViewController: ARHoloUSDZViewController, context: Context) {}
}

private final class ARHoloUSDZViewController: UIViewController {
    private let modelFile: URL
    private let onDone: () -> Void

    private var arView: ARView!
    private var modelRoot: Entity?

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var baseTransform: Transform?
    private var isAnimating: Bool = false

    init(modelFile: URL, onDone: @escaping () -> Void) {
        self.modelFile = modelFile
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

            let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -0.5))
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)
            modelRoot = entity

            addLocalLights(around: entity)
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

    @objc private func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let root = modelRoot else { return }
        let location = recognizer.location(in: arView)
        if let tapped = arView.entity(at: location), tapped.isDescendant(of: root) {
            startAnimation()
        }
    }

    private func startAnimation() {
        guard !isAnimating, let root = modelRoot else { return }
        isAnimating = true
        baseTransform = root.transform
        startTime = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        guard let startTime,
              let root = modelRoot,
              let baseTransform else {
            stopAnimation()
            return
        }

        let elapsed = CACurrentMediaTime() - startTime
        let duration: Double = 2.6

        if elapsed >= duration {
            root.transform = baseTransform
            stopAnimation()
            return
        }

        let t = Float(elapsed)
        let yawAmplitude: Float = .pi / 10.0
        let orbitRadius: Float = 0.015
        let omega: Float = 2.0 * .pi * 1.2

        let yaw = yawAmplitude * sin(omega * t)
        let offsetX = orbitRadius * sin(omega * t)
        let offsetZ = orbitRadius * cos(omega * t)

        var updated = baseTransform
        updated.rotation = simd_mul(baseTransform.rotation, simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
        updated.translation = baseTransform.translation + SIMD3<Float>(offsetX, 0, offsetZ)
        root.transform = updated
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        startTime = nil
        isAnimating = false
    }
}

private extension Entity {
    func isDescendant(of ancestor: Entity) -> Bool {
        if self === ancestor { return true }
        return parent?.isDescendant(of: ancestor) ?? false
    }
}
