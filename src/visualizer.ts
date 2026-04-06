const ACTIVE_CHARS = [" ", " ", ".", ".", ":", ":", "-", "=", "+", "*", "#", "%", "@", "@"]
const IDLE_CHARS = [" ", " ", ".", ".", ":", "-", "="]

type Ripple = {
  radius: number
  strength: number
  width: number
  speed: number
}

type Spike = {
  angle: number
  strength: number
  width: number
  drift: number
  ttl: number
}

const motion = {
  lastTick: -1,
  bass: 0,
  lowMid: 0,
  mids: 0,
  highs: 0,
  air: 0,
  shock: 0,
  sway: 0,
  ripples: [] as Ripple[],
  spikes: [] as Spike[],
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value))
}

function mix(from: number, to: number, amount: number): number {
  return from + (to - from) * amount
}

function averageBand(energy: number[], start: number, end: number): number {
  if (energy.length === 0) return 0
  const safeStart = clamp(start, 0, energy.length - 1)
  const safeEnd = clamp(end, safeStart + 1, energy.length)
  let total = 0
  let count = 0
  for (let index = safeStart; index < safeEnd; index++) {
    total += energy[index] ?? 0
    count++
  }
  return count > 0 ? total / count : 0
}

function sampleBins(energy: number[], normalizedAngle: number): number {
  if (energy.length === 0) return 0
  const scaled = normalizedAngle * energy.length
  const leftIndex = Math.floor(scaled) % energy.length
  const rightIndex = (leftIndex + 1) % energy.length
  const amount = scaled - Math.floor(scaled)
  const left = energy[leftIndex] ?? 0
  const right = energy[rightIndex] ?? left
  return left * (1 - amount) + right * amount
}

function angularDistance(a: number, b: number): number {
  const tau = Math.PI * 2
  let diff = Math.abs(a - b) % tau
  if (diff > Math.PI) diff = tau - diff
  return diff
}

function ellipseDistance(x: number, y: number, cx: number, cy: number, rx: number, ry: number): number {
  const dx = (x - cx) / rx
  const dy = (y - cy) / ry
  return Math.hypot(dx, dy) - 1
}

function baseCloudDistance(x: number, y: number, tick: number): number {
  const shear = motion.sway * 0.06
  const warpedX = x + Math.sin(y * 4.8 + tick * 0.013) * 0.018 + shear
  const warpedY = y + Math.cos(x * 4.1 - tick * 0.01) * 0.012

  const lobeA = ellipseDistance(warpedX, warpedY, -0.22, 0.01, 0.62, 0.37)
  const lobeB = ellipseDistance(warpedX, warpedY, 0.18, -0.02, 0.58, 0.33)
  const lower = ellipseDistance(warpedX, warpedY, 0.02, 0.26, 0.74, 0.24)
  const crest = ellipseDistance(warpedX, warpedY, 0.0, -0.26, 0.38, 0.16)
  const tail = ellipseDistance(warpedX, warpedY, 0.46, 0.14, 0.22, 0.16)

  return Math.min(lobeA, lobeB, lower, crest, tail)
}

function spawnRipple(strength: number, speed: number, width: number) {
  motion.ripples.push({
    radius: 0.12,
    strength: clamp(strength, 0.08, 1),
    width: clamp(width, 0.025, 0.11),
    speed: clamp(speed, 0.018, 0.07),
  })
  if (motion.ripples.length > 9) {
    motion.ripples.splice(0, motion.ripples.length - 9)
  }
}

function spawnSpike(strength: number, baseAngle: number) {
  motion.spikes.push({
    angle: baseAngle + (Math.random() - 0.5) * 0.16,
    strength: clamp(strength, 0.08, 1),
    width: 0.04 + Math.random() * 0.05,
    drift: (Math.random() - 0.5) * 0.025,
    ttl: 7 + Math.floor(Math.random() * 7),
  })
  if (motion.spikes.length > 16) {
    motion.spikes.splice(0, motion.spikes.length - 16)
  }
}

function advanceMotion(playing: boolean, tick: number, energy: number[]) {
  if (motion.lastTick === tick) return
  motion.lastTick = tick

  const bass = averageBand(energy, 0, 5)
  const lowMid = averageBand(energy, 5, 12)
  const mids = averageBand(energy, 12, 28)
  const highs = averageBand(energy, 28, 40)
  const air = averageBand(energy, 40, 48)

  if (!playing || energy.length === 0) {
    motion.bass *= 0.9
    motion.lowMid *= 0.9
    motion.mids *= 0.92
    motion.highs *= 0.88
    motion.air *= 0.84
    motion.shock *= 0.78
    motion.sway *= 0.9
  } else {
    const bassRise = Math.max(0, bass - motion.bass * 0.72)
    const kickRise = Math.max(0, bass * 1.18 + lowMid * 0.7 - motion.bass * 0.68 - motion.lowMid * 0.18 - 0.035)
    const highRise = Math.max(0, air + highs * 0.7 - motion.air * 0.72 - motion.highs * 0.24 - 0.016)

    motion.bass = mix(motion.bass, bass, bass > motion.bass ? 0.5 : 0.16)
    motion.lowMid = mix(motion.lowMid, lowMid, lowMid > motion.lowMid ? 0.4 : 0.18)
    motion.mids = mix(motion.mids, mids, mids > motion.mids ? 0.28 : 0.15)
    motion.highs = mix(motion.highs, highs, highs > motion.highs ? 0.52 : 0.2)
    motion.air = mix(motion.air, air, air > motion.air ? 0.56 : 0.24)
    motion.sway = mix(motion.sway, Math.sin(tick * 0.02 + mids * 5), 0.09)

    if (bassRise > 0.03) {
      spawnRipple(
        bassRise * 3.6 + bass * 0.55,
        0.02 + bass * 0.045,
        0.03 + lowMid * 0.05,
      )
    }

    if (kickRise > 0.05) {
      motion.shock = Math.max(motion.shock, clamp(kickRise * 2.8, 0.14, 1))
      spawnRipple(
        kickRise * 2.4,
        0.028 + kickRise * 0.05,
        0.024 + kickRise * 0.03,
      )
    } else {
      motion.shock *= 0.84
    }

    if (highRise > 0.026) {
      const anchors = [-2.55, -1.95, -1.42, -0.86, -0.18, 0.42, 1.06, 1.76, 2.45]
      const burstCount = 1 + Math.min(3, Math.floor(highRise * 18))
      for (let index = 0; index < burstCount; index++) {
        const anchor = anchors[Math.floor(Math.random() * anchors.length)] ?? 0
        spawnSpike(highRise * 2 + highs * 0.45, anchor)
      }
    }
  }

  motion.ripples = motion.ripples
    .map((ripple) => ({
      ...ripple,
      radius: ripple.radius + ripple.speed,
      strength: ripple.strength * 0.968,
      width: ripple.width * 1.008,
    }))
    .filter((ripple) => ripple.radius < 1.45 && ripple.strength > 0.02)

  motion.spikes = motion.spikes
    .map((spike) => ({
      ...spike,
      angle: spike.angle + spike.drift,
      strength: spike.strength * 0.89,
      ttl: spike.ttl - 1,
    }))
    .filter((spike) => spike.ttl > 0 && spike.strength > 0.04)
}

function rippleField(x: number, y: number): number {
  const sourceX = 0.02 + motion.sway * 0.06
  const sourceY = 0.18
  const distance = Math.hypot((x - sourceX) * 1.12, (y - sourceY) * 1.4)
  const lowerMask = clamp((y + 0.15) * 1.35, 0, 1)

  let total = 0
  for (const ripple of motion.ripples) {
    const wave = Math.exp(-((distance - ripple.radius) ** 2) / (2 * ripple.width * ripple.width))
    total += wave * ripple.strength * lowerMask
  }

  return total
}

function spikeLift(angle: number): number {
  let total = 0
  for (const spike of motion.spikes) {
    const distance = angularDistance(angle, spike.angle)
    const shape = Math.exp(-(distance * distance) / (2 * spike.width * spike.width))
    total += shape * spike.strength * 0.28
  }
  return total
}

export function renderCircle(
  w: number,
  h: number,
  playing: boolean,
  tick: number,
  energy: number[] = [],
): string[] {
  advanceMotion(playing, tick, energy)

  const width = Math.max(28, w)
  const height = Math.max(12, h)
  const grid = Array.from({ length: height }, () => Array.from({ length: width }, () => " "))
  const cx = (width - 1) / 2
  const cy = (height - 1) / 2 - 0.3
  const scaleX = Math.max(12, width * 0.42)
  const scaleY = Math.max(5, height * 0.45)

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const row = grid[y]!
      const nx = (x - cx) / scaleX
      const ny = (y - cy) / scaleY
      const angle = Math.atan2(ny, nx)
      const normalizedAngle = (angle + Math.PI) / (Math.PI * 2)
      const localEnergy = sampleBins(energy, normalizedAngle)
      const distance = baseCloudDistance(nx, ny, tick)
      const edgeFlares = spikeLift(angle)
      const rimWidth = 0.055 + motion.shock * 0.02 + localEnergy * 0.018
      const shell = Math.max(0, 1 - Math.abs(distance + edgeFlares) / rimWidth)
      const interior = Math.max(0, 1 - clamp((distance + 0.36) / 0.42, 0, 1))
      const rippleGlow = rippleField(nx, ny)
      const sourceX = 0.02 + motion.sway * 0.06
      const sourceY = 0.18
      const dropDistance = Math.hypot((nx - sourceX) * 1.08, (ny - sourceY) * 1.35)
      const kickCore = Math.exp(-(dropDistance * dropDistance) / (2 * 0.06 * 0.06)) * motion.shock * 1.6
      const shockRing =
        Math.exp(-((dropDistance - (0.16 + motion.shock * 0.22)) ** 2) / (2 * (0.032 + motion.shock * 0.018) ** 2))
        * motion.shock
        * 1.2
      const mist =
        Math.sin(nx * 7.2 + tick * 0.018)
        + Math.cos(ny * 8.8 - tick * 0.013)
        + Math.sin((nx - ny) * 5.4 + tick * 0.011)
      const edgeMist = Math.max(0, 1 - Math.abs(distance - 0.07) / 0.18) * (motion.air * 0.28 + motion.highs * 0.12)
      const centerVoid = Math.max(0, 1 - Math.hypot(nx * 1.05, ny * 1.2) / 0.22) * 0.18
      const leftPocket = Math.exp(-((((nx + 0.22) / 0.16) ** 2) + (((ny + 0.02) / 0.13) ** 2))) * 0.18
      const rightPocket = Math.exp(-((((nx - 0.16) / 0.15) ** 2) + (((ny + 0.01) / 0.12) ** 2))) * 0.13
      const crownBite = Math.exp(-((((nx + motion.sway * 0.03) / 0.24) ** 2) + (((ny + 0.28) / 0.09) ** 2))) * 0.16
      const centerChannel = Math.exp(-((((nx - motion.sway * 0.02) / 0.11) ** 2) + (((ny - 0.02) / 0.19) ** 2))) * 0.12
      const lowerWindow = Math.exp(-((((nx + 0.01) / 0.2) ** 2) + (((ny - 0.2) / 0.1) ** 2))) * 0.1
      const grain = Math.sin((nx * 13 - ny * 9) + tick * 0.035 + angle * 3) * 0.04

      const density =
        shell * 0.92
        + interior * 0.08
        + rippleGlow * 1.05
        + kickCore
        + shockRing
        + edgeMist
        + mist * 0.03
        + grain
        - centerVoid
        - leftPocket
        - rightPocket
        - crownBite
        - centerChannel
        - lowerWindow

      if (density <= 0.02) continue

      if (!playing) {
        const index = clamp(Math.floor(density * (IDLE_CHARS.length - 1)), 0, IDLE_CHARS.length - 1)
        row[x] = IDLE_CHARS[index] ?? " "
        continue
      }

      const index = clamp(Math.floor(density * (ACTIVE_CHARS.length - 1)), 0, ACTIVE_CHARS.length - 1)
      row[x] = ACTIVE_CHARS[index] ?? " "
    }
  }

  return grid.map((row) => row.join(""))
}
