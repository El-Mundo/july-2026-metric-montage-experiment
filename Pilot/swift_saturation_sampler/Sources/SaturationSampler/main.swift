import AVFoundation
import CoreGraphics
import Foundation

struct Config {
    var videoDir = "/Volumes/Extreme SSD/Video/Chinese1949-66"
    var outputDir = "./saturation_sample_results_swift"
    var startTimeSec = 0.0
    var intervalSec = 5.0
    var maxFrames = 30
    var resizeWidth = 320
    var ffmpegBinary = "ffmpeg"
    var force = false
}

struct FileInfo {
    let film: String
    let path: String
    let fileSize: Int64
    let mtimeNs: Int64
}

struct FrameRow {
    let film: String
    let videoPath: String
    let frameSampleIndex: Int
    let timestampSec: Double
    let readOk: Bool
    let saturationMean: Double?
    let saturationMedian: Double?
    let saturationMax: Double?
    let frameWidth: Int?
    let frameHeight: Int?
}

struct SummaryRow {
    let info: FileInfo
    let sampledFrameCount: Int
    let requestedFrameCount: Int
    let startTimeSec: Double
    let sampleIntervalSec: Double
    let maxSampledFrames: Int
    let videoFps: Double
    let videoFrameCount: Int
    let videoDurationSec: Double
    let maxSaturationAnyPixel: Double
    let maxFrameMeanSaturation: Double
    let meanSaturation30Frames: Double
    let medianSaturation30Frames: Double
    let meanFrameMedianSaturation: Double
    let medianFrameMedianSaturation: Double
    let createdAt: String
}

struct ProgressRow {
    let info: FileInfo
    let status: String
    let sampledFrameCount: Int
    let error: String
    let startedAt: String
    let finishedAt: String
}

let summaryHeader = [
    "film", "video_path", "file_size", "mtime_ns", "sampled_frame_count",
    "requested_frame_count", "start_time_sec", "sample_interval_sec", "max_sampled_frames",
    "video_fps", "video_frame_count", "video_duration_sec", "max_saturation_any_pixel",
    "max_frame_mean_saturation", "mean_saturation_30_frames", "median_saturation_30_frames",
    "mean_frame_median_saturation", "median_frame_median_saturation", "created_at"
]

let frameHeader = [
    "film", "video_path", "frame_sample_index", "timestamp_sec", "read_ok",
    "saturation_mean", "saturation_median", "saturation_max", "frame_width", "frame_height"
]

let progressHeader = [
    "film", "video_path", "file_size", "mtime_ns", "status", "sampled_frame_count",
    "error", "started_at", "finished_at"
]

func parseArgs() -> Config {
    var config = Config()
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        func requireValue() -> String {
            guard index + 1 < args.count else {
                fatalError("Missing value for \(arg)")
            }
            index += 1
            return args[index]
        }
        switch arg {
        case "--video-dir":
            config.videoDir = requireValue()
        case "--output-dir":
            config.outputDir = requireValue()
        case "--start":
            config.startTimeSec = Double(requireValue()) ?? config.startTimeSec
        case "--interval":
            config.intervalSec = Double(requireValue()) ?? config.intervalSec
        case "--max-frames":
            config.maxFrames = Int(requireValue()) ?? config.maxFrames
        case "--resize-width":
            config.resizeWidth = Int(requireValue()) ?? config.resizeWidth
        case "--ffmpeg":
            config.ffmpegBinary = requireValue()
        case "--force":
            config.force = true
        case "--help", "-h":
            print("""
            Usage:
              swift run -c release saturation-sampler [options]

            Options:
              --video-dir PATH       Default: /Volumes/Extreme SSD/Video/Chinese1949-66
              --output-dir PATH      Default: ./saturation_sample_results_swift
              --start SECONDS        Default: 0
              --interval SECONDS     Default: 5
              --max-frames N         Default: 30
              --resize-width PX      Default: 320
              --ffmpeg PATH          Default: ffmpeg
              --force                Recompute movies already marked complete
            """)
            exit(0)
        default:
            fatalError("Unknown argument: \(arg)")
        }
        index += 1
    }
    return config
}

func nowIso() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func round4(_ value: Double) -> Double {
    (value * 10_000).rounded() / 10_000
}

func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}

func csvLine(_ values: [String]) -> String {
    values.map(csvEscape).joined(separator: ",")
}

func splitCsvLine(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var inQuotes = false
    var i = line.startIndex
    while i < line.endIndex {
        let ch = line[i]
        if ch == "\"" {
            let next = line.index(after: i)
            if inQuotes && next < line.endIndex && line[next] == "\"" {
                current.append("\"")
                i = line.index(after: next)
                continue
            }
            inQuotes.toggle()
        } else if ch == "," && !inQuotes {
            result.append(current)
            current = ""
        } else {
            current.append(ch)
        }
        i = line.index(after: i)
    }
    result.append(current)
    return result
}

func readCsvRows(path: URL) -> [[String: String]] {
    guard let text = try? String(contentsOf: path, encoding: .utf8), !text.isEmpty else {
        return []
    }
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard let first = lines.first else {
        return []
    }
    let header = splitCsvLine(first)
    return lines.dropFirst().map { line in
        let cells = splitCsvLine(line)
        var row: [String: String] = [:]
        for (idx, key) in header.enumerated() {
            row[key] = idx < cells.count ? cells[idx] : ""
        }
        return row
    }
}

func atomicWrite(path: URL, text: String) throws {
    let tmp = path.appendingPathExtension("tmp")
    try text.write(to: tmp, atomically: true, encoding: .utf8)
    if FileManager.default.fileExists(atPath: path.path) {
        try FileManager.default.removeItem(at: path)
    }
    try FileManager.default.moveItem(at: tmp, to: path)
}

func fileInfo(url: URL) throws -> FileInfo {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let stem = url.deletingPathExtension().lastPathComponent
    return FileInfo(film: stem, path: url.path, fileSize: fileSize, mtimeNs: Int64(mtime * 1_000_000_000))
}

func discoverVideos(videoDir: URL) -> [URL] {
    let extensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    guard let enumerator = FileManager.default.enumerator(at: videoDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var urls: [URL] = []
    for case let url as URL in enumerator {
        if url.lastPathComponent.hasPrefix("._") {
            continue
        }
        if extensions.contains(url.pathExtension.lowercased()) {
            urls.append(url)
        }
    }
    return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func isCompleteAndCurrent(progressRows: [[String: String]], info: FileInfo, force: Bool) -> Bool {
    if force {
        return false
    }
    guard let row = progressRows.last(where: { $0["video_path"] == info.path }) else {
        return false
    }
    return row["status"] == "complete"
        && Int64(row["file_size"] ?? "") == info.fileSize
        && Int64(row["mtime_ns"] ?? "") == info.mtimeNs
}

func rowsReplacingVideoPath(rows: [[String: String]], videoPath: String, newRows: [[String: String]]) -> [[String: String]] {
    rows.filter { $0["video_path"] != videoPath } + newRows
}

func writeTable(path: URL, header: [String], rows: [[String: String]]) throws {
    var lines = [csvLine(header)]
    for row in rows {
        lines.append(csvLine(header.map { row[$0] ?? "" }))
    }
    try atomicWrite(path: path, text: lines.joined(separator: "\n") + "\n")
}

func row(_ summary: SummaryRow) -> [String: String] {
    [
        "film": summary.info.film,
        "video_path": summary.info.path,
        "file_size": "\(summary.info.fileSize)",
        "mtime_ns": "\(summary.info.mtimeNs)",
        "sampled_frame_count": "\(summary.sampledFrameCount)",
        "requested_frame_count": "\(summary.requestedFrameCount)",
        "start_time_sec": "\(round4(summary.startTimeSec))",
        "sample_interval_sec": "\(round4(summary.sampleIntervalSec))",
        "max_sampled_frames": "\(summary.maxSampledFrames)",
        "video_fps": "\(round4(summary.videoFps))",
        "video_frame_count": "\(summary.videoFrameCount)",
        "video_duration_sec": "\(round4(summary.videoDurationSec))",
        "max_saturation_any_pixel": "\(round4(summary.maxSaturationAnyPixel))",
        "max_frame_mean_saturation": "\(round4(summary.maxFrameMeanSaturation))",
        "mean_saturation_30_frames": "\(round4(summary.meanSaturation30Frames))",
        "median_saturation_30_frames": "\(round4(summary.medianSaturation30Frames))",
        "mean_frame_median_saturation": "\(round4(summary.meanFrameMedianSaturation))",
        "median_frame_median_saturation": "\(round4(summary.medianFrameMedianSaturation))",
        "created_at": summary.createdAt
    ]
}

func row(_ frame: FrameRow) -> [String: String] {
    [
        "film": frame.film,
        "video_path": frame.videoPath,
        "frame_sample_index": "\(frame.frameSampleIndex)",
        "timestamp_sec": "\(round4(frame.timestampSec))",
        "read_ok": frame.readOk ? "true" : "false",
        "saturation_mean": frame.saturationMean.map { "\(round4($0))" } ?? "",
        "saturation_median": frame.saturationMedian.map { "\(round4($0))" } ?? "",
        "saturation_max": frame.saturationMax.map { "\(round4($0))" } ?? "",
        "frame_width": frame.frameWidth.map(String.init) ?? "",
        "frame_height": frame.frameHeight.map(String.init) ?? ""
    ]
}

func row(_ progress: ProgressRow) -> [String: String] {
    [
        "film": progress.info.film,
        "video_path": progress.info.path,
        "file_size": "\(progress.info.fileSize)",
        "mtime_ns": "\(progress.info.mtimeNs)",
        "status": progress.status,
        "sampled_frame_count": "\(progress.sampledFrameCount)",
        "error": progress.error,
        "started_at": progress.startedAt,
        "finished_at": progress.finishedAt
    ]
}

func pixelBufferStats(cgImage: CGImage, resizeWidth: Int) throws -> (mean: Double, median: Double, max: Double, width: Int, height: Int) {
    let sourceWidth = cgImage.width
    let sourceHeight = cgImage.height
    let width = min(resizeWidth, sourceWidth)
    let height = max(1, Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded()))
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var data = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw NSError(domain: "SaturationSampler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create CGContext"])
    }
    context.interpolationQuality = .low
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var histogram = [Int](repeating: 0, count: 256)
    var sum = 0
    var maxSat = 0
    let pixelCount = width * height
    for offset in stride(from: 0, to: data.count, by: bytesPerPixel) {
        let r = Int(data[offset])
        let g = Int(data[offset + 1])
        let b = Int(data[offset + 2])
        let channelMax = max(r, max(g, b))
        let channelMin = min(r, min(g, b))
        let saturation = channelMax == 0 ? 0 : (255 * (channelMax - channelMin) + channelMax / 2) / channelMax
        histogram[saturation] += 1
        sum += saturation
        if saturation > maxSat {
            maxSat = saturation
        }
    }

    let midpoint = pixelCount / 2
    var cumulative = 0
    var median = 0
    for value in 0..<histogram.count {
        cumulative += histogram[value]
        if cumulative > midpoint {
            median = value
            break
        }
    }

    return (Double(sum) / Double(pixelCount), Double(median), Double(maxSat), width, height)
}

func rgbByteStats(_ bytes: [UInt8], start: Int, width: Int, height: Int) -> (mean: Double, median: Double, max: Double, width: Int, height: Int) {
    let pixelCount = width * height
    var histogram = [Int](repeating: 0, count: 256)
    var sum = 0
    var maxSat = 0
    var offset = start
    for _ in 0..<pixelCount {
        let r = Int(bytes[offset])
        let g = Int(bytes[offset + 1])
        let b = Int(bytes[offset + 2])
        let channelMax = max(r, max(g, b))
        let channelMin = min(r, min(g, b))
        let saturation = channelMax == 0 ? 0 : (255 * (channelMax - channelMin) + channelMax / 2) / channelMax
        histogram[saturation] += 1
        sum += saturation
        if saturation > maxSat {
            maxSat = saturation
        }
        offset += 3
    }

    let midpoint = pixelCount / 2
    var cumulative = 0
    var median = 0
    for value in 0..<histogram.count {
        cumulative += histogram[value]
        if cumulative > midpoint {
            median = value
            break
        }
    }

    return (Double(sum) / Double(pixelCount), Double(median), Double(maxSat), width, height)
}

func readPpmToken(_ bytes: [UInt8], offset: inout Int) -> String? {
    var token: [UInt8] = []
    while offset < bytes.count {
        let byte = bytes[offset]
        offset += 1
        if byte == 35 {
            while offset < bytes.count && bytes[offset] != 10 && bytes[offset] != 13 {
                offset += 1
            }
            continue
        }
        if byte == 9 || byte == 10 || byte == 13 || byte == 32 {
            if !token.isEmpty {
                return String(bytes: token, encoding: .utf8)
            }
            continue
        }
        token.append(byte)
    }
    return token.isEmpty ? nil : String(bytes: token, encoding: .utf8)
}

func ffmpegFrameStats(url: URL, config: Config) throws -> [(timestamp: Double, stats: (mean: Double, median: Double, max: Double, width: Int, height: Int))] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var args = [
        config.ffmpegBinary,
        "-hide_banner",
        "-loglevel", "error",
        "-nostdin"
    ]
    if config.startTimeSec > 0 {
        args += ["-ss", "\(config.startTimeSec)"]
    }
    let decodeDuration = config.intervalSec * Double(max(config.maxFrames, 1))
    let selectFilter = "select='isnan(prev_selected_t)+gte(t-prev_selected_t,\(config.intervalSec))'"
    let vf = "\(selectFilter),scale=\(config.resizeWidth):-2"
    args += [
        "-t", "\(decodeDuration)",
        "-i", url.path,
        "-vf", vf,
        "-vsync", "0",
        "-frames:v", "\(config.maxFrames)",
        "-an", "-sn",
        "-f", "image2pipe",
        "-vcodec", "ppm",
        "pipe:1"
    ]
    process.arguments = args

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let err = String(data: errData, encoding: .utf8) ?? ""
        throw NSError(domain: "SaturationSampler", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed: \(err)"])
    }

    let bytes = [UInt8](outData)
    var offset = 0
    var results: [(timestamp: Double, stats: (mean: Double, median: Double, max: Double, width: Int, height: Int))] = []
    while offset < bytes.count {
        guard let magic = readPpmToken(bytes, offset: &offset) else {
            break
        }
        guard magic == "P6" else {
            throw NSError(domain: "SaturationSampler", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected PPM magic: \(magic)"])
        }
        guard
            let widthText = readPpmToken(bytes, offset: &offset),
            let heightText = readPpmToken(bytes, offset: &offset),
            let maxText = readPpmToken(bytes, offset: &offset),
            let width = Int(widthText),
            let height = Int(heightText),
            let maxValue = Int(maxText)
        else {
            throw NSError(domain: "SaturationSampler", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not parse PPM header"])
        }
        guard maxValue == 255 else {
            throw NSError(domain: "SaturationSampler", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unexpected PPM max value: \(maxValue)"])
        }
        let byteCount = width * height * 3
        guard offset + byteCount <= bytes.count else {
            throw NSError(domain: "SaturationSampler", code: 7, userInfo: [NSLocalizedDescriptionKey: "Truncated PPM payload"])
        }
        let stats = rgbByteStats(bytes, start: offset, width: width, height: height)
        let timestamp = config.startTimeSec + Double(results.count) * config.intervalSec
        results.append((timestamp: timestamp, stats: stats))
        offset += byteCount
    }
    return results
}

func assetMetadata(url: URL) -> (fps: Double, durationSec: Double, frameCount: Int) {
    let asset = AVURLAsset(url: url)
    let track = asset.tracks(withMediaType: .video).first
    let fps = Double(track?.nominalFrameRate ?? 0)
    let durationSec = CMTimeGetSeconds(asset.duration)
    let frameCount = fps > 0 && durationSec.isFinite ? Int((fps * durationSec).rounded()) : 0
    return (fps, durationSec, frameCount)
}

func sampleVideo(url: URL, config: Config) throws -> ([FrameRow], SummaryRow) {
    let info = try fileInfo(url: url)
    let metadata = assetMetadata(url: url)
    let fps = metadata.fps
    let durationSec = metadata.durationSec
    let frameCount = metadata.frameCount
    let sampledStats = try ffmpegFrameStats(url: url, config: config)

    var frameRows: [FrameRow] = []
    var means: [Double] = []
    var medians: [Double] = []
    var maxes: [Double] = []

    for sampleIndex in 1...config.maxFrames {
        let timestamp = config.startTimeSec + Double(sampleIndex - 1) * config.intervalSec
        if sampleIndex > sampledStats.count {
            frameRows.append(FrameRow(
                film: info.film, videoPath: info.path, frameSampleIndex: sampleIndex,
                timestampSec: timestamp, readOk: false, saturationMean: nil,
                saturationMedian: nil, saturationMax: nil, frameWidth: nil, frameHeight: nil
            ))
            continue
        }
        let stats = sampledStats[sampleIndex - 1].stats
        means.append(stats.mean)
        medians.append(stats.median)
        maxes.append(stats.max)
        frameRows.append(FrameRow(
            film: info.film, videoPath: info.path, frameSampleIndex: sampleIndex,
            timestampSec: timestamp, readOk: true, saturationMean: stats.mean,
            saturationMedian: stats.median, saturationMax: stats.max,
            frameWidth: stats.width, frameHeight: stats.height
        ))
    }

    guard !means.isEmpty else {
        throw NSError(domain: "SaturationSampler", code: 2, userInfo: [NSLocalizedDescriptionKey: "No sampled frames could be read"])
    }

    func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    let summary = SummaryRow(
        info: info,
        sampledFrameCount: means.count,
        requestedFrameCount: config.maxFrames,
        startTimeSec: config.startTimeSec,
        sampleIntervalSec: config.intervalSec,
        maxSampledFrames: config.maxFrames,
        videoFps: fps,
        videoFrameCount: frameCount,
        videoDurationSec: durationSec,
        maxSaturationAnyPixel: maxes.max() ?? 0,
        maxFrameMeanSaturation: means.max() ?? 0,
        meanSaturation30Frames: mean(means),
        medianSaturation30Frames: median(means),
        meanFrameMedianSaturation: mean(medians),
        medianFrameMedianSaturation: median(medians),
        createdAt: nowIso()
    )
    return (frameRows, summary)
}

let config = parseArgs()
let videoDir = URL(fileURLWithPath: config.videoDir)
let outputDir = URL(fileURLWithPath: config.outputDir)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let summaryCsv = outputDir.appendingPathComponent("movie_saturation_summary.csv")
let framesCsv = outputDir.appendingPathComponent("movie_saturation_frames.csv")
let progressCsv = outputDir.appendingPathComponent("movie_saturation_progress.csv")

var summaryRows = readCsvRows(path: summaryCsv)
var frameRows = readCsvRows(path: framesCsv)
var progressRows = readCsvRows(path: progressCsv)

let videos = discoverVideos(videoDir: videoDir)
print("Discovered videos: \(videos.count)")

var pending: [(URL, FileInfo)] = []
for url in videos {
    let info = try fileInfo(url: url)
    if !isCompleteAndCurrent(progressRows: progressRows, info: info, force: config.force) {
        pending.append((url, info))
    }
}
print("Already complete/current: \(videos.count - pending.count)")
print("Pending this run: \(pending.count)")

for (index, item) in pending.enumerated() {
    let (url, info) = item
    let startedAt = nowIso()
    print("[\(index + 1)/\(pending.count)] \(url.lastPathComponent)")

    progressRows = rowsReplacingVideoPath(
        rows: progressRows,
        videoPath: info.path,
        newRows: [row(ProgressRow(info: info, status: "running", sampledFrameCount: 0, error: "", startedAt: startedAt, finishedAt: ""))]
    )
    try writeTable(path: progressCsv, header: progressHeader, rows: progressRows)

    do {
        let (sampledFrames, summary) = try sampleVideo(url: url, config: config)
        summaryRows = rowsReplacingVideoPath(rows: summaryRows, videoPath: info.path, newRows: [row(summary)])
        frameRows = rowsReplacingVideoPath(rows: frameRows, videoPath: info.path, newRows: sampledFrames.map(row))
        try writeTable(path: summaryCsv, header: summaryHeader, rows: summaryRows.sorted { ($0["film"] ?? "") < ($1["film"] ?? "") })
        try writeTable(path: framesCsv, header: frameHeader, rows: frameRows.sorted {
            if ($0["film"] ?? "") == ($1["film"] ?? "") {
                return (Int($0["frame_sample_index"] ?? "") ?? 0) < (Int($1["frame_sample_index"] ?? "") ?? 0)
            }
            return ($0["film"] ?? "") < ($1["film"] ?? "")
        })
        progressRows = rowsReplacingVideoPath(
            rows: progressRows,
            videoPath: info.path,
            newRows: [row(ProgressRow(info: info, status: "complete", sampledFrameCount: summary.sampledFrameCount, error: "", startedAt: startedAt, finishedAt: nowIso()))]
        )
        try writeTable(path: progressCsv, header: progressHeader, rows: progressRows.sorted { ($0["film"] ?? "") < ($1["film"] ?? "") })
    } catch {
        progressRows = rowsReplacingVideoPath(
            rows: progressRows,
            videoPath: info.path,
            newRows: [row(ProgressRow(info: info, status: "failed", sampledFrameCount: 0, error: String(describing: error), startedAt: startedAt, finishedAt: nowIso()))]
        )
        try writeTable(path: progressCsv, header: progressHeader, rows: progressRows.sorted { ($0["film"] ?? "") < ($1["film"] ?? "") })
        print("FAILED \(url.lastPathComponent): \(error)")
    }
}

let complete = progressRows.filter { $0["status"] == "complete" }.count
let failed = progressRows.filter { $0["status"] == "failed" }.count
print("Done. Complete: \(complete), failed: \(failed), summary rows: \(summaryRows.count)")
