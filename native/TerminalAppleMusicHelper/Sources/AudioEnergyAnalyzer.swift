import Foundation
import CoreAudio

private let analyzerSampleCapacity = 8192

struct AudioAnalysisSnapshot: Sendable {
  let bins: [Double]
  let source: String
}

enum AudioAnalyzerError: Error, CustomStringConvertible {
  case status(String, OSStatus)

  var description: String {
    switch self {
      case .status(let operation, let status):
        "\(operation) failed (\(statusDescription(status)))"
    }
  }
}

func statusDescription(_ status: OSStatus) -> String {
  let code = UInt32(bitPattern: status)
  let bytes = [
    UInt8((code >> 24) & 0xff),
    UInt8((code >> 16) & 0xff),
    UInt8((code >> 8) & 0xff),
    UInt8(code & 0xff),
  ]
  let isPrintable = bytes.allSatisfy { (32...126).contains($0) }
  if isPrintable, let fourCC = String(bytes: bytes, encoding: .ascii) {
    return "\(status) / '\(fourCC)'"
  }
  return "\(status)"
}

private func requireNoErr(_ status: OSStatus, _ operation: String) throws {
  guard status == noErr else {
    throw AudioAnalyzerError.status(operation, status)
  }
}

private func scalarProperty<T>(
  objectID: AudioObjectID,
  selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
  as type: T.Type,
) throws -> T {
  var address = AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: scope,
    mElement: element,
  )
  var size = UInt32(MemoryLayout<T>.size)
  let storage = UnsafeMutableRawPointer.allocate(
    byteCount: MemoryLayout<T>.size,
    alignment: MemoryLayout<T>.alignment,
  )
  defer { storage.deallocate() }

  try requireNoErr(
    AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage),
    "AudioObjectGetPropertyData(\(selector))",
  )
  return storage.load(as: T.self)
}

private func stringProperty(
  objectID: AudioObjectID,
  selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
) throws -> String {
  var address = AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: scope,
    mElement: element,
  )
  var value: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  try requireNoErr(
    withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    },
    "AudioObjectGetPropertyData(\(selector))",
  )
  guard let value else {
    throw AudioAnalyzerError.status("missing CFString for selector \(selector)", -1)
  }
  return value.takeRetainedValue() as String
}

final class AudioEnergyAnalyzer: @unchecked Sendable {
  private let callbackQueue = DispatchQueue(label: "terminal-apple-music.helper.audio")
  private let lock = NSLock()
  private var tapID: AudioObjectID = kAudioObjectUnknown
  private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
  private var ioProcID: AudioDeviceIOProcID?
  private var lastStartAttempt = Date.distantPast
  private var started = false
  private var lastError: String?
  private var ringBuffer = Array(repeating: Float(0), count: analyzerSampleCapacity)
  private var writeIndex = 0
  private var sampleCount = 0
  private var smoothedBins = Array(repeating: Float(0), count: spectrumBinCount)
  private var lastSampleAt = Date.distantPast
  private var lastSignalAt = Date.distantPast
  private var sampleRate: Float = 44_100
  private var loggedFirstCallback = false
  private var loggedEmptyInput = false
  private var loggedUnsupportedFormat = false
  private var lastPeakLogAt = Date.distantPast

  deinit {
    stop()
  }

  func startIfNeeded() {
    lock.lock()
    if started || Date().timeIntervalSince(lastStartAttempt) < 5 {
      lock.unlock()
      return
    }
    lastStartAttempt = Date()
    lock.unlock()

    do {
      try startCapture()
      lock.lock()
      started = true
      lastError = nil
      lock.unlock()
    } catch {
      let message = String(describing: error)
      lock.lock()
      lastError = message
      lock.unlock()
      debugLog("audio analyzer unavailable: \(message)")
    }
  }

  func snapshot() -> AudioAnalysisSnapshot {
    lock.lock()
    defer { lock.unlock() }

    let now = Date()
    let age = now.timeIntervalSince(lastSampleAt)
    if sampleCount == 0 {
      decayBins(factor: 0.92)
      return AudioAnalysisSnapshot(bins: smoothedBins.map { Double($0) }, source: "idle")
    }

    let frameCount = min(sampleCount, ringBuffer.count)
    let recentSamples = copyRecentSamples(count: frameCount)
    let targets = buildSpectrumBins(from: recentSamples, sampleRate: sampleRate)

    for index in smoothedBins.indices {
      let target = targets[index]
      let blend: Float = target > smoothedBins[index] ? 0.58 : 0.18
      smoothedBins[index] += (target - smoothedBins[index]) * blend
    }

    if age > 0.18 {
      let decay = max(0.58, Float(1 - min(age, 1.2) * 0.55))
      decayBins(factor: decay)
    }

    let source = now.timeIntervalSince(lastSignalAt) < 0.35 ? "fft" : "idle"
    return AudioAnalysisSnapshot(
      bins: smoothedBins.map { Double(min(max($0, 0), 1)) },
      source: source,
    )
  }

  private func decayBins(factor: Float) {
    for index in smoothedBins.indices {
      smoothedBins[index] *= factor
    }
  }

  private func startCapture() throws {
    guard #available(macOS 14.2, *) else {
      throw AudioAnalyzerError.status("Audio taps require macOS 14.2", -1)
    }

    var createdTapID = AudioObjectID(kAudioObjectUnknown)
    var createdAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    var createdIOProcID: AudioDeviceIOProcID?

    do {
      let outputDeviceID = try scalarProperty(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultOutputDevice,
        as: AudioObjectID.self,
      )
      let outputDeviceUID = try stringProperty(
        objectID: outputDeviceID,
        selector: kAudioDevicePropertyDeviceUID,
      )
      let description = CATapDescription(
        __excludingProcesses: [],
        andDeviceUID: outputDeviceUID,
        withStream: 0,
      )
      description.name = "Terminal Apple Music Visualizer"
      description.isPrivate = true
      description.muteBehavior = .unmuted

      try requireNoErr(
        AudioHardwareCreateProcessTap(description, &createdTapID),
        "AudioHardwareCreateProcessTap",
      )

      let tapUID = try stringProperty(objectID: createdTapID, selector: kAudioTapPropertyUID)
      let format = try scalarProperty(
        objectID: createdTapID,
        selector: kAudioTapPropertyFormat,
        as: AudioStreamBasicDescription.self,
      )

      let aggregateDescription: [String: Any] = [
        "uid": "com.jow.terminal-apple-music.visualizer.\(UUID().uuidString)",
        "name": "Terminal Apple Music Visualizer",
        "private": 1,
        "tapautostart": 1,
        "taps": [[
          "uid": tapUID,
          "drift": 0,
        ]],
      ]

      try requireNoErr(
        AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateDeviceID),
        "AudioHardwareCreateAggregateDevice",
      )

      try requireNoErr(
        AudioDeviceCreateIOProcIDWithBlock(
          &createdIOProcID,
          createdAggregateDeviceID,
          callbackQueue,
        ) { [weak self] _, inputData, _, outputData, _ in
          guard let self else { return }
          self.consume(
            inputBufferList: inputData,
            outputBufferList: outputData,
            format: format,
          )
        },
        "AudioDeviceCreateIOProcIDWithBlock",
      )

      try requireNoErr(
        AudioDeviceStart(createdAggregateDeviceID, createdIOProcID),
        "AudioDeviceStart",
      )

      lock.lock()
      tapID = createdTapID
      aggregateDeviceID = createdAggregateDeviceID
      ioProcID = createdIOProcID
      lock.unlock()

      debugLog(
        "audio analyzer started: deviceUID=\(outputDeviceUID) format=\(format.mSampleRate)Hz channels=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel) flags=\(format.mFormatFlags)"
      )
    } catch {
      if createdAggregateDeviceID != kAudioObjectUnknown {
        _ = AudioHardwareDestroyAggregateDevice(createdAggregateDeviceID)
      }
      if createdTapID != kAudioObjectUnknown {
        _ = AudioHardwareDestroyProcessTap(createdTapID)
      }
      throw error
    }
  }

  private func stop() {
    lock.lock()
    let deviceID = aggregateDeviceID
    let tap = tapID
    let procID = ioProcID
    aggregateDeviceID = kAudioObjectUnknown
    tapID = kAudioObjectUnknown
    ioProcID = nil
    started = false
    lock.unlock()

    if deviceID != kAudioObjectUnknown, let procID {
      _ = AudioDeviceStop(deviceID, procID)
      _ = AudioDeviceDestroyIOProcID(deviceID, procID)
      _ = AudioHardwareDestroyAggregateDevice(deviceID)
    }
    if #available(macOS 14.2, *), tap != kAudioObjectUnknown {
      _ = AudioHardwareDestroyProcessTap(tap)
    }
  }

  private func consume(
    inputBufferList: UnsafePointer<AudioBufferList>,
    outputBufferList: UnsafeMutablePointer<AudioBufferList>?,
    format: AudioStreamBasicDescription,
  ) {
    let inputBytes = totalBytes(in: inputBufferList)
    let outputBytes = outputBufferList.map { totalBytes(in: UnsafePointer($0)) } ?? 0
    let selectedBufferList: UnsafePointer<AudioBufferList> =
      outputBytes > inputBytes
        ? UnsafePointer(outputBufferList!)
        : inputBufferList

    if debugEnabled && !loggedFirstCallback {
      loggedFirstCallback = true
      debugLog(
        "audio callback received: inputBytes=\(inputBytes) outputBytes=\(outputBytes) using=\(outputBytes > inputBytes ? "output" : "input")"
      )
    }
    let samples = extractMonoSamples(from: selectedBufferList, format: format)
    guard !samples.isEmpty else { return }

    if debugEnabled, Date().timeIntervalSince(lastPeakLogAt) > 1 {
      lastPeakLogAt = Date()
      let peak = samples.reduce(Float(0)) { current, sample in
        max(current, abs(sample))
      }
      debugLog("audio samples decoded: count=\(samples.count) peak=\(peak)")
    }

    lock.lock()
    defer { lock.unlock() }

    for sample in samples {
      ringBuffer[writeIndex] = sample
      writeIndex = (writeIndex + 1) % ringBuffer.count
    }
    sampleCount = min(ringBuffer.count, sampleCount + samples.count)
    sampleRate = Float(format.mSampleRate)
    lastSampleAt = Date()
    let peak = samples.reduce(Float(0)) { current, sample in
      max(current, abs(sample))
    }
    if peak >= spectrumSignalFloor {
      lastSignalAt = lastSampleAt
    }
  }

  private func totalBytes(in bufferList: UnsafePointer<AudioBufferList>) -> Int {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    return buffers.reduce(0) { partialResult, buffer in
      partialResult + Int(buffer.mDataByteSize)
    }
  }

  private func copyRecentSamples(count: Int) -> [Float] {
    guard count > 0 else { return [] }
    let safeCount = min(count, ringBuffer.count)
    let startIndex = (writeIndex - safeCount + ringBuffer.count) % ringBuffer.count
    if startIndex + safeCount <= ringBuffer.count {
      return Array(ringBuffer[startIndex..<startIndex + safeCount])
    }
    let head = ringBuffer[startIndex...]
    let tailCount = safeCount - head.count
    return Array(head) + Array(ringBuffer[..<tailCount])
  }

  private func extractMonoSamples(
    from bufferList: UnsafePointer<AudioBufferList>,
    format: AudioStreamBasicDescription,
  ) -> [Float] {
    guard format.mFormatID == kAudioFormatLinearPCM else {
      if debugEnabled && !loggedUnsupportedFormat {
        loggedUnsupportedFormat = true
        debugLog("audio analyzer unsupported format id \(format.mFormatID)")
      }
      return []
    }

    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard !buffers.isEmpty else {
      if debugEnabled && !loggedEmptyInput {
        loggedEmptyInput = true
        debugLog("audio analyzer received no buffers")
      }
      return []
    }

    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
    let channelCount = max(1, Int(format.mChannelsPerFrame))

    guard isFloat || isSignedInteger else {
      if debugEnabled && !loggedUnsupportedFormat {
        loggedUnsupportedFormat = true
        debugLog(
          "audio analyzer unsupported pcm flags=\(format.mFormatFlags) bits=\(format.mBitsPerChannel)"
        )
      }
      return []
    }

    if isNonInterleaved {
      guard let firstData = buffers.first?.mData else { return [] }
      let frameCount = Int(buffers[0].mDataByteSize) / bytesPerSample
      guard frameCount > 0 else { return [] }
      var mono = Array(repeating: Float(0), count: frameCount)

      for channel in 0..<min(channelCount, buffers.count) {
        let buffer = buffers[channel]
        guard let data = buffer.mData else { continue }
        for frame in 0..<frameCount {
          mono[frame] += sampleValue(
            baseAddress: data,
            index: frame,
            bytesPerSample: bytesPerSample,
            isFloat: isFloat,
          )
        }
      }

      let divisor = Float(max(1, min(channelCount, buffers.count)))
      if divisor > 1 {
        for index in mono.indices {
          mono[index] /= divisor
        }
      }
      _ = firstData
      return mono
    }

    let buffer = buffers[0]
    guard let data = buffer.mData else { return [] }
    let bytesPerFrame = max(1, Int(format.mBytesPerFrame))
    let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
    guard frameCount > 0 else { return [] }
    var mono = Array(repeating: Float(0), count: frameCount)

    for frame in 0..<frameCount {
      var total: Float = 0
      for channel in 0..<channelCount {
        total += sampleValue(
          baseAddress: data,
          index: frame * channelCount + channel,
          bytesPerSample: bytesPerSample,
          isFloat: isFloat,
        )
      }
      mono[frame] = total / Float(channelCount)
    }

    return mono
  }

  private func sampleValue(
    baseAddress: UnsafeMutableRawPointer,
    index: Int,
    bytesPerSample: Int,
    isFloat: Bool,
  ) -> Float {
    if isFloat {
      switch bytesPerSample {
        case 4:
          let pointer = baseAddress.assumingMemoryBound(to: Float.self)
          return pointer[index]
        case 8:
          let pointer = baseAddress.assumingMemoryBound(to: Double.self)
          return Float(pointer[index])
        default:
          return 0
      }
    }

    switch bytesPerSample {
      case 2:
        let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
        return Float(pointer[index]) / Float(Int16.max)
      case 4:
        let pointer = baseAddress.assumingMemoryBound(to: Int32.self)
        return Float(pointer[index]) / Float(Int32.max)
      default:
        return 0
    }
  }
}
