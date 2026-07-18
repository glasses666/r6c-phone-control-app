import AppKit
import SceneKit
import SwiftUI

enum DJIModelAsset {
    static func url() -> URL? {
        if let bundled = Bundle.main.url(forResource: "DJI_IG830_high_fidelity", withExtension: "usdz") {
            return bundled
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            currentDirectory.appendingPathComponent("Resources/DJI_IG830_high_fidelity.usdz"),
            currentDirectory.appendingPathComponent("../Resources/DJI_IG830_high_fidelity.usdz")
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}

struct DJIModelView: NSViewRepresentable {
    let snapshot: DJI4GSnapshot

    func makeNSView(context: Context) -> DJIModelSceneView {
        let view = DJIModelSceneView(frame: .zero)
        view.loadModel(from: DJIModelAsset.url())
        view.apply(snapshot: snapshot)
        return view
    }

    func updateNSView(_ nsView: DJIModelSceneView, context: Context) {
        nsView.apply(snapshot: snapshot)
    }
}

@MainActor
final class DJIModelSceneView: SCNView {
    private let turntableNode = SCNNode()
    private let assetNode = SCNNode()
    private let cameraNode = SCNNode()
    private var lastDragLocation: CGPoint?
    private var resumeRotationWorkItem: DispatchWorkItem?
    // The physical status lens sits on the narrow edge below the DJI logo.
    // This framing keeps both in view before the idle turntable begins.
    private var pitch: CGFloat = -0.34
    private var yaw: CGFloat = -0.24
    private var cameraDistance: CGFloat = 104
    private var didLoadModel = false
    private var renderedIndicator: DJIStatusIndicator?

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        configureScene()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func layout() {
        super.layout()
        updateCameraDistance()
    }

    func loadModel(from url: URL?) {
        guard !didLoadModel else { return }
        didLoadModel = true

        guard let url, let imported = try? SCNScene(url: url, options: nil) else {
            installFallbackModel()
            return
        }

        if let hardwareRoot = imported.rootNode.childNode(withName: "DJI_IG830_ROOT", recursively: true) {
            hardwareRoot.removeFromParentNode()
            assetNode.addChildNode(hardwareRoot)
        } else {
            for child in imported.rootNode.childNodes {
                child.removeFromParentNode()
                assetNode.addChildNode(child)
            }
        }

        var removable: [SCNNode] = []
        assetNode.enumerateChildNodes { node, _ in
            node.removeAllAnimations()
            if node.camera != nil || node.light != nil || node.name == "Cube_012" {
                removable.append(node)
            }
        }
        removable.forEach { $0.removeFromParentNode() }
        normalizeImportedMaterials()
        if let hardwareRoot = assetNode.childNode(withName: "DJI_IG830_ROOT", recursively: true) {
            installSolidLogoI(on: hardwareRoot)
        }
        centerAsset()
        applyCurrentOrientation()
        resumeIdleRotation(after: 1.75)
    }

    func apply(snapshot: DJI4GSnapshot) {
        let indicator = snapshot.statusIndicator
        guard renderedIndicator != indicator else { return }
        renderedIndicator = indicator

        assetNode.enumerateChildNodes { node, _ in
            guard let name = node.name else { return }
            let isEmitterController = name.hasPrefix("Status_LED_") && name.hasSuffix("_Emitter")
            if isEmitterController {
                node.scale = matchesIndicator(indicator, nodeName: name)
                    ? SCNVector3(1, 1, 1)
                    : SCNVector3(0, 0, 0)
                return
            }
            let isIndicatorWindow = name.contains("Status_Indicator_Window")
            let isEmitter = name.contains("Status_LED_")
            guard isIndicatorWindow || isEmitter else { return }
            let isActive = matchesIndicator(indicator, nodeName: name)
            let shouldGlow = isActive || (isIndicatorWindow && indicator.color != .off)
            node.removeAction(forKey: "indicator-pulse")
            node.opacity = 1
            node.geometry?.materials.forEach { material in
                if isIndicatorWindow {
                    material.transparency = shouldGlow ? 0.68 : 0.88
                    material.emission.contents = shouldGlow ? indicatorColor(indicator.color) : NSColor.black
                    material.emission.intensity = shouldGlow ? 0.48 : 0
                } else {
                    material.transparency = isActive ? 1 : 0.025
                    material.emission.contents = isActive ? indicatorColor(indicator.color) : NSColor.black
                    material.emission.intensity = isActive ? 3.6 : 0
                    material.diffuse.contents = isActive ? indicatorColor(indicator.color) : NSColor.black
                }
            }

            if shouldGlow, indicator.behavior == .flashing {
                node.opacity = 0.12
                let pulse = SCNAction.sequence([
                    .fadeOpacity(to: 1, duration: 0.22),
                    .wait(duration: 0.28),
                    .fadeOpacity(to: 0.12, duration: 0.38),
                    .wait(duration: 0.24)
                ])
                node.runAction(.repeatForever(pulse), forKey: "indicator-pulse")
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pauseIdleRotation()
        if event.clickCount == 2 {
            pitch = -0.34
            yaw = -0.24
            cameraDistance = 104
            updateCameraDistance()
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.28
            applyCurrentOrientation()
            SCNTransaction.commit()
            resumeIdleRotation(after: 1.2)
            return
        }
        lastDragLocation = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let previous = lastDragLocation else {
            lastDragLocation = location
            return
        }
        yaw += (location.x - previous.x) * 0.008
        pitch = min(0.8, max(-0.8, pitch - (location.y - previous.y) * 0.006))
        lastDragLocation = location
        applyCurrentOrientation()
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        NSCursor.openHand.set()
        resumeIdleRotation(after: 1.2)
    }

    override func scrollWheel(with event: NSEvent) {
        cameraDistance = min(164, max(72, cameraDistance + event.scrollingDeltaY * 0.42))
        updateCameraDistance()
    }

    override func magnify(with event: NSEvent) {
        cameraDistance = min(164, max(72, cameraDistance * (1 - event.magnification)))
        updateCameraDistance()
    }

    private func configureScene() {
        let scene = SCNScene()
        self.scene = scene
        let stageColor = NSColor(genericGamma22White: 0.026, alpha: 1)
        backgroundColor = stageColor
        scene.background.contents = stageColor
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        rendersContinuously = true
        isPlaying = true
        allowsCameraControl = false
        autoenablesDefaultLighting = false

        scene.rootNode.addChildNode(turntableNode)
        turntableNode.addChildNode(assetNode)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.1
        camera.zFar = 500
        camera.wantsHDR = false
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        cameraNode.constraints = [SCNLookAtConstraint(target: turntableNode)]
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        updateCameraDistance()

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(genericGamma22White: 0.72, alpha: 1)
        ambient.intensity = 460
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let keyNode = SCNNode()
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1)
        key.intensity = 1_080
        key.castsShadow = true
        key.shadowRadius = 10
        key.shadowSampleCount = 16
        keyNode.light = key
        keyNode.position = SCNVector3(34, 30, 48)
        keyNode.constraints = [SCNLookAtConstraint(target: turntableNode)]
        scene.rootNode.addChildNode(keyNode)

        let fillNode = SCNNode()
        let fill = SCNLight()
        fill.type = .omni
        fill.color = NSColor(srgbRed: 0.84, green: 0.85, blue: 0.88, alpha: 1)
        fill.intensity = 680
        fill.attenuationStartDistance = 18
        fill.attenuationEndDistance = 150
        fillNode.light = fill
        fillNode.position = SCNVector3(-36, 8, 38)
        scene.rootNode.addChildNode(fillNode)

        let rimNode = SCNNode()
        let rim = SCNLight()
        rim.type = .omni
        rim.color = NSColor(srgbRed: 0.76, green: 0.78, blue: 0.82, alpha: 1)
        rim.intensity = 760
        rim.attenuationStartDistance = 18
        rim.attenuationEndDistance = 140
        rimNode.light = rim
        rimNode.position = SCNVector3(-34, 18, -34)
        scene.rootNode.addChildNode(rimNode)
    }

    private func normalizeImportedMaterials() {
        assetNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            if isDJILogoCurve(node) {
                // The source logo planes are coplanar with the housing. Lift the
                // original curves slightly so the final "i" does not z-fight.
                node.position.z += 0.025
                node.renderingOrder = 8
            }
            geometry.materials = geometry.materials.map { source in
                let material = (source.copy() as? SCNMaterial) ?? source
                configureImportedMaterial(material, on: node)
                return material
            }
        }
    }

    private func configureImportedMaterial(_ material: SCNMaterial, on node: SCNNode) {
        let name = (material.name ?? "").lowercased()
        material.lightingModel = .physicallyBased

        if name.contains("status_led_") {
            material.diffuse.contents = NSColor.black
            material.emission.contents = NSColor.black
            material.emission.intensity = 0
            return
        }

        switch name {
        case let value where value.contains("one_piece_cast_matte_housing"):
            setMaterial(material, color: rgb(0.125, 0.132, 0.145), roughness: 0.80, metalness: 0.02)
        case let value where value.contains("bottom_laser_engraving_field"):
            setMaterial(material, color: rgb(0.090, 0.096, 0.106), roughness: 0.70, metalness: 0.04)
        case let value where value.contains("dji_logo_silver_gray"):
            setMaterial(material, color: rgb(0.78, 0.80, 0.83), roughness: 0.34, metalness: 0.24)
        case let value where value.contains("curve-material") && isDJILogoCurve(node):
            material.lightingModel = .constant
            material.diffuse.contents = rgb(0.86, 0.88, 0.92)
            material.multiply.contents = NSColor.white
            material.emission.contents = rgb(0.72, 0.75, 0.80)
            material.emission.intensity = 0.26
            material.isDoubleSided = true
        case let value where value.contains("pantone_cool_gray_6c"):
            setMaterial(material, color: rgb(0.38, 0.39, 0.41), roughness: 0.66, metalness: 0.04)
        case let value where value.contains("matte_black_engineering_polymer"):
            setMaterial(material, color: rgb(0.026, 0.029, 0.034), roughness: 0.76, metalness: 0.01)
        case let value where value.contains("fine_grain_matte_edge_polymer"):
            setMaterial(material, color: rgb(0.034, 0.038, 0.044), roughness: 0.72, metalness: 0.01)
        case let value where value.contains("black_oxide_screw"):
            setMaterial(material, color: rgb(0.018, 0.019, 0.022), roughness: 0.43, metalness: 0.48)
        case let value where value.contains("port_cavity_black"):
            setMaterial(material, color: rgb(0.004, 0.005, 0.006), roughness: 0.84, metalness: 0.01)
        case let value where value.contains("usb_connector_dark_nickel"):
            setMaterial(material, color: rgb(0.075, 0.080, 0.088), roughness: 0.31, metalness: 0.68)
        case let value where value.contains("ts_5_gold_plated_contact"):
            setMaterial(material, color: rgb(0.58, 0.34, 0.08), roughness: 0.24, metalness: 0.9)
        case let value where value.contains("smoked_status_indicator_window"):
            setMaterial(material, color: rgb(0.012, 0.016, 0.022), roughness: 0.22, metalness: 0.03)
            material.transparency = 0.88
        default:
            break
        }
    }

    private func setMaterial(
        _ material: SCNMaterial,
        color: NSColor,
        roughness: CGFloat,
        metalness: CGFloat
    ) {
        material.diffuse.contents = color
        material.multiply.contents = NSColor.white
        material.roughness.contents = NSNumber(value: Double(roughness))
        material.metalness.contents = NSNumber(value: Double(metalness))
        material.emission.contents = NSColor.black
        material.emission.intensity = 0
    }

    private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private func isDJILogoCurve(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let item = current {
            if item.name?.hasPrefix("DJI_Logo_Curve") == true {
                return true
            }
            current = item.parent
        }
        return false
    }

    private func matchesIndicator(_ indicator: DJIStatusIndicator, nodeName: String) -> Bool {
        switch indicator.color {
        case .green: return nodeName.contains("GREEN")
        case .blue: return nodeName.contains("BLUE")
        case .red: return nodeName.contains("RED")
        case .off: return false
        }
    }

    private func indicatorColor(_ color: DJIStatusIndicatorColor) -> NSColor {
        switch color {
        case .green: return NSColor(srgbRed: 0.18, green: 0.95, blue: 0.38, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.18, green: 0.56, blue: 1, alpha: 1)
        case .red: return NSColor(srgbRed: 1, green: 0.20, blue: 0.20, alpha: 1)
        case .off: return .black
        }
    }

    private func centerAsset() {
        let bounds = assetNode.boundingBox
        let center = SCNVector3(
            (bounds.min.x + bounds.max.x) / 2,
            (bounds.min.y + bounds.max.y) / 2,
            (bounds.min.z + bounds.max.z) / 2
        )
        assetNode.position = SCNVector3(-center.x, -center.y, -center.z)
    }

    private func installSolidLogoI(on hardwareRoot: SCNNode) {
        guard hardwareRoot.childNode(withName: "DJI_Logo_I_Solid", recursively: false) == nil else { return }

        // SceneKit imports the USD BasisCurves glyph as a hollow stroke. These
        // are the four corner anchors from Curve_002, transformed into the
        // hardware root's coordinate space so the original DJI proportions stay intact.
        hardwareRoot.childNode(withName: "DJI_Logo_Curve_002", recursively: false)?.isHidden = true
        let sourceScale: CGFloat = 0.17203984
        let sourceOrigin = SCNVector3(-4.0007362, -2.3110752, 4.055)
        let sourceCorners: [(CGFloat, CGFloat)] = [
            (39.14205, 21.603928),
            (35.574142, 6.4429674),
            (42.93833, 6.4429674),
            (46.50514, 21.603928)
        ]
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(sourceCorners.count)
        for (sourceX, sourceY) in sourceCorners {
            let x = sourceOrigin.x + sourceX * sourceScale
            let y = sourceOrigin.y + sourceY * sourceScale
            vertices.append(SCNVector3(x, y, sourceOrigin.z))
        }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(
            indices: [Int32(0), 1, 2, 0, 2, 3],
            primitiveType: .triangles
        )
        let glyph = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = rgb(0.86, 0.88, 0.92)
        material.emission.contents = rgb(0.72, 0.75, 0.80)
        material.emission.intensity = 0.26
        material.isDoubleSided = true
        glyph.materials = [material]

        let glyphNode = SCNNode(geometry: glyph)
        glyphNode.name = "DJI_Logo_I_Solid"
        glyphNode.renderingOrder = 9
        hardwareRoot.addChildNode(glyphNode)
    }

    private func installFallbackModel() {
        let body = SCNBox(width: 52.4, height: 23, length: 8, chamferRadius: 3)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = rgb(0.125, 0.132, 0.145)
        material.roughness.contents = 0.72
        material.metalness.contents = 0.04
        body.materials = [material]
        assetNode.geometry = body
        applyCurrentOrientation()
        resumeIdleRotation(after: 1.75)
    }

    private func pauseIdleRotation() {
        resumeRotationWorkItem?.cancel()
        resumeRotationWorkItem = nil
        let currentOrientation = turntableNode.presentation.simdOrientation
        turntableNode.removeAction(forKey: "idle-rotation")
        turntableNode.simdOrientation = currentOrientation
        pitch = turntableNode.eulerAngles.x
        yaw = turntableNode.eulerAngles.y
    }

    private func resumeIdleRotation(after delay: TimeInterval) {
        resumeRotationWorkItem?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let centerYaw = self.turntableNode.presentation.eulerAngles.y
            self.turntableNode.eulerAngles = self.turntableNode.presentation.eulerAngles
            let right = SCNAction.rotateTo(
                x: self.pitch,
                y: centerYaw + 0.30,
                z: 0,
                duration: 7.5,
                usesShortestUnitArc: true
            )
            let left = SCNAction.rotateTo(
                x: self.pitch,
                y: centerYaw - 0.30,
                z: 0,
                duration: 15,
                usesShortestUnitArc: true
            )
            let settle = SCNAction.rotateTo(
                x: self.pitch,
                y: centerYaw,
                z: 0,
                duration: 7.5,
                usesShortestUnitArc: true
            )
            for action in [right, left, settle] {
                action.timingMode = .easeInEaseOut
            }
            self.turntableNode.runAction(.repeatForever(.sequence([right, left, settle])), forKey: "idle-rotation")
        }
        resumeRotationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func applyCurrentOrientation() {
        turntableNode.eulerAngles = SCNVector3(pitch, yaw, 0)
    }

    private func updateCameraDistance() {
        let height = max(bounds.height, 1)
        let aspectRatio = max(bounds.width / height, 0.2)
        let verticalFieldOfView = CGFloat.pi * 38 / 180
        let horizontalFieldOfView = 2 * atan(tan(verticalFieldOfView / 2) * aspectRatio)
        let limitingFieldOfView = min(verticalFieldOfView, horizontalFieldOfView)
        let fitDistance = 30.5 / max(sin(limitingFieldOfView / 2), 0.1)
        cameraNode.position = SCNVector3(0, 0, max(cameraDistance, fitDistance))
    }
}
