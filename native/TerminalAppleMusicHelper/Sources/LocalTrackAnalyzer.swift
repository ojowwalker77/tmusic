import Foundation
import AVFAudio
import iTunesLibrary

private let localAnalysisFrameDuration = 1.0 / 30.0
private let localAnalysisWindowSeconds = 0.05
private let localTrackDurationTolerance = 2.5
private let maxCachedTrackMatches = 256
private let maxCachedTrackAnalyses = 6
private let maxFailedTrackAnalyses = 256

private struct LocalLibraryEntry: Sendable {
  let title: String
  let artist: String
  let album: String
  let duration: Double
  let location: URL?
  let isCloud: Bool
  let isDRMProtected: Bool
  let keyWithAlbum: String
  let keyWithoutAlbum: String
  let looseKey: String
}

private struct LocalTrackAnalysis: Sendable {
  let frameDuration: Double
  let frames: [[Double]]

  func sample(at position: Double) -> [Double] {
    guard !frames.isEmpty else {
      return Array(repeating: 0, count: spectrumBinCount)
    }

    let normalizedPosition = max(0, position)
    let scaled = normalizedPosition / max(frameDuration, 0.001)
    let leftIndex = max(0, min(frames.count - 1, Int(floor(scaled))))
    let rightIndex = max(0, min(frames.count - 1, leftIndex + 1))
    let amount = max(0, min(1, scaled - floor(scaled)))

    if leftIndex == rightIndex {
      return frames[leftIndex]
    }

    let left = frames[leftIndex]
    let right = frames[rightIndex]
    return zip(left, right).map { lhs, rhs in
      lhs * (1 - amount) + rhs * amount
    }
  }
}

actor LocalTrackAnalyzer {
  private var libraryLoaded = false
  private var loadAttempted = false
  private var libraryEntriesByKey: [String: [LocalLibraryEntry]] = [:]
  private var matchCache: [String: LocalLibraryEntry?] = [:]
  private var matchCacheOrder: [String] = []
  private var analysisCache: [String: LocalTrackAnalysis] = [:]
  private var analysisCacheOrder: [String] = []
  private var analysisTasks: [String: Task<LocalTrackAnalysis?, Never>] = [:]
  private var failedAnalysis = Set<String>()
  private var failedAnalysisOrder: [String] = []

  func prepare(track: WireTrack) async {
    await loadLibraryIfNeeded()
    guard let entry = resolveEntry(for: track), canRead(entry: entry) else {
      return
    }

    if analysisCache[track.id] != nil || analysisTasks[track.id] != nil || failedAnalysis.contains(track.id) {
      return
    }

    guard let url = entry.location else { return }
    let task = Task.detached(priority: .utility) { () -> LocalTrackAnalysis? in
      do {
        return try analyzeFile(at: url, durationHint: track.duration)
      } catch {
        debugLog("local analysis failed for \(url.lastPathComponent): \(error)")
        return nil
      }
    }
    analysisTasks[track.id] = task

    Task {
      let result = await task.value
      self.finishAnalysis(trackID: track.id, result: result)
    }
  }

  func energyIfReady(track: WireTrack, position: Double) async -> [Double]? {
    await prepare(track: track)
    guard let analysis = analysisCache[track.id] else {
      return nil
    }
    touch(track.id, in: &analysisCacheOrder)
    return analysis.sample(at: position)
  }

  private func finishAnalysis(trackID: String, result: LocalTrackAnalysis?) {
    analysisTasks[trackID] = nil
    if let result {
      rememberAnalysis(result, for: trackID)
    } else {
      rememberFailedAnalysis(trackID)
    }
  }

  private func loadLibraryIfNeeded() async {
    guard !libraryLoaded, !loadAttempted else { return }
    loadAttempted = true

    do {
      let library = try ITLibrary(apiVersion: "1.0")
      var readableCount = 0
      var readableSamples: [String] = []
      for item in library.allMediaItems {
        let title = normalized(item.title)
        guard !title.isEmpty else { continue }

        let artist = normalized(item.artist?.name ?? "")
        let album = normalized(item.album.title ?? "")
        let duration = Double(item.totalTime) / 1000
        let entry = LocalLibraryEntry(
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          location: item.location,
          isCloud: item.isCloud,
          isDRMProtected: item.isDRMProtected,
          keyWithAlbum: matchKey(title: title, artist: artist, album: album, duration: duration),
          keyWithoutAlbum: matchKey(title: title, artist: artist, album: "", duration: duration),
          looseKey: "\(title)|\(artist)",
        )

        libraryEntriesByKey[entry.keyWithAlbum, default: []].append(entry)
        libraryEntriesByKey[entry.keyWithoutAlbum, default: []].append(entry)
        libraryEntriesByKey[entry.looseKey, default: []].append(entry)
        if canRead(entry: entry) {
          readableCount += 1
          if readableSamples.count < 10 {
            readableSamples.append("\(item.title) -> \(entry.location?.lastPathComponent ?? "unknown")")
          }
        }
      }
      libraryLoaded = true
      debugLog("loaded local library index: items=\(library.allMediaItems.count) readable=\(readableCount)")
      if !readableSamples.isEmpty {
        debugLog("readable local items: \(readableSamples.joined(separator: " | "))")
      }
    } catch {
      debugLog("failed to load iTunesLibrary index: \(error)")
    }
  }

  private func resolveEntry(for track: WireTrack) -> LocalLibraryEntry? {
    if let cached = matchCache[track.id] {
      touch(track.id, in: &matchCacheOrder)
      return cached
    }

    let title = normalized(track.name)
    let artist = normalized(track.artist)
    let album = normalized(track.album)
    let preferredKey = matchKey(title: title, artist: artist, album: album, duration: track.duration)
    let fallbackKey = matchKey(title: title, artist: artist, album: "", duration: track.duration)
    let looseKey = "\(title)|\(artist)"
    let candidates =
      (libraryEntriesByKey[preferredKey] ?? [])
      + (libraryEntriesByKey[fallbackKey] ?? [])
      + (libraryEntriesByKey[looseKey] ?? [])

    let chosen = candidates.min { lhs, rhs in
      score(entry: lhs, track: track) < score(entry: rhs, track: track)
    }

    if let chosen {
      debugLog(
        "matched local track \(track.name) -> \(chosen.location?.lastPathComponent ?? "no-file") drm=\(chosen.isDRMProtected) cloud=\(chosen.isCloud)"
      )
    }

    rememberMatch(chosen, for: track.id)
    return chosen
  }

  private func score(entry: LocalLibraryEntry, track: WireTrack) -> Double {
    let durationPenalty = abs(entry.duration - track.duration)
    let albumPenalty = entry.album == normalized(track.album) ? 0 : 0.35
    let artistPenalty = entry.artist == normalized(track.artist) ? 0 : 0.6
    return durationPenalty + albumPenalty + artistPenalty
  }

  private func canRead(entry: LocalLibraryEntry) -> Bool {
    guard entry.location != nil else { return false }
    if entry.isDRMProtected { return false }
    return true
  }

  private func rememberMatch(_ entry: LocalLibraryEntry?, for trackID: String) {
    matchCache[trackID] = entry
    touch(trackID, in: &matchCacheOrder)
    trimCache(&matchCache, order: &matchCacheOrder, limit: maxCachedTrackMatches)
  }

  private func rememberAnalysis(_ analysis: LocalTrackAnalysis, for trackID: String) {
    analysisCache[trackID] = analysis
    touch(trackID, in: &analysisCacheOrder)
    trimCache(&analysisCache, order: &analysisCacheOrder, limit: maxCachedTrackAnalyses)
  }

  private func rememberFailedAnalysis(_ trackID: String) {
    failedAnalysis.insert(trackID)
    touch(trackID, in: &failedAnalysisOrder)
    trimSet(&failedAnalysis, order: &failedAnalysisOrder, limit: maxFailedTrackAnalyses)
  }

  private func touch(_ key: String, in order: inout [String]) {
    if let existingIndex = order.firstIndex(of: key) {
      order.remove(at: existingIndex)
    }
    order.append(key)
  }

  private func trimCache<Value>(
    _ cache: inout [String: Value],
    order: inout [String],
    limit: Int,
  ) {
    while order.count > limit {
      let oldest = order.removeFirst()
      cache.removeValue(forKey: oldest)
    }
  }

  private func trimSet(
    _ set: inout Set<String>,
    order: inout [String],
    limit: Int,
  ) {
    while order.count > limit {
      let oldest = order.removeFirst()
      set.remove(oldest)
    }
  }
}

private func analyzeFile(at url: URL, durationHint: Double) throws -> LocalTrackAnalysis {
  let file = try AVAudioFile(forReading: url)
  let sourceFormat = file.processingFormat
  let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: sourceFormat.sampleRate,
    channels: sourceFormat.channelCount,
    interleaved: false,
  )!

  let chunkFrameCount: AVAudioFrameCount = 16_384
  guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkFrameCount) else {
    throw NSError(domain: "LocalTrackAnalyzer", code: -1, userInfo: [NSLocalizedDescriptionKey: "unable to allocate pcm buffer"])
  }

  var monoSamples: [Float] = []
  monoSamples.reserveCapacity(Int(min(file.length, 4_000_000)))

  file.framePosition = 0
  while true {
    try file.read(into: buffer, frameCount: chunkFrameCount)
    let frameLength = Int(buffer.frameLength)
    if frameLength == 0 { break }

    let channelCount = Int(buffer.format.channelCount)
    if channelCount == 0 { break }

    guard let channels = buffer.floatChannelData else { break }
    for frame in 0..<frameLength {
      var total: Float = 0
      for channel in 0..<channelCount {
        total += channels[channel][frame]
      }
      monoSamples.append(total / Float(channelCount))
    }
  }

  let sampleRate = outputFormat.sampleRate
  let inferredDuration = Double(monoSamples.count) / max(sampleRate, 1)
  let duration = max(durationHint, inferredDuration)
  let frameCount = max(1, Int(ceil(duration / localAnalysisFrameDuration)))
  let windowRadius = max(256, Int(sampleRate * localAnalysisWindowSeconds * 0.5))

  var frames = Array(repeating: Array(repeating: Double(0), count: spectrumBinCount), count: frameCount)
  for frameIndex in 0..<frameCount {
    let centerTime = Double(frameIndex) * localAnalysisFrameDuration
    let centerSample = Int(centerTime * sampleRate)
    let start = max(0, centerSample - windowRadius)
    let end = min(monoSamples.count, centerSample + windowRadius)
    let slice = Array(monoSamples[start..<end])
    let bins = buildSpectrumBins(from: slice, sampleRate: Float(sampleRate))
    frames[frameIndex] = bins.map(Double.init)
  }

  return LocalTrackAnalysis(
    frameDuration: localAnalysisFrameDuration,
    frames: frames,
  )
}

private func matchKey(title: String, artist: String, album: String, duration: Double) -> String {
  let bucket = Int((duration / localTrackDurationTolerance).rounded())
  return "\(title)|\(artist)|\(album)|\(bucket)"
}

private func normalized(_ value: String) -> String {
  let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  let scalars = folded.unicodeScalars.map { scalar -> Character in
    if CharacterSet.alphanumerics.contains(scalar) {
      return Character(scalar)
    }
    return " "
  }
  return String(scalars)
    .split(separator: " ")
    .joined(separator: " ")
}
