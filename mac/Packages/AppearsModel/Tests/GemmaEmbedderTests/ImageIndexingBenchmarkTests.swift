import CoreGraphics
import Darwin
import EmbeddingGemma2
import Foundation
import Testing
@testable import AppearsCore
@testable import GemmaEmbedder

// Real-model measurements on demo images: the integrated indexer and the original
// stage-timing prototype. Neither opens the user's index or Messages database.
extension GemmaEmbedderTests {
    @Test(.timeLimit(.minutes(3))) func imageIndexerBenchmark() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task.detached(priority: .medium) {
                do { try await self.measureIndexer(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func measureIndexer() async throws {
        var root = URL(filePath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appending(path: "demo/files").path) {
            root.deleteLastPathComponent()
        }
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "demo/files"), includingPropertiesForKeys: nil))
        let urls = files.compactMap { $0 as? URL }.filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        #expect(urls.count == 18)
        let model = try await GemmaEmbedder.load(from: ModelFolder.url)
        // Keep the towers warm between modes; production normally unloads after a run.
        // Both modes still use the production shared scheduler for every forward.
        let embedder = ScheduledEmbedder(WarmBenchmarkEmbedder(base: model))
        _ = try await embedder.embed(queries: ["Synthetic warmup"])
        let first = try #require(urls.first)
        let image = try #require(Extractor.loadImage(first))
        _ = try await embedder.embed(images: [image])
        // Warm accurate OCR and every image/text shape before comparing steady runs.
        // The first full pass can include substantial Vision/Metal initialization.
        _ = try await runIndexer(urls, embedder: embedder, prefetch: false)
        let serial = try await runIndexer(urls, embedder: embedder, prefetch: false)
        for (name, prefetch) in [("prefetch_1", true), ("prefetch_2", true), ("serial_2", false)] {
            let run = try await runIndexer(urls, embedder: embedder, prefetch: prefetch)
            #expect(run.units.map(\.unit) == serial.units.map(\.unit))
            for (actual, reference) in zip(run.units, serial.units) {
                #expect(cosine(actual.vector, reference.vector) > 0.99999)
            }
            print("IMAGE_INDEXER \(name) total=\(run.elapsed) footprint_before=\(run.before) footprint_sampled_peak=\(run.peak)")
        }
        print("IMAGE_INDEXER serial_1 total=\(serial.elapsed) footprint_before=\(serial.before) footprint_sampled_peak=\(serial.peak) images=\(urls.count) priority=\(Task.currentPriority.rawValue) image_tokens=\(model.imageTokens)")
        await model.unloadVision()
    }

    private struct IndexerResult {
        let elapsed: Double
        let before: UInt64
        let peak: UInt64
        let units: [(unit: AppearsCore.Unit, vector: [Float])]
    }

    private func runIndexer(_ urls: [URL], embedder: ScheduledEmbedder, prefetch: Bool) async throws -> IndexerResult {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-indexer-bench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let vectors = VectorIndex(dimension: embedder.dimension)
        let items = try urls.enumerated().map { index, url in
            var item = Item(source: .file, path: url.path, kind: .image, title: url.lastPathComponent,
                            size: 1, created: .distantPast, modified: Date(timeIntervalSince1970: Double(100 - index)), lastUsed: nil)
            item.id = try store.record(item, signature: "synthetic").id
            return item
        }
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: SourceSettings(notes: false, messages: false))
        await indexer.setPoliteness(false)
        let before = footprint()
        let sampler = Task.detached(priority: .medium) {
            var peak = before
            while !Task.isCancelled {
                peak = max(peak, self.footprint())
                try? await Task.sleep(for: .milliseconds(5))
            }
            return peak
        }
        defer { sampler.cancel() }
        let started = ContinuousClock.now
        if prefetch { #expect(try await indexer.indexPending() == items.count) }
        else { for item in items { try await indexer.index(item) } }
        let elapsed = seconds(started)
        sampler.cancel()
        let peak = await sampler.value
        #expect(try store.counts().waiting == 0)
        return IndexerResult(elapsed: elapsed, before: before, peak: peak,
                             units: try items.flatMap { try store.units(itemID: $0.id) })
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test(.timeLimit(.minutes(3))) func imageIndexingBenchmark() async throws {
        // Awaiting Task.value would donate the test runner's user-initiated priority.
        // A continuation lets the measured work keep the engine's medium priority.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task.detached(priority: .medium) {
                do { try await self.measureImages(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func measureImages() async throws {
        var root = URL(filePath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appending(path: "demo/files").path) {
            root.deleteLastPathComponent()
        }
        let demo = root.appending(path: "demo/files")
        let enumerator = try #require(FileManager.default.enumerator(at: demo, includingPropertiesForKeys: nil))
        let images = enumerator.compactMap { $0 as? URL }
            .filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        #expect(!images.isEmpty)
        let embedder = try await GemmaEmbedder.load(from: ModelFolder.url)
        // Warm both towers and OCR; cold initialization is reported separately.
        let cold = ContinuousClock.now
        let warm = try await prepare(try #require(images.first), imageTokens: embedder.imageTokens)
        _ = try await embedder.embed(documents: warm.documents)
        _ = try await embedder.embed(images: [warm.image])
        print("IMAGE_BENCH cold_warmup_seconds=\(seconds(cold)) images=\(images.count) image_tokens=\(embedder.imageTokens) priority=\(Task.currentPriority.rawValue)")
        let tokenStarted = ContinuousClock.now
        let expectedIDs = try await embedder.encoder.imageTokenIDs(softTokenCount: warm.pixels.softTokenCount)
        for _ in 0..<100 {
            #expect(try await embedder.encoder.imageTokenIDs(softTokenCount: warm.pixels.softTokenCount) == expectedIDs)
        }
        print("IMAGE_BENCH image_tokenizer_ms_per_image=\(seconds(tokenStarted) * 1000 / 101)")

        let serial = try await run(images, embedder: embedder, prefetch: false)
        let pipeline = try await run(images, embedder: embedder, prefetch: true)
        // Reverse order once to distinguish the overlap from warm-cache/order effects.
        let pipelineAgain = try await run(images, embedder: embedder, prefetch: true)
        let serialAgain = try await run(images, embedder: embedder, prefetch: false)
        for (name, result) in [("serial_1", serial), ("prefetch_1", pipeline), ("prefetch_2", pipelineAgain), ("serial_2", serialAgain)] {
            print("IMAGE_BENCH \(name) total=\(result.total) decode=\(result.decode) ocr=\(result.ocr) image_prepare=\(result.imagePrepare) text_model=\(result.textModel) image_model=\(result.imageModel) write=\(result.write)")
            #expect(result.vectors.count == serial.vectors.count)
            for (vector, reference) in zip(result.vectors, serial.vectors) { #expect(cosine(vector, reference) > 0.99999) }
        }
        print("IMAGE_BENCH peak_memory_bytes=\(embedder.peakMemory)")
        await embedder.unloadVision()
    }

    private struct Prepared: Sendable {
        let image: CGImage
        let pixels: PreparedImage
        let documents: [EmbeddingDocument]
        let texts: [String]
        let decode: Double
        let ocr: Double
        let imagePrepare: Double
    }

    private struct Result {
        var total = 0.0, decode = 0.0, ocr = 0.0, imagePrepare = 0.0
        var textModel = 0.0, imageModel = 0.0, write = 0.0
        var vectors: [[Float]] = []
    }

    private func prepare(_ url: URL, imageTokens: Int) async throws -> Prepared {
        let decodeStarted = ContinuousClock.now
        let image = try #require(Extractor.loadImage(url))
        let decode = seconds(decodeStarted)
        let ocrStarted = ContinuousClock.now
        let text = await Extractor.recognizeText(in: image)
        let ocr = seconds(ocrStarted)
        // Match the current image/OCR thresholds and add a made-up nearby conversation,
        // as MessagesReader.extraction does for a photo sent within a conversation.
        var texts: [String] = text.count >= 80 ? [String(text.prefix(Extractor.chunkCharacters * 2))] : []
        texts.append("Me: Can you send the kitchen quote and confirm whether it covers moving the outlet?\nDana: Here is the quote. Cabinets, counters and installation are included. The electrician will confirm the outlet on Thursday.\nMe: Thanks. Please keep the permit and the updated schedule with the quote.")
        let documents = texts.map { EmbeddingDocument(title: "Photo · Synthetic kitchen conversation", text: $0) }
        let prepareStarted = ContinuousClock.now
        let pixels = try ImageProcessor.prepare(GemmaEmbedder.opaqueRGB(image), maxSoftTokens: imageTokens)
        return Prepared(image: image, pixels: pixels, documents: documents, texts: texts,
                        decode: decode, ocr: ocr, imagePrepare: seconds(prepareStarted))
    }

    private func run(_ urls: [URL], embedder: GemmaEmbedder, prefetch: Bool) async throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-image-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let vectors = VectorIndex(dimension: embedder.dimension)
        var items: [Item] = []
        for (index, _) in urls.enumerated() {
            var item = Item(source: .file, path: "/fixture/photo-\(index).jpg", kind: .image, title: "Synthetic photo",
                            size: 1, created: .distantPast, modified: .distantPast, lastUsed: nil)
            item.id = try store.record(item, signature: "synthetic").id
            items.append(item)
        }
        var result = Result()
        let started = ContinuousClock.now
        var next: Task<Prepared, any Error>?
        defer { next?.cancel() }
        if prefetch, let first = urls.first {
            next = Task.detached(priority: .medium) { try await self.prepare(first, imageTokens: embedder.imageTokens) }
        }
        for (index, url) in urls.enumerated() {
            let prepared: Prepared
            if let next { prepared = try await next.value }
            else { prepared = try await prepare(url, imageTokens: embedder.imageTokens) }
            next = nil
            if prefetch, index + 1 < urls.count {
                let following = urls[index + 1]
                next = Task.detached(priority: .medium) { try await self.prepare(following, imageTokens: embedder.imageTokens) }
            }
            result.decode += prepared.decode
            result.ocr += prepared.ocr
            result.imagePrepare += prepared.imagePrepare
            let textStarted = ContinuousClock.now
            let textVectors = try await embedder.embed(documents: prepared.documents)
            result.textModel += seconds(textStarted)
            let imageStarted = ContinuousClock.now
            let imageVector = try await embedder.encoder.encodeImage(prepared.pixels, dimensions: embedder.dimension)
            result.imageModel += seconds(imageStarted)
            result.vectors += textVectors + [imageVector]
            let writeStarted = ContinuousClock.now
            var units = zip(prepared.texts, textVectors).enumerated().map { offset, entry in
                (Unit(kind: .text, locator: .chunk(offset), text: entry.0), entry.1)
            }
            units.append((Unit(kind: .image, locator: .whole, text: "Synthetic photo OCR"), imageVector))
            let (added, removed) = try store.replaceUnits(itemID: items[index].id, title: items[index].title, units: units)
            vectors.remove(ids: removed)
            for (unit, vector) in zip(added, units.map(\.1)) { vectors.upsert(id: unit.id, kind: unit.kind, vector: vector) }
            result.write += seconds(writeStarted)
        }
        result.total = seconds(started)
        #expect(try store.counts().waiting == 0)
        return result
    }

    private func seconds(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

private struct WarmBenchmarkEmbedder: Embedder {
    let base: GemmaEmbedder
    var modelID: String { base.modelID }
    var dimension: Int { base.dimension }
    var supportsImages: Bool { base.supportsImages }
    func embed(queries: [String]) async throws -> [[Float]] { try await base.embed(queries: queries) }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] { try await base.embed(documents: documents) }
    func embed(images: [CGImage]) async throws -> [[Float]] { try await base.embed(images: images) }
    func prepare(image: CGImage) throws -> PreparedImageEmbedding { try base.prepare(image: image) }
}
