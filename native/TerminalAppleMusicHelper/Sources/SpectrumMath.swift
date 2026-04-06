import Foundation

let spectrumBinCount = 48
let spectrumFFTSize = 2048
let spectrumSignalFloor: Float = 0.00035

func buildSpectrumBins(from samples: [Float], sampleRate: Float) -> [Float] {
  guard samples.count >= 128 else {
    return Array(repeating: 0, count: spectrumBinCount)
  }

  let fftSize = largestPowerOfTwo(lessThanOrEqualTo: min(samples.count, spectrumFFTSize))
  guard fftSize >= 128 else {
    return Array(repeating: 0, count: spectrumBinCount)
  }

  let window = Array(samples.suffix(fftSize))
  let hann = hannWindow(count: fftSize)
  var real = Array(repeating: Float(0), count: fftSize)
  var imag = Array(repeating: Float(0), count: fftSize)

  for index in 0..<fftSize {
    real[index] = window[index] * hann[index]
  }

  forwardFFT(real: &real, imag: &imag)
  let magnitudes = positiveMagnitudes(real: real, imag: imag)
  let normalized = normalizeSpectrum(magnitudes, fftSize: fftSize)
  return makeLogBins(
    magnitudes: normalized,
    sampleRate: max(8_000, sampleRate),
  )
}

private func largestPowerOfTwo(lessThanOrEqualTo value: Int) -> Int {
  guard value > 0 else { return 0 }
  var result = 1
  while result << 1 <= value {
    result <<= 1
  }
  return result
}

private func hannWindow(count: Int) -> [Float] {
  if count <= 1 {
    return [1]
  }

  let denom = Float(count - 1)
  return (0..<count).map { index in
    0.5 - 0.5 * cos((2 * .pi * Float(index)) / denom)
  }
}

private func forwardFFT(real: inout [Float], imag: inout [Float]) {
  let count = real.count
  guard count > 1 else { return }

  var j = 0
  for i in 1..<count {
    var bit = count >> 1
    while j & bit != 0 {
      j ^= bit
      bit >>= 1
    }
    j ^= bit
    if i < j {
      real.swapAt(i, j)
      imag.swapAt(i, j)
    }
  }

  var length = 2
  while length <= count {
    let angle = -2 * Float.pi / Float(length)
    let wLenCos = cos(angle)
    let wLenSin = sin(angle)

    var start = 0
    while start < count {
      var wCos: Float = 1
      var wSin: Float = 0
      for offset in 0..<(length / 2) {
        let evenIndex = start + offset
        let oddIndex = evenIndex + length / 2

        let oddReal = real[oddIndex] * wCos - imag[oddIndex] * wSin
        let oddImag = real[oddIndex] * wSin + imag[oddIndex] * wCos
        let evenReal = real[evenIndex]
        let evenImag = imag[evenIndex]

        real[evenIndex] = evenReal + oddReal
        imag[evenIndex] = evenImag + oddImag
        real[oddIndex] = evenReal - oddReal
        imag[oddIndex] = evenImag - oddImag

        let nextCos = wCos * wLenCos - wSin * wLenSin
        let nextSin = wCos * wLenSin + wSin * wLenCos
        wCos = nextCos
        wSin = nextSin
      }
      start += length
    }

    length <<= 1
  }
}

private func positiveMagnitudes(real: [Float], imag: [Float]) -> [Float] {
  guard real.count == imag.count, real.count > 2 else { return [] }

  let half = real.count / 2
  var magnitudes = Array(repeating: Float(0), count: half)
  for index in 1..<half {
    let realValue = real[index]
    let imagValue = imag[index]
    magnitudes[index] = sqrt(realValue * realValue + imagValue * imagValue)
  }
  return magnitudes
}

private func normalizeSpectrum(_ magnitudes: [Float], fftSize: Int) -> [Float] {
  guard !magnitudes.isEmpty else { return [] }

  let scale = 2 / Float(max(1, fftSize))
  return magnitudes.map { magnitude in
    let adjusted = magnitude * scale
    return adjusted > spectrumSignalFloor ? adjusted : 0
  }
}

private func makeLogBins(magnitudes: [Float], sampleRate: Float) -> [Float] {
  guard magnitudes.count > 4 else {
    return Array(repeating: 0, count: spectrumBinCount)
  }

  var bins = Array(repeating: Float(0), count: spectrumBinCount)
  let nyquist = max(4_000, sampleRate / 2)
  let binWidth = nyquist / Float(magnitudes.count)
  let minFrequency: Float = 24
  let maxFrequency = min(nyquist, 16_000)
  let ratio = maxFrequency / minFrequency

  for index in bins.indices {
    let startFrequency = minFrequency * pow(ratio, Float(index) / Float(bins.count))
    let endFrequency = minFrequency * pow(ratio, Float(index + 1) / Float(bins.count))
    let start = max(1, Int(startFrequency / binWidth))
    let end = min(magnitudes.count, max(start + 1, Int(endFrequency / binWidth)))

    var weightedTotal: Float = 0
    var weightedSamples: Float = 0
    var peak: Float = 0

    if start < end {
      for spectrumIndex in start..<end {
        let frequency = Float(spectrumIndex) * binWidth
        let emphasis = spectralEmphasis(for: frequency)
        let value = magnitudes[spectrumIndex] * emphasis
        weightedTotal += value
        weightedSamples += emphasis
        peak = max(peak, value)
      }
    }

    let average = weightedTotal / max(1, weightedSamples)
    let shaped = min(1, pow(max(0, average) * 10.5 + peak * 4.2, 0.42))
    bins[index] = shaped
  }

  let maxValue = bins.max() ?? 0
  if maxValue > 0.0001 {
    for index in bins.indices {
      bins[index] = min(1, bins[index] / maxValue)
    }
  }

  return bins
}

private func spectralEmphasis(for frequency: Float) -> Float {
  if frequency < 80 {
    return 1.55
  }
  if frequency < 220 {
    return 1.25
  }
  if frequency < 2_000 {
    return 1.0
  }
  if frequency < 6_000 {
    return 1.16
  }
  return 1.28
}
