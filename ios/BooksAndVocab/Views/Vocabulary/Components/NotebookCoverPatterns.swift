import SwiftUI
import CryptoKit

struct NotebookCoverAsset: Equatable {
    let path: String
    let sha256: String
    let byteSize: Int

    var hasValidMetadata: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && byteSize > 0
            && sha256.count == 64
            && sha256.allSatisfy { $0.isHexDigit }
    }

    var accessibilityValue: String {
        "sha256:\(sha256); bytes:\(byteSize); path:\(path)"
    }
}

enum NotebookCoverSource: Equatable {
    case procedural
    /// Existing user-local notebook/podcast cover behavior. A missing local
    /// file may still use the caller's procedural pattern.
    case localFile(path: String)
    /// Canonical UI World / installed asset. Any provenance or decode failure
    /// is fail-closed and must never use the procedural pattern.
    case canonicalAsset(NotebookCoverAsset)
    case invalidCanonicalAsset

    static func shouldRenderProceduralPattern(
        for source: NotebookCoverSource,
        imageLoaded: Bool
    ) -> Bool {
        switch source {
        case .procedural:
            return true
        case .localFile:
            return !imageLoaded
        case .canonicalAsset, .invalidCanonicalAsset:
            return false
        }
    }
}

enum NotebookCoverImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func image(
        path: String,
        displaySize: CGSize,
        scale: CGFloat,
        loadData: (String) -> Data? = { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) -> UIImage? {
        // 持久化的 localFile 值（檔名或舊版絕對路徑）先解析成目前 container 內的檔案（#3676）。
        image(
            path: NotebookCoverStore.resolvePath(path) ?? path,
            displaySize: displaySize,
            scale: scale,
            cacheDiscriminator: nil,
            loadData: loadData
        )
    }

    static func image(
        for asset: NotebookCoverAsset,
        displaySize: CGSize,
        scale: CGFloat,
        loadData: (String) -> Data? = { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }
    ) -> UIImage? {
        guard asset.hasValidMetadata else { return nil }
        return image(
            path: asset.path,
            displaySize: displaySize,
            scale: scale,
            cacheDiscriminator: "sha256:\(asset.sha256);bytes:\(asset.byteSize);file:\(fileSignature(path: asset.path))",
            loadData: { path in
                guard let data = loadData(path),
                      data.count == asset.byteSize,
                      sha256Hex(for: data) == asset.sha256 else {
                    return nil
                }
                return data
            }
        )
    }

    private static func image(
        path: String,
        displaySize: CGSize,
        scale: CGFloat,
        cacheDiscriminator: String?,
        loadData: (String) -> Data?
    ) -> UIImage? {
        let maxDimensionPoints = max(displaySize.width, displaySize.height)
        guard maxDimensionPoints.isFinite, maxDimensionPoints > 0, scale.isFinite, scale > 0 else {
            return nil
        }
        let pixelBound = max(1, Int((maxDimensionPoints * scale).rounded(.up)))
        let identity = cacheDiscriminator ?? fileSignature(path: path)
        let key = "\(path)#\(pixelBound)#\(identity)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = loadData(path),
              let image = CoverImageDownsampler.downsample(
                data: data,
                maxDimensionPoints: maxDimensionPoints,
                scale: scale
              ) ?? UIImage(data: data) else {
            return nil
        }
        let pixels = Int((image.size.width * image.scale * image.size.height * image.scale).rounded(.up))
        cache.setObject(image, forKey: key, cost: max(1, pixels * 4))
        return image
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func removeAll() {
        cache.removeAllObjects()
    }

    private static func fileSignature(path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(mtime)"
    }
}

enum NotebookCoverPattern: String, CaseIterable, Identifiable {
    case dots
    case lines
    case grid
    case waves
    case circles
    case noise

    var id: String { rawValue }

    var label: String {
        localizedLabel(language: AppLanguageStore.shared.selection)
    }

    func localizedLabel(language: AppLanguage) -> String {
        switch self {
        case .dots: return L10n.string("圓點", language: language)
        case .lines: return L10n.string("條紋", language: language)
        case .grid: return L10n.string("格線", language: language)
        case .waves: return L10n.string("波浪", language: language)
        case .circles: return L10n.string("同心圓", language: language)
        case .noise: return L10n.string("噪點", language: language)
        }
    }

    @ViewBuilder
    func patternOverlay(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            switch self {
            case .dots:
                let spacing: CGFloat = 16
                let radius: CGFloat = 2.5
                var y: CGFloat = spacing / 2
                while y < h {
                    var x: CGFloat = spacing / 2
                    while x < w {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(.white.opacity(NotebookStackMetrics.patternOpacity))
                        )
                        x += spacing
                    }
                    y += spacing
                }
            case .lines:
                let spacing: CGFloat = 12
                let lineWidth: CGFloat = 1.5
                var offset: CGFloat = -h
                while offset < w + h {
                    var path = Path()
                    path.move(to: CGPoint(x: offset, y: 0))
                    path.addLine(to: CGPoint(x: offset - h, y: h))
                    context.stroke(path, with: .color(.white.opacity(NotebookStackMetrics.patternOpacity)), lineWidth: lineWidth)
                    offset += spacing
                }
            case .grid:
                let spacing: CGFloat = 20
                let lineWidth: CGFloat = 0.8
                var x: CGFloat = 0
                while x <= w {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    context.stroke(path, with: .color(.white.opacity(NotebookStackMetrics.patternOpacity)), lineWidth: lineWidth)
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= h {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                    context.stroke(path, with: .color(.white.opacity(NotebookStackMetrics.patternOpacity)), lineWidth: lineWidth)
                    y += spacing
                }
            case .waves:
                let amplitude: CGFloat = 8
                let wavelength: CGFloat = 30
                let spacing: CGFloat = 20
                var yOffset: CGFloat = spacing / 2
                while yOffset < h + amplitude {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: yOffset))
                    var x: CGFloat = 0
                    while x <= w {
                        let y = yOffset + amplitude * sin(x / wavelength * .pi * 2)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 2
                    }
                    context.stroke(path, with: .color(.white.opacity(NotebookStackMetrics.patternOpacity)), lineWidth: 1.2)
                    yOffset += spacing
                }
            case .circles:
                let centerX = w / 2
                let centerY = h / 2
                let maxRadius = max(w, h) / 2
                var r: CGFloat = 15
                while r < maxRadius {
                    let rect = CGRect(x: centerX - r, y: centerY - r, width: r * 2, height: r * 2)
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(NotebookStackMetrics.patternOpacity)),
                        lineWidth: 1.0
                    )
                    r += 15
                }
            case .noise:
                let step: CGFloat = 4
                var y: CGFloat = 0
                var seed: UInt64 = 42
                while y < h {
                    var x: CGFloat = 0
                    while x < w {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        let val = Double((seed >> 33) & 0xFF) / 255.0
                        if val > 0.6 {
                            // noise pattern 維持動態 opacity (per-pixel rand-driven, max ≈ 0.15)。
                            // **不**統一 patternOpacity token — noise 的視覺特色就是 per-pixel
                            // 隨機變化,夾平會變一坨灰塊。Task 7 review 確認 noise 結構上
                            // 必然 < 0.18 = 既有 token,顯式豁免。
                            let opacity = (val - 0.6) * 0.375
                            context.fill(
                                Path(CGRect(x: x, y: y, width: step, height: step)),
                                with: .color(.white.opacity(opacity))
                            )
                        }
                        x += step
                    }
                    y += step
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct NotebookCoverView: View {
    @ObserveInjection private var inject
    @Environment(\.displayScale) private var displayScale
    let color: Color
    let pattern: NotebookCoverPattern?
    let source: NotebookCoverSource
    let name: String
    /// 是否在 cover 中央渲染白色 name text。預設 true 保留既有行為(Bookshelf / Podcast /
    /// EditSheet preview / #Preview 等 5 處 callsite zero-touch);NotebookCard 在
    /// 套 editorial overlay 時傳 false,避免雙層 name 疊字。
    var showsName: Bool = true
    var assetAccessibilityIdentifier: String? = nil
    var assetAccessibilityLabel: String? = nil
    var assetAccessibilityValue: String? = nil

    init(
        color: Color,
        pattern: NotebookCoverPattern?,
        coverImagePath: String?,
        name: String,
        showsName: Bool = true
    ) {
        self.init(
            color: color,
            pattern: pattern,
            source: coverImagePath.map(NotebookCoverSource.localFile) ?? .procedural,
            name: name,
            showsName: showsName
        )
    }

    init(
        color: Color,
        pattern: NotebookCoverPattern?,
        source: NotebookCoverSource,
        name: String,
        showsName: Bool = true,
        assetAccessibilityIdentifier: String? = nil,
        assetAccessibilityLabel: String? = nil,
        assetAccessibilityValue: String? = nil
    ) {
        self.color = color
        self.pattern = pattern
        self.source = source
        self.name = name
        self.showsName = showsName
        self.assetAccessibilityIdentifier = assetAccessibilityIdentifier
        self.assetAccessibilityLabel = assetAccessibilityLabel
        self.assetAccessibilityValue = assetAccessibilityValue
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                color

                switch source {
                case .canonicalAsset(let asset):
                    let coverImage = loadImage(for: asset, displaySize: geo.size)
                    if let coverImage {
                        imageLayer(coverImage, size: geo.size)
                    } else if NotebookCoverSource.shouldRenderProceduralPattern(for: source, imageLoaded: false),
                              let pattern {
                        pattern.patternOverlay(size: geo.size)
                    }
                case .localFile(let path):
                    let coverImage = loadImage(from: path, displaySize: geo.size)
                    if let coverImage {
                        imageLayer(coverImage, size: geo.size)
                    } else if NotebookCoverSource.shouldRenderProceduralPattern(for: source, imageLoaded: false),
                              let pattern {
                        pattern.patternOverlay(size: geo.size)
                    }
                case .procedural:
                    if NotebookCoverSource.shouldRenderProceduralPattern(for: source, imageLoaded: false),
                       let pattern {
                        pattern.patternOverlay(size: geo.size)
                    }
                case .invalidCanonicalAsset:
                    EmptyView()
                }

                if showsName {
                    Text(name)
                        .font(AppFonts.body(weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1) // token-allow: cover text legibility shadow, not UI elevation
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.s2)
                }
            }
        }
        .enableInjection()
    }

    private func loadImage(from path: String, displaySize: CGSize) -> UIImage? {
        NotebookCoverImageCache.image(path: path, displaySize: displaySize, scale: displayScale)
    }

    private func loadImage(for asset: NotebookCoverAsset, displaySize: CGSize) -> UIImage? {
        NotebookCoverImageCache.image(for: asset, displaySize: displaySize, scale: displayScale)
    }

    @ViewBuilder
    private func imageLayer(_ image: UIImage, size: CGSize) -> some View {
        let imageView = platformImage(image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
#if DEBUG && targetEnvironment(simulator)
        if let identifier = assetAccessibilityIdentifier {
            imageView
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(assetAccessibilityLabel ?? name)
                .accessibilityValue(assetAccessibilityValue ?? "")
        } else {
            imageView
        }
#else
        imageView
#endif
    }

    private func platformImage(_ image: UIImage) -> Image {
        Image(uiImage: image)
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: AppSpacing.s3) {
        ForEach(NotebookCoverPattern.allCases) { pattern in
            NotebookCoverView(
                color: Color(hex: "#4A90D9") ?? .blue, // token-allow: preview fixture notebook data color
                pattern: pattern,
                coverImagePath: nil,
                name: pattern.label
            )
            .frame(height: 80)
            .clipShape(AppRoundedRect(roundness: AppRoundness.card))
        }
    }
    .padding()
}
