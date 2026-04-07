import { createConnection } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { NowPlaying, Playlist, RepeatMode, Track } from "./types"

type HelperMethod =
  | "ping"
  | "shutdown"
  | "bootstrap"
  | "playlistTracks"
  | "nowPlaying"
  | "subscribeNowPlaying"
  | "playTrack"
  | "playpause"
  | "next"
  | "prev"
  | "setShuffle"
  | "setRepeat"

interface HelperRequest {
  id: string
  method: HelperMethod
  playlistId?: string
  trackId?: string
  startIndex?: number
  enabled?: boolean
  repeatMode?: RepeatMode
}

interface HelperErrorPayload {
  code: string
  message: string
  detail?: string
}

interface BootstrapPayload {
  libraryTracks: Track[]
  playlists: Playlist[]
}

interface HelperResponse {
  id: string
  ok: boolean
  error?: HelperErrorPayload
  bootstrap?: BootstrapPayload
  tracks?: Track[]
  nowPlaying?: NowPlaying
}

export class MusicBridgeError extends Error {
  code: string
  detail: string

  constructor(code: string, message: string, detail = "") {
    super(message)
    this.name = "MusicBridgeError"
    this.code = code
    this.detail = detail
  }
}

const ROOT = join(import.meta.dir, "../..")
const SOCKET_PATH = join(tmpdir(), "terminal-apple-music.sock")
const HELPER_EXECUTABLE = join(
  ROOT,
  ".build-helper",
  "TerminalAppleMusicHelper.app",
  "Contents",
  "MacOS",
  "TerminalAppleMusicHelper",
)
const BUILD_SCRIPT = join(ROOT, "native", "TerminalAppleMusicHelper", "build-app.sh")

let helperProcess: Bun.Subprocess | null = null
let helperStartup: Promise<void> | null = null
let helperShutdownRegistered = false
let streamSocket: ReturnType<typeof createConnection> | null = null
let streamReconnectTimer: ReturnType<typeof setTimeout> | null = null
let streamActive = false
let streamConnectInFlight = false

function registerShutdown() {
  if (helperShutdownRegistered) return
  helperShutdownRegistered = true
  process.on("exit", () => {
    try { helperProcess?.kill() } catch {}
    try { streamSocket?.destroy() } catch {}
    clearStreamReconnect()
  })
}

async function findSocketHelperPids(): Promise<number[]> {
  const proc = Bun.spawn(["/bin/ps", "-axo", "pid=,command="], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "ignore",
  })

  const [stdout, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    proc.exited,
  ])

  if (exitCode !== 0) {
    return []
  }

  const pids = stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const match = line.match(/^(\d+)\s+(.*)$/)
      if (!match) return null
      const pidText = match[1] ?? ""
      const command = match[2] ?? ""
      const pid = Number.parseInt(pidText, 10)
      if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid) {
        return null
      }
      if (!command.includes(HELPER_EXECUTABLE) || !command.includes(`--socket ${SOCKET_PATH}`)) {
        return null
      }
      return pid
    })
    .filter((pid): pid is number => pid !== null)

  return [...new Set(pids)]
}

async function terminateHelperPid(pid: number) {
  try {
    process.kill(pid, "SIGTERM")
  } catch {}
}

async function buildHelperIfNeeded() {
  const proc = Bun.spawn(["/bin/zsh", BUILD_SCRIPT], {
    cwd: ROOT,
    env: {
      ...process.env,
      CLANG_MODULE_CACHE_PATH: "/tmp/clang-module-cache",
      SWIFT_MODULECACHE_PATH: "/tmp/swift-module-cache",
    },
    stdout: "pipe",
    stderr: "pipe",
  })

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])

  if (exitCode !== 0) {
    throw new MusicBridgeError(
      "build_failed",
      "native helper build failed",
      `${stdout}\n${stderr}`.trim(),
    )
  }
}

async function sendRaw(request: HelperRequest, timeoutMs = 15000): Promise<HelperResponse> {
  return await new Promise((resolve, reject) => {
    const socket = createConnection(SOCKET_PATH)
    let settled = false
    let data = ""
    const timeout = setTimeout(() => {
      socket.destroy()
      if (!settled) {
        settled = true
        reject(new MusicBridgeError("timeout", "helper request timed out"))
      }
    }, timeoutMs)

    socket.setEncoding("utf8")
    socket.on("connect", () => {
      socket.write(`${JSON.stringify(request)}\n`)
    })
    socket.on("data", (chunk) => {
      data += chunk
    })
    socket.on("error", (error) => {
      clearTimeout(timeout)
      if (!settled) {
        settled = true
        reject(new MusicBridgeError("connection_failed", "helper connection failed", String(error)))
      }
    })
    socket.on("end", () => {
      clearTimeout(timeout)
      if (settled) return
      settled = true
      try {
        resolve(JSON.parse(data) as HelperResponse)
      } catch (error) {
        reject(new MusicBridgeError("invalid_response", "helper returned invalid JSON", String(error)))
      }
    })
  })
}

async function pingHelper(): Promise<boolean> {
  try {
    const response = await sendRaw({
      id: crypto.randomUUID(),
      method: "ping",
    }, 1000)
    return response.ok
  } catch {
    return false
  }
}

async function ensureHelper() {
  registerShutdown()

  if (await pingHelper()) return
  if (helperStartup) {
    await helperStartup
    return
  }

  helperStartup = (async () => {
    await buildHelperIfNeeded()

    try { helperProcess?.kill() } catch {}
    helperProcess = Bun.spawn([HELPER_EXECUTABLE, "--socket", SOCKET_PATH, "--parent-pid", String(process.pid)], {
      cwd: ROOT,
      stdout: "ignore",
      stderr: "ignore",
    })
    ;(helperProcess as unknown as { unref?: () => void }).unref?.()

    const deadline = Date.now() + 15000
    while (Date.now() < deadline) {
      if (await pingHelper()) return
      await Bun.sleep(150)
    }

    throw new MusicBridgeError("startup_failed", "native helper failed to start")
  })()

  try {
    await helperStartup
  } finally {
    helperStartup = null
  }
}

async function request(method: HelperMethod, fields: Partial<HelperRequest> = {}) {
  await ensureHelper()
  const response = await sendRaw({
    id: crypto.randomUUID(),
    method,
    ...fields,
  })

  if (!response.ok) {
    const error = response.error
    throw new MusicBridgeError(
      error?.code ?? "request_failed",
      error?.message ?? "helper request failed",
      error?.detail ?? "",
    )
  }

  return response
}

export async function bootstrap(): Promise<BootstrapPayload> {
  const response = await request("bootstrap")
  if (!response.bootstrap) {
    throw new MusicBridgeError("invalid_response", "helper returned no bootstrap payload")
  }
  return response.bootstrap
}

export async function getPlaylistTracks(playlistId: string): Promise<Track[]> {
  const response = await request("playlistTracks", { playlistId })
  return response.tracks ?? []
}

export async function getNowPlaying(): Promise<NowPlaying> {
  const response = await request("nowPlaying")
  if (!response.nowPlaying) {
    throw new MusicBridgeError("invalid_response", "helper returned no now playing payload")
  }
  return response.nowPlaying
}

function clearStreamReconnect() {
  if (!streamReconnectTimer) return
  clearTimeout(streamReconnectTimer)
  streamReconnectTimer = null
}

export async function subscribeNowPlaying(onUpdate: (nowPlaying: NowPlaying) => void): Promise<() => void> {
  streamActive = true

  const connect = async () => {
    if (!streamActive || streamConnectInFlight) return
    streamConnectInFlight = true

    try {
      await ensureHelper()
      if (!streamActive) return

      const socket = createConnection(SOCKET_PATH)
      streamSocket = socket
      let buffer = ""

      socket.setEncoding("utf8")
      socket.on("connect", () => {
        socket.write(`${JSON.stringify({
          id: crypto.randomUUID(),
          method: "subscribeNowPlaying",
        } satisfies HelperRequest)}\n`)
      })

      socket.on("data", (chunk) => {
        buffer += chunk
        while (true) {
          const newlineIndex = buffer.indexOf("\n")
          if (newlineIndex === -1) break

          const line = buffer.slice(0, newlineIndex).trim()
          buffer = buffer.slice(newlineIndex + 1)
          if (!line) continue

          try {
            const response = JSON.parse(line) as HelperResponse
            if (!response.ok) continue
            if (response.nowPlaying) {
              onUpdate(response.nowPlaying)
            }
          } catch {}
        }
      })

      const scheduleReconnect = () => {
        if (!streamActive) return
        clearStreamReconnect()
        streamReconnectTimer = setTimeout(() => {
          void connect()
        }, 250)
      }

      socket.on("error", () => {
        if (streamSocket === socket) streamSocket = null
        scheduleReconnect()
      })

      socket.on("close", () => {
        if (streamSocket === socket) streamSocket = null
        scheduleReconnect()
      })
    } finally {
      streamConnectInFlight = false
    }
  }

  await connect()

  return () => {
    streamActive = false
    clearStreamReconnect()
    try { streamSocket?.destroy() } catch {}
    streamSocket = null
  }
}

export async function playTrackById(id: string, playlistId: string, startIndex: number): Promise<void> {
  await request("playTrack", { trackId: id, playlistId, startIndex })
}

export async function playpause(): Promise<void> {
  await request("playpause")
}

export async function next(): Promise<void> {
  await request("next")
}

export async function prev(): Promise<void> {
  await request("prev")
}

export async function setShuffle(enabled: boolean): Promise<void> {
  await request("setShuffle", { enabled })
}

export async function setRepeat(mode: RepeatMode): Promise<void> {
  await request("setRepeat", { repeatMode: mode })
}

export async function shutdown(): Promise<void> {
  streamActive = false
  clearStreamReconnect()
  try { streamSocket?.destroy() } catch {}
  streamSocket = null

  const trackedHelper = helperProcess
  helperProcess = null
  helperStartup = null

  if (await pingHelper()) {
    try {
      await sendRaw({
        id: crypto.randomUUID(),
        method: "shutdown",
      }, 750)
    } catch {}
  }

  if (trackedHelper) {
    try { trackedHelper.kill() } catch {}
    await Promise.race([
      trackedHelper.exited.then(() => undefined),
      Bun.sleep(500),
    ])
  }

  const socketHelperPids = await findSocketHelperPids()
  for (const pid of socketHelperPids) {
    await terminateHelperPid(pid)
  }
}
