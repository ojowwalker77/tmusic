import Foundation
import MusicKit

let debugEnabled = ProcessInfo.processInfo.environment["TERMINAL_APPLE_MUSIC_DEBUG"] == "1"

func debugLog(_ message: String) {
  guard debugEnabled else { return }
  fputs("[helper] \(message)\n", stderr)
}

struct WireTrack: Codable, Sendable {
  let id: String
  let name: String
  let artist: String
  let album: String
  let duration: Double
  let genre: String
  let year: Int
  let playCount: Int
  let loved: Bool
  let trackNumber: Int
}

struct WirePlaylist: Codable, Sendable {
  let id: String
  let name: String
  let trackCount: Int
}

struct WireNowPlaying: Codable, Sendable {
  let track: WireTrack?
  let state: String
  let position: Double
  let volume: Int
  let shuffleEnabled: Bool
  let repeatMode: String
  let energy: [Double]
  let analysisSource: String
}

struct BootstrapPayload: Codable, Sendable {
  let libraryTracks: [WireTrack]
  let playlists: [WirePlaylist]
}

struct HelperRequest: Decodable, Sendable {
  let id: String
  let method: String
  let playlistId: String?
  let trackId: String?
  let startIndex: Int?
  let enabled: Bool?
  let repeatMode: String?
}

struct HelperErrorPayload: Codable, Sendable {
  let code: String
  let message: String
  let detail: String?
}

struct HelperResponse: Codable, Sendable {
  let id: String
  let ok: Bool
  let bootstrap: BootstrapPayload?
  let tracks: [WireTrack]?
  let nowPlaying: WireNowPlaying?
  let error: HelperErrorPayload?

  static func ok(id: String, bootstrap: BootstrapPayload? = nil, tracks: [WireTrack]? = nil, nowPlaying: WireNowPlaying? = nil) -> HelperResponse {
    HelperResponse(id: id, ok: true, bootstrap: bootstrap, tracks: tracks, nowPlaying: nowPlaying, error: nil)
  }

  static func failure(id: String, code: String, message: String, detail: String? = nil) -> HelperResponse {
    HelperResponse(
      id: id,
      ok: false,
      bootstrap: nil,
      tracks: nil,
      nowPlaying: nil,
      error: HelperErrorPayload(code: code, message: message, detail: detail)
    )
  }
}

enum ServiceError: Error {
  case permissionDenied(String)
  case notFound(String)
  case invalidRequest(String)
}

private func lineEncoded(_ response: HelperResponse, encoder: JSONEncoder) -> Data {
  var data = (try? encoder.encode(response)) ?? Data("{\"id\":\"unknown\",\"ok\":false}".utf8)
  data.append(0x0a)
  return data
}

final class MusicService {
  private let maxRetainedSongs = 48
  private let maxCachedPlaylistTrackSets = 8
  private let player = ApplicationMusicPlayer.shared
  private let analyzer = AudioEnergyAnalyzer()
  private let localTrackAnalyzer = LocalTrackAnalyzer()
  private var songCache: [String: Song] = [:]
  private var songCacheOrder: [String] = []
  private var trackCache: [String: WireTrack] = [:]
  private var libraryTracks: [WireTrack] = []
  private var playlists: [String: Playlist] = [:]
  private var playlistSummaries: [WirePlaylist] = []
  private var playlistTrackCache: [String: [WireTrack]] = [:]
  private var playlistTrackCacheOrder: [String] = []
  private var activeQueueTrackIDs: [String] = []
  private var activeQueueIndex = 0
  private var trackedTrackID: String?
  private var trackedPosition: Double = 0
  private var positionAnchor = Date()
  private var shuffleEnabled = false
  private var repeatMode = "off"
  private var authorizationResolved = false

  func bootstrap() async throws -> BootstrapPayload {
    try await authorize()
    analyzer.startIfNeeded()
    try await loadLibraryIfNeeded()
    return BootstrapPayload(libraryTracks: libraryTracks, playlists: playlistSummaries)
  }

  func playlistTracks(id: String) async throws -> [WireTrack] {
    try await authorize()
    try await loadLibraryIfNeeded()

    if let cached = playlistTrackCache[id] {
      touchCacheKey(id, in: &playlistTrackCacheOrder)
      return cached
    }

    guard let playlist = playlists[id] else {
      throw ServiceError.notFound("playlist not found")
    }

    let detailedPlaylist = try await playlist.with([.tracks])
    guard let collection = detailedPlaylist.tracks else {
      return []
    }

    let items = try await collectAll(from: collection)
    let tracks = items.compactMap { item -> Song? in
      switch item {
        case .song(let song):
          return song
        default:
          return nil
      }
    }
    .sorted { lhs, rhs in
      compareSongsByAddedDate(lhs, rhs)
    }
    .map { song in
      cache(song: song)
    }

    rememberPlaylistTracks(tracks, for: id)
    return tracks
  }

  func playTrack(id: String, playlistID: String?, startIndex: Int?) async throws {
    try await authorize()
    analyzer.startIfNeeded()
    try await loadLibraryIfNeeded()

    let queueTracks = try await queueTracks(for: playlistID)
    let index: Int
    if let startIndex, queueTracks.indices.contains(startIndex), queueTracks[startIndex].id == id {
      index = startIndex
    } else if let foundIndex = queueTracks.firstIndex(where: { $0.id == id }) {
      index = foundIndex
    } else {
      throw ServiceError.notFound("track not found")
    }

    activeQueueTrackIDs = queueTracks.map(\.id)
    await localTrackAnalyzer.prepare(track: queueTracks[index])
    try await playQueueEntry(at: index)
  }

  func playpause() async throws {
    switch player.state.playbackStatus {
      case .playing:
        trackedPosition = estimatedPosition()
        positionAnchor = Date()
        player.pause()
      default:
        positionAnchor = Date()
        try await player.play()
    }
  }

  func next() async throws {
    try await authorize()
    try await loadLibraryIfNeeded()

    guard !activeQueueTrackIDs.isEmpty else { return }

    if repeatMode == "one" {
      try await playQueueEntry(at: activeQueueIndex)
      return
    }

    if shuffleEnabled && activeQueueTrackIDs.count > 1 {
      var candidates = Array(activeQueueTrackIDs.indices)
      candidates.removeAll { $0 == activeQueueIndex }
      if let randomIndex = candidates.randomElement() {
        try await playQueueEntry(at: randomIndex)
      }
      return
    }

    let nextIndex = activeQueueIndex + 1
    if activeQueueTrackIDs.indices.contains(nextIndex) {
      try await playQueueEntry(at: nextIndex)
      return
    }

    if repeatMode == "all" {
      try await playQueueEntry(at: 0)
      return
    }

    trackedPosition = estimatedPosition()
    positionAnchor = Date()
    player.pause()
  }

  func prev() async throws {
    try await authorize()
    try await loadLibraryIfNeeded()

    guard !activeQueueTrackIDs.isEmpty else { return }

    if estimatedPosition() > 3 || repeatMode == "one" {
      try await playQueueEntry(at: activeQueueIndex)
      return
    }

    if shuffleEnabled && activeQueueTrackIDs.count > 1 {
      var candidates = Array(activeQueueTrackIDs.indices)
      candidates.removeAll { $0 == activeQueueIndex }
      if let randomIndex = candidates.randomElement() {
        try await playQueueEntry(at: randomIndex)
      }
      return
    }

    let previousIndex = activeQueueIndex - 1
    if activeQueueTrackIDs.indices.contains(previousIndex) {
      try await playQueueEntry(at: previousIndex)
      return
    }

    if repeatMode == "all", let lastIndex = activeQueueTrackIDs.indices.last {
      try await playQueueEntry(at: lastIndex)
      return
    }

    try await playQueueEntry(at: activeQueueIndex)
  }

  func setShuffle(enabled: Bool) {
    shuffleEnabled = enabled
  }

  func setRepeat(mode: String) {
    repeatMode = mode
  }

  func nowPlaying() async throws -> WireNowPlaying {
    try await authorize()
    analyzer.startIfNeeded()

    let track = try await currentTrack()
    if let track {
      if trackedTrackID != track.id {
        trackedTrackID = track.id
        trackedPosition = 0
        positionAnchor = Date()
      }
      if let queueIndex = activeQueueTrackIDs.firstIndex(of: track.id) {
        activeQueueIndex = queueIndex
      }
    } else {
      trackedTrackID = nil
      trackedPosition = 0
      positionAnchor = Date()
    }

    let state: String
    switch player.state.playbackStatus {
      case .playing:
        state = "playing"
      case .paused:
        state = "paused"
      default:
        state = "stopped"
    }

    let position = estimatedPosition()
    var energy: [Double]
    var analysisSource: String

    if let track, let localEnergy = await localTrackAnalyzer.energyIfReady(track: track, position: position) {
      energy = localEnergy
      analysisSource = "file"
    } else {
      let snapshot = analyzer.snapshot()
      energy = snapshot.bins
      analysisSource = snapshot.source
    }

    if state == "playing", analysisSource != "file", analysisSource != "fft" || energy.allSatisfy({ $0 < 0.0001 }) {
      energy = fallbackEnergy(
        seed: track?.id ?? trackedTrackID ?? "terminal-apple-music",
        position: position,
        binCount: max(energy.count, 48),
      )
      analysisSource = "fallback"
    }

    return WireNowPlaying(
      track: track,
      state: state,
      position: position,
      volume: 100,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
      energy: energy,
      analysisSource: analysisSource
    )
  }

  private func authorize() async throws {
    if authorizationResolved {
      return
    }

    let currentStatus = MusicAuthorization.currentStatus
    if currentStatus == .authorized {
      authorizationResolved = true
      return
    }

    let status = await MusicAuthorization.request()
    guard status == .authorized else {
      throw ServiceError.permissionDenied("music access denied")
    }
    authorizationResolved = true
  }

  private func loadLibraryIfNeeded() async throws {
    guard libraryTracks.isEmpty else { return }

    var songRequest = MusicLibraryRequest<Song>()
    songRequest.limit = 1000
    let songResponse = try await songRequest.response()
    let songs = try await collectAll(from: songResponse.items)
      .sorted { lhs, rhs in
        compareSongsByAddedDate(lhs, rhs)
      }
    libraryTracks = songs.map { song in
      cache(song: song)
    }

    var playlistRequest = MusicLibraryRequest<Playlist>()
    playlistRequest.limit = 1000
    let playlistResponse = try await playlistRequest.response()
    let loadedPlaylists = try await collectAll(from: playlistResponse.items)
    playlistSummaries = loadedPlaylists.map { playlist in
      let id = playlist.id.rawValue
      playlists[id] = playlist
      return WirePlaylist(id: id, name: playlist.name, trackCount: 0)
    }
  }

  private func queueTracks(for playlistID: String?) async throws -> [WireTrack] {
    if let playlistID, playlistID != "library" {
      return try await playlistTracks(id: playlistID)
    }
    return libraryTracks
  }

  private func playQueueEntry(at index: Int) async throws {
    guard activeQueueTrackIDs.indices.contains(index) else {
      throw ServiceError.notFound("track not found")
    }

    let id = activeQueueTrackIDs[index]
    let song: Song?
    if let cached = cachedSong(id: id) {
      song = cached
    } else {
      song = try await resolveSong(id: id)
    }

    guard let song else {
      throw ServiceError.notFound("track not found")
    }

    player.queue = [song]
    activeQueueIndex = index
    trackedTrackID = id
    trackedPosition = 0
    positionAnchor = Date()
    try await player.play()
  }

  private func resolveSong(id: String) async throws -> Song? {
    if let song = cachedSong(id: id) {
      return song
    }

    var request = MusicLibraryRequest<Song>()
    request.filter(matching: \.id, equalTo: MusicItemID(rawValue: id))
    request.limit = 1
    let response = try await request.response()
    guard let song = response.items.first else { return nil }
    _ = cache(song: song, retainSong: true)
    return song
  }

  private func currentTrack() async throws -> WireTrack? {
    guard let entry = player.queue.currentEntry, let item = entry.item else {
      return nil
    }

    let id = item.id.rawValue
    if let cached = trackCache[id] {
      return cached
    }

    if let song = try await resolveSong(id: id) {
      return cache(song: song)
    }

    return nil
  }

  private func estimatedPosition() -> Double {
    guard let trackID = trackedTrackID, let track = trackCache[trackID] else { return 0 }
    guard player.state.playbackStatus == .playing else { return min(track.duration, trackedPosition) }
    let elapsed = Date().timeIntervalSince(positionAnchor)
    return min(track.duration, trackedPosition + elapsed)
  }

  private func fallbackEnergy(seed: String, position: Double, binCount: Int) -> [Double] {
    let hash = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { partialResult, scalar in
      (partialResult ^ UInt64(scalar.value)) &* 1099511628211
    }
    let tempo = 2.1 + Double(hash % 5) * 0.18
    let wobble = 4.3 + Double((hash >> 3) % 7) * 0.21
    let spread = 0.08 + Double((hash >> 7) % 5) * 0.012

    return (0..<max(1, binCount)).map { index in
      let x = Double(index) / Double(max(1, binCount))
      let anchorA = Double((hash >> 11) % UInt64(max(1, binCount))) / Double(max(1, binCount))
      let anchorB = Double((hash >> 17) % UInt64(max(1, binCount))) / Double(max(1, binCount))
      let pulseA = exp(-pow((x - anchorA) / spread, 2)) * (sin(position * tempo) * 0.5 + 0.5)
      let pulseB = exp(-pow((x - anchorB) / (spread * 1.6), 2)) * (cos(position * (tempo * 0.63)) * 0.5 + 0.5)
      let shimmer =
        sin(position * wobble + x * Double.pi * 4) * 0.22
        + cos(position * (wobble * 0.73) - x * Double.pi * 7) * 0.18
      let floor = 0.12 + (sin(position * 1.7 + x * Double.pi * 2) * 0.5 + 0.5) * 0.08
      return min(1, max(0, floor + pulseA * 0.55 + pulseB * 0.42 + shimmer))
    }
  }

  private func compareSongsByAddedDate(_ lhs: Song, _ rhs: Song) -> Bool {
    let lhsDate = lhs.libraryAddedDate ?? .distantPast
    let rhsDate = rhs.libraryAddedDate ?? .distantPast
    if lhsDate == rhsDate {
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
    return lhsDate > rhsDate
  }

  private func cache(song: Song, retainSong: Bool = false) -> WireTrack {
    let id = song.id.rawValue
    if retainSong {
      rememberSong(song)
    }
    if let cached = trackCache[id] {
      return cached
    }

    let year = song.releaseDate.map { Calendar.current.component(.year, from: $0) } ?? 0
    let track = WireTrack(
      id: id,
      name: song.title,
      artist: song.artistName,
      album: song.albumTitle ?? "",
      duration: song.duration ?? 0,
      genre: song.genreNames.first ?? "",
      year: year,
      playCount: 0,
      loved: false,
      trackNumber: song.trackNumber ?? 0
    )

    trackCache[id] = track
    return track
  }

  private func cachedSong(id: String) -> Song? {
    guard let song = songCache[id] else {
      return nil
    }
    touchCacheKey(id, in: &songCacheOrder)
    return song
  }

  private func rememberSong(_ song: Song) {
    let id = song.id.rawValue
    songCache[id] = song
    touchCacheKey(id, in: &songCacheOrder)
    trimCache(&songCache, order: &songCacheOrder, limit: maxRetainedSongs)
  }

  private func rememberPlaylistTracks(_ tracks: [WireTrack], for playlistID: String) {
    playlistTrackCache[playlistID] = tracks
    touchCacheKey(playlistID, in: &playlistTrackCacheOrder)
    trimCache(&playlistTrackCache, order: &playlistTrackCacheOrder, limit: maxCachedPlaylistTrackSets)
  }

  private func touchCacheKey(_ key: String, in order: inout [String]) {
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

  private func collectAll<Item>(from collection: MusicItemCollection<Item>) async throws -> [Item] {
    var allItems = Array(collection)
    var batch = collection

    while batch.hasNextBatch {
      guard let nextBatch = try await batch.nextBatch(limit: 1000) else {
        break
      }
      batch = nextBatch
      allItems.append(contentsOf: batch)
    }

    return allItems
  }
}

final class UnixSocketServer: @unchecked Sendable {
  private let path: String
  private let queue = DispatchQueue(
    label: "terminal-apple-music.helper.socket",
    qos: .userInitiated,
    attributes: .concurrent,
  )
  private let service = MusicService()
  private var listenerFD: Int32 = -1

  init(path: String) {
    self.path = path
  }

  func start() throws {
    unlink(path)
    debugLog("starting socket server at \(path)")

    listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerFD >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    path.withCString { rawPath in
      withUnsafeMutablePointer(to: &address.sun_path) { rawPtr in
        let destination = UnsafeMutableRawPointer(rawPtr).assumingMemoryBound(to: CChar.self)
        strncpy(destination, rawPath, maxPathLength - 1)
      }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(listenerFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    guard listen(listenerFD, SOMAXCONN) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    queue.async { [self] in
      acceptLoop()
    }
  }

  private func acceptLoop() {
    while true {
      let clientFD = accept(listenerFD, nil, nil)
      if clientFD < 0 {
        if errno == EINTR { continue }
        break
      }
      var noSigPipe: Int32 = 1
      _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      debugLog("accepted client fd \(clientFD)")

      queue.async { [self] in
        handle(clientFD: clientFD)
      }
    }
  }

  private func handle(clientFD: Int32) {
    let requestData = readAll(from: clientFD)
    debugLog("read \(requestData.count) bytes from fd \(clientFD)")

    let decoder = JSONDecoder()
    if let request = try? decoder.decode(HelperRequest.self, from: requestData), request.method == "subscribeNowPlaying" {
      Task { [self] in
        await streamNowPlaying(clientFD: clientFD, requestID: request.id)
      }
      return
    }

    Task { [self] in
      let response = await process(requestData: requestData)
      debugLog("writing \(response.count) bytes to fd \(clientFD)")
      _ = writeAll(response, to: clientFD)
      shutdown(clientFD, SHUT_RDWR)
      close(clientFD)
    }
  }

  private func streamNowPlaying(clientFD: Int32, requestID: String) async {
    debugLog("starting now playing stream for fd \(clientFD)")
    let encoder = JSONEncoder()

    while true {
      let response: HelperResponse
      do {
        response = .ok(id: requestID, nowPlaying: try await service.nowPlaying())
      } catch let error as ServiceError {
        switch error {
          case .permissionDenied(let message):
            response = .failure(id: requestID, code: "permission_denied", message: message)
          case .notFound(let message):
            response = .failure(id: requestID, code: "not_found", message: message)
          case .invalidRequest(let message):
            response = .failure(id: requestID, code: "invalid_request", message: message)
        }
      } catch {
        response = .failure(id: requestID, code: "execution_failed", message: error.localizedDescription)
      }

      let intervalNs: UInt64
      if let nowPlaying = response.nowPlaying, nowPlaying.state == "playing" {
        intervalNs = 33_000_000
      } else {
        intervalNs = 180_000_000
      }

      let packet = lineEncoded(response, encoder: encoder)
      if !writeAll(packet, to: clientFD) {
        break
      }

      do {
        try await Task.sleep(nanoseconds: intervalNs)
      } catch {
        break
      }
    }

    debugLog("ending now playing stream for fd \(clientFD)")
    shutdown(clientFD, SHUT_RDWR)
    close(clientFD)
  }

  private func process(requestData: Data) async -> Data {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    let response: HelperResponse
    do {
      let request = try decoder.decode(HelperRequest.self, from: requestData)
      debugLog("processing method \(request.method)")
      switch request.method {
        case "ping":
          response = .ok(id: request.id)
        case "bootstrap":
          response = .ok(id: request.id, bootstrap: try await service.bootstrap())
        case "playlistTracks":
          guard let playlistId = request.playlistId else {
            throw ServiceError.invalidRequest("playlistId is required")
          }
          response = .ok(id: request.id, tracks: try await service.playlistTracks(id: playlistId))
        case "nowPlaying":
          response = .ok(id: request.id, nowPlaying: try await service.nowPlaying())
        case "playTrack":
          guard let trackId = request.trackId else {
            throw ServiceError.invalidRequest("trackId is required")
          }
          try await service.playTrack(
            id: trackId,
            playlistID: request.playlistId,
            startIndex: request.startIndex,
          )
          response = .ok(id: request.id)
        case "playpause":
          try await service.playpause()
          response = .ok(id: request.id)
        case "next":
          try await service.next()
          response = .ok(id: request.id)
        case "prev":
          try await service.prev()
          response = .ok(id: request.id)
        case "setShuffle":
          service.setShuffle(enabled: request.enabled ?? false)
          response = .ok(id: request.id)
        case "setRepeat":
          service.setRepeat(mode: request.repeatMode ?? "off")
          response = .ok(id: request.id)
        default:
          response = .failure(id: request.id, code: "invalid_method", message: "unknown helper method")
      }
    } catch let error as ServiceError {
      debugLog("service error: \(error)")
      switch error {
        case .permissionDenied(let message):
          response = .failure(id: "unknown", code: "permission_denied", message: message)
        case .notFound(let message):
          response = .failure(id: "unknown", code: "not_found", message: message)
        case .invalidRequest(let message):
          response = .failure(id: "unknown", code: "invalid_request", message: message)
      }
    } catch {
      debugLog("unexpected error: \(error)")
      response = .failure(id: "unknown", code: "execution_failed", message: error.localizedDescription)
    }

    return (try? encoder.encode(response)) ?? Data("{\"id\":\"unknown\",\"ok\":false}".utf8)
  }

  private func readAll(from fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)

    while true {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count > 0 {
        data.append(buffer, count: count)
        if data.last == 10 {
          break
        }
      } else {
        break
      }
    }

    if data.last == 10 {
      data.removeLast()
    }

    return data
  }

  private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      var sent = 0
      while sent < data.count {
        let result = send(fd, baseAddress.advanced(by: sent), data.count - sent, 0)
        if result <= 0 { return false }
        sent += result
      }
      return true
    }
  }
}

let arguments = ProcessInfo.processInfo.arguments
let socketPath: String
if let socketFlagIndex = arguments.firstIndex(of: "--socket"), socketFlagIndex + 1 < arguments.count {
  socketPath = arguments[socketFlagIndex + 1]
} else {
  socketPath = "/tmp/terminal-apple-music.sock"
}

do {
  let server = UnixSocketServer(path: socketPath)
  try server.start()
  dispatchMain()
} catch {
  fputs("helper failed: \(error)\n", stderr)
  exit(1)
}
