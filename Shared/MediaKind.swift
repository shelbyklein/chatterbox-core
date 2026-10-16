import Foundation

/// Files that play rather than sit still: GIFs, videos, Lottie animations, and 3D models you
/// can turn. Shared with the iPhone app.
enum MediaKind: Equatable {
    case animatedImage
    case video
    /// A Lottie animation as JSON (Bodymovin), or as a .lottie (dotLottie) archive.
    case lottie
    case dotLottie
    /// GLB, glTF, STL, OBJ or FBX, shown in a web page with three.js.
    case model3D
    /// USDZ, shown natively (SceneKit).
    case usdz

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let modelExtensions: Set<String> = ["glb", "gltf", "stl", "obj", "fbx"]
    /// Larger models get an Open button instead of a preview (the page holds the whole file).
    static let modelPreviewLimit = 80 * 1024 * 1024
    /// Pictures that sit still (screenshots, renders, proofs), shown under a reply that names them.
    static let stillImageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff", "bmp"]

    static func isStillImage(_ name: String) -> Bool { stillImageExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// What a file is, by its name (and, for .json, a look inside to tell Lottie from data).
    static func of(name: String, contents: () -> Data?) -> MediaKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "gif" { return .animatedImage }
        if videoExtensions.contains(ext) { return .video }
        if ext == "lottie" { return .dotLottie }
        if modelExtensions.contains(ext) { return .model3D }
        if ext == "usdz" { return .usdz }
        if ext == "json", let data = contents(), isLottie(data) { return .lottie }
        return nil
    }

    static func of(_ url: URL) -> MediaKind? {
        of(name: url.lastPathComponent) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4096)
        }
    }

    /// Lottie JSON starts with its version, frame rate, size, and layers.
    static func isLottie(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        return head.contains("\"layers\"") || (head.contains("\"fr\"") && head.contains("\"ip\"") && head.contains("\"op\""))
    }

    /// A page that plays a Lottie animation, looping, centered on white. Lottie's player
    /// loads from a CDN.
    static func lottiePage(json: String) -> String {
        // The animation's own shape (its w and h), as large as fits up to 360 points tall.
        var aspect = "16 / 9"
        if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let w = object["w"] as? Double, let h = object["h"] as? Double, w > 0, h > 0 {
            aspect = "\(w) / \(h)"
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:#fff}#a{aspect-ratio:\(aspect);max-height:360px;margin:0 auto}</style>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js"></script>
        </head><body><div id="a"></div><script>
        lottie.loadAnimation({container: document.getElementById('a'), renderer: 'svg', loop: true, autoplay: true,
          animationData: \(json)});
        </script></body></html>
        """
    }

    /// A .gltf with the files it points to (its .bin buffers and textures, beside it) folded in
    /// as data, so a page can show it on its own. Other files come back as they are.
    static func selfContainedModel(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard url.pathExtension.lowercased() == "gltf",
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        let folder = url.deletingLastPathComponent()
        func inline(_ key: String, type: (String) -> String) {
            guard var entries = json[key] as? [[String: Any]] else { return }
            for i in entries.indices {
                guard let uri = entries[i]["uri"] as? String, !uri.hasPrefix("data:"),
                      let path = uri.removingPercentEncoding,
                      let bytes = try? Data(contentsOf: folder.appendingPathComponent(path)) else { continue }
                entries[i]["uri"] = "data:\(type(path));base64," + bytes.base64EncodedString()
            }
            json[key] = entries
        }
        inline("buffers") { _ in "application/octet-stream" }
        inline("images") { path in
            switch (path as NSString).pathExtension.lowercased() {
            case "png": "image/png"
            case "webp": "image/webp"
            case "ktx2": "image/ktx2"
            default: "image/jpeg"
            }
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }

    /// A page that shows a 3D model to turn (drag), zoom (scroll or pinch) and pan, lit and
    /// framed to fit, turning slowly until touched. three.js loads from a CDN. A .gltf must
    /// hold its own buffers and textures (one that points to other files shows without them).
    static func modelPage(base64: String, ext: String, dark: Bool) -> String {
        let loader: String
        switch ext.lowercased() {
        case "stl": loader = "const g = new STLLoader().parse(buf); g.computeVertexNormals(); return new THREE.Mesh(g, new THREE.MeshStandardMaterial({color: 0xb8bcc4, roughness: 0.55, metalness: 0.1}));"
        case "obj": loader = "const o = new OBJLoader().parse(new TextDecoder().decode(buf)); o.traverse(c => { if (c.isMesh && (!c.material || !c.material.map)) c.material = new THREE.MeshStandardMaterial({color: 0xb8bcc4, roughness: 0.55}); }); return o;"
        case "fbx": loader = "return new FBXLoader().parse(buf, '');"
        default: loader = "return await new Promise((ok, no) => new GLTFLoader().parse(buf, '', g => { mixer = g.animations.length ? new THREE.AnimationMixer(g.scene) : null; if (mixer) g.animations.forEach(a => mixer.clipAction(a).play()); ok(g.scene); }, no));"
        }
        let background = dark ? "#1c1c1e" : "#f2f2f7"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:\(background);height:360px;overflow:hidden}canvas{display:block;touch-action:none}
        #m{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font:13px -apple-system;color:#8e8e93}</style>
        <script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/"}}</script>
        </head><body><div id="m">Loading model…</div><script type="module">
        import * as THREE from 'three';
        import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
        import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
        import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
        import { STLLoader } from 'three/addons/loaders/STLLoader.js';
        import { OBJLoader } from 'three/addons/loaders/OBJLoader.js';
        import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
        let mixer = null;
        const buf = Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0)).buffer;
        const renderer = new THREE.WebGLRenderer({antialias: true, alpha: true});
        // A phone's web view has little graphics memory: at most 2x, and the page's width (it
        // can be 0 before the view is laid out).
        const width = () => Math.max(innerWidth, 100);
        renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2)); renderer.setSize(width(), 360);
        renderer.outputColorSpace = THREE.SRGBColorSpace; renderer.toneMapping = THREE.ACESFilmicToneMapping;
        document.body.appendChild(renderer.domElement);
        const scene = new THREE.Scene();
        // Reflections from a lit room, where there's memory for them; plain lights otherwise.
        try { scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture; } catch (e) {}
        scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 1.2));
        const sun = new THREE.DirectionalLight(0xffffff, 1.5); sun.position.set(3, 5, 4); scene.add(sun);
        const camera = new THREE.PerspectiveCamera(40, width() / 360, 0.001, 10000);
        const controls = new OrbitControls(camera, renderer.domElement);
        controls.enableDamping = true; controls.autoRotate = true; controls.autoRotateSpeed = 1.2;
        controls.addEventListener('start', () => { controls.autoRotate = false; });
        try {
          const model = await (async () => { \(loader) })();
          scene.add(model);
          const box = new THREE.Box3().setFromObject(model), size = box.getSize(new THREE.Vector3()), center = box.getCenter(new THREE.Vector3());
          const radius = Math.max(size.length() / 2, 1e-4);
          controls.target.copy(center);
          camera.position.copy(center).add(new THREE.Vector3(0.9, 0.55, 1.4).normalize().multiplyScalar(radius / Math.sin(THREE.MathUtils.degToRad(20)) * 1.05));
          camera.near = radius / 100; camera.far = radius * 100; camera.updateProjectionMatrix();
          document.getElementById('m').remove();
        } catch (e) { const m = document.getElementById('m'); m.style.cssText += ';white-space:pre-wrap;font-size:10px;padding:12px;text-align:left'; m.textContent = "Couldn't show this model: " + (e && e.message || e) + "\\nbytes " + buf.byteLength + " webgl2 " + !!renderer.capabilities.isWebGL2 + "\\n" + (e && e.stack || '').replace(/https:\\/\\/cdn.jsdelivr.net\\/npm\\/three@0.170.0\\//g, ''); }
        const clock = new THREE.Clock();
        addEventListener('resize', () => { renderer.setSize(width(), 360); camera.aspect = width() / 360; camera.updateProjectionMatrix(); });
        renderer.setAnimationLoop(() => { if (mixer) mixer.update(clock.getDelta()); controls.update(); renderer.render(scene, camera); });
        </script></body></html>
        """
    }

    /// The same for a .lottie archive, with the dotLottie player.
    static func dotLottiePage(base64: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:#fff}canvas{width:100%;aspect-ratio:1;max-height:360px;display:block;margin:0 auto;object-fit:contain}</style>
        </head><body><canvas id="c"></canvas><script type="module">
        import { DotLottie } from 'https://cdn.jsdelivr.net/npm/@lottiefiles/dotlottie-web/+esm';
        const bytes = Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0));
        new DotLottie({ canvas: document.getElementById('c'), data: bytes.buffer, loop: true, autoplay: true });
        </script></body></html>
        """
    }
}
