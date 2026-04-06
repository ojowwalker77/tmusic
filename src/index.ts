import { createCliRenderer, Box, Text, type KeyEvent } from "@opentui/core"
import { createState } from "./state"
import { cache } from "./music/cache"
import { MusicBridgeError } from "./music/bridge"
import * as bridge from "./music/bridge"
import { renderCircle } from "./visualizer"

const FG = "#e8e4df"
const DIM = "#6f6a66"
const SOFT = "#96908b"
const ACCENT = "#d9d5d1"
const HIGHLIGHT = "#ffffff"
const PLAYING_FG = "#f0ece7"

const renderer = await createCliRenderer({ exitOnCtrlC: false })
const state = createState()
let w = process.stdout.columns || 80
let h = process.stdout.rows || 24
let tick = 0
let playlistPickerOpen = false
let playlistPickerSelection = 0
let stopNowPlayingStream: (() => void) | null = null
let animTimer: ReturnType<typeof setTimeout> | null = null

function formatTime(s: number): string {
  const m = Math.floor(s / 60)
  const sec = Math.floor(s % 60)
  return `${m}:${sec.toString().padStart(2, "0")}`
}

function pad(s: string, len: number): string {
  if (len <= 0) return ""
  return s.length > len ? s.slice(0, len - 1) + "…" : s.padEnd(len)
}

function cycleRepeatMode() {
  state.nowPlaying.repeatMode =
    state.nowPlaying.repeatMode === "off"
      ? "all"
      : state.nowPlaying.repeatMode === "all"
        ? "one"
        : "off"
}

function repeatLabel() {
  switch (state.nowPlaying.repeatMode) {
    case "all":
      return "repeat all"
    case "one":
      return "repeat one"
    default:
      return "repeat off"
  }
}

function statusLabel() {
  if (state.nowPlaying.state === "playing") return "Now playing"
  if (state.nowPlaying.state === "paused") return "Paused"
  if (playlistPickerOpen) return "Choose playlist"
  if (state.playlistStatus === "loading") return "Loading playlist"
  if (state.libraryStatus === "loading") return "Loading library"
  if (state.playlistStatus === "error" || state.libraryStatus === "error") return "Music unavailable"
  return "Pick a song"
}

function describeBridgeError(error: unknown): string {
  if (error instanceof MusicBridgeError) {
    return error.message
  }

  if (error instanceof Error && error.message) {
    return error.message
  }

  return "music bridge failed"
}

function permissionHint(message: string | null): string | null {
  if (!message) return null
  if (message.includes("access denied") || message.includes("authorization")) {
    return "approve music access when macOS prompts for it"
  }
  if (message.includes("build failed")) {
    return "check the native helper build and signing output"
  }
  return null
}

function getTrackListMessage(): { message: string | null; hint: string | null } {
  if (playlistPickerOpen) {
    return {
      message: state.playlists.length === 0 ? "no playlists found" : null,
      hint: null,
    }
  }

  if (state.playlistStatus === "loading") {
    return { message: "loading playlist...", hint: null }
  }

  if (state.playlistStatus === "error") {
    return {
      message: state.playlistError ?? "playlist load failed",
      hint: permissionHint(state.playlistError),
    }
  }

  if (state.libraryStatus === "loading") {
    return { message: "loading songs...", hint: null }
  }

  if (state.libraryStatus === "error") {
    return {
      message: state.libraryError ?? "music bridge failed",
      hint: permissionHint(state.libraryError),
    }
  }

  if (state.tracks.length === 0) {
    return { message: "library is empty", hint: null }
  }

  return { message: null, hint: null }
}

async function playTrackAt(index: number) {
  const track = state.tracks[index]
  const playlist = state.playlists[state.currentPlaylist]
  if (!track || !playlist) return

  state.trackSelection = index
  try {
    await bridge.playTrackById(track.id, playlist.id, index)
  } catch {}
  render()
}

function render() {
  const existingMain = renderer.root.getRenderable("main")
  if (existingMain && !existingMain.isDestroyed) {
    existingMain.destroyRecursively()
  }

  const panelWidth = Math.max(40, w)
  const panelHeight = Math.max(14, h)
  const listWidth = Math.max(28, Math.min(38, Math.floor(panelWidth * 0.29)))
  const visualWidth = Math.max(28, panelWidth - listWidth - 5)
  const bodyHeight = Math.max(7, panelHeight - 6)
  const visibleRows = Math.max(4, bodyHeight - 3)

  if (!playlistPickerOpen && state.tracks.length > 0) {
    state.trackSelection = Math.max(0, Math.min(state.trackSelection, state.tracks.length - 1))
    if (state.trackSelection < state.scrollOffset) state.scrollOffset = state.trackSelection
    if (state.trackSelection >= state.scrollOffset + visibleRows) {
      state.scrollOffset = state.trackSelection - visibleRows + 1
    }
  } else if (!playlistPickerOpen) {
    state.trackSelection = 0
    state.scrollOffset = 0
  }

  const playlistName = state.playlists[state.currentPlaylist]?.name ?? "Library"
  const { message: trackListMessage, hint } = getTrackListMessage()
  const trackListChildren: any[] = [
    Box(
      {
        width: "100%",
        height: 1,
        onMouseDown: () => {
          playlistPickerSelection = state.currentPlaylist
          playlistPickerOpen = !playlistPickerOpen
          render()
        },
      } as any,
      Text({ content: `Playlist: ${playlistName} ${playlistPickerOpen ? "x" : "v"}`, fg: ACCENT }),
    ),
    Box({ width: "100%", height: 1 }),
  ]

  if (playlistPickerOpen) {
    const start = Math.max(0, Math.min(playlistPickerSelection, Math.max(0, state.playlists.length - visibleRows)))
    const slice = state.playlists.slice(start, start + visibleRows)

    for (let i = 0; i < visibleRows; i++) {
      const playlistIndex = start + i
      const playlist = slice[i]

      if (!playlist) {
        if (i === 0 && trackListMessage) {
          trackListChildren.push(Text({ content: pad(trackListMessage, listWidth - 1), fg: SOFT }))
        } else {
          trackListChildren.push(Box({ width: "100%", height: 1 }))
        }
        continue
      }

      const selected = playlistIndex === playlistPickerSelection
      trackListChildren.push(
        Box(
          {
            width: "100%",
            height: 1,
            onMouseDown: () => {
              playlistPickerOpen = false
              void loadPlaylistTracks(playlistIndex)
            },
          } as any,
          Text({
            content: `${selected ? ">" : " "} ${pad(playlist.name, listWidth - 4)}`,
            fg: selected ? HIGHLIGHT : FG,
          }),
        ),
      )
    }
  } else {
    const slice = state.tracks.slice(state.scrollOffset, state.scrollOffset + visibleRows)
    for (let i = 0; i < visibleRows; i++) {
      const trackIdx = state.scrollOffset + i
      const track = slice[i]

      if (!track) {
        if (i === 0 && trackListMessage) {
          trackListChildren.push(Text({ content: pad(trackListMessage, listWidth - 1), fg: SOFT }))
        } else if (i === 1 && hint) {
          trackListChildren.push(Text({ content: pad(hint, listWidth - 1), fg: DIM }))
        } else {
          trackListChildren.push(Box({ width: "100%", height: 1 }))
        }
        continue
      }

      const selected = trackIdx === state.trackSelection
      const isCurrentTrack = state.nowPlaying.track?.id === track.id
      const fg = selected ? HIGHLIGHT : isCurrentTrack ? PLAYING_FG : FG
      const prefix = selected ? ">" : isCurrentTrack ? "*" : " "

      trackListChildren.push(
        Box(
          {
            width: "100%",
            height: 1,
            onMouseDown: () => {
              void playTrackAt(trackIdx)
            },
          } as any,
          Text({
            content: `${prefix} ${pad(track.name, listWidth - 4)}`,
            fg,
          }),
        ),
      )
    }
  }

  const trackList = Box(
    {
      flexDirection: "column",
      width: listWidth,
      height: bodyHeight,
      paddingTop: 1,
      paddingRight: 2,
    },
    ...trackListChildren,
  )

  const vizH = Math.max(12, bodyHeight - 1)
  const vizW = Math.max(36, visualWidth - 1)
  const circleLines = renderCircle(
    vizW,
    vizH,
    state.nowPlaying.state === "playing",
    tick,
    state.nowPlaying.energy,
  )

  const visualizer = Box(
    {
      flexDirection: "column",
      width: visualWidth,
      height: bodyHeight,
      justifyContent: "center",
      alignItems: "center",
      paddingTop: 1,
    },
    ...circleLines.map((line) => Text({ content: line, fg: SOFT })),
  )

  const content = Box(
    {
      flexDirection: "row",
      width: "100%",
      height: bodyHeight,
      columnGap: 4,
      paddingLeft: 2,
      paddingRight: 2,
      paddingTop: 1,
    },
    trackList,
    visualizer,
  )

  const np = state.nowPlaying
  const stateIcon = np.state === "playing" ? "pause" : "play"
  const progressWidth = Math.max(panelWidth - 38, 12)
  const progress = np.track && np.track.duration > 0 ? np.position / np.track.duration : 0
  const filled = Math.round(progress * progressWidth)
  const bar = `${"=".repeat(Math.max(0, filled))}o${".".repeat(Math.max(0, progressWidth - filled - 1))}`
  const timeStr = np.track ? `${formatTime(np.position)} / ${formatTime(np.track.duration)}` : "0:00 / 0:00"

  const bottomBar = Box(
    {
      flexDirection: "column",
      width: "100%",
      height: 5,
      paddingTop: 1,
      paddingLeft: 3,
      paddingRight: 3,
    },
    Box(
      { flexDirection: "row", width: "100%", height: 1 },
      Box(
        {
          onMouseDown: () => {
            bridge.playpause()
            render()
          },
        } as any,
        Text({ content: stateIcon, fg: ACCENT }),
      ),
      Text({ content: `  ${bar}  `, fg: SOFT }),
      Text({ content: timeStr, fg: SOFT }),
    ),
    Box({ width: "100%", height: 1 }),
    Box(
      { flexDirection: "row", width: "100%", height: 1, justifyContent: "space-between" },
      Text({
        content: np.track ? pad(np.track.name, Math.max(18, listWidth + 12)) : "nothing queued",
        fg: FG,
      }),
      Box(
        { flexDirection: "row", gap: 4 },
        Box(
          {
            onMouseDown: () => { bridge.prev() },
          } as any,
          Text({ content: "prev", fg: SOFT }),
        ),
        Box(
          {
            onMouseDown: () => {
              state.nowPlaying.shuffleEnabled = !state.nowPlaying.shuffleEnabled
              bridge.setShuffle(state.nowPlaying.shuffleEnabled)
              render()
            },
          } as any,
          Text({
            content: np.shuffleEnabled ? "shuffle on" : "shuffle off",
            fg: np.shuffleEnabled ? HIGHLIGHT : SOFT,
          }),
        ),
        Box(
          {
            onMouseDown: () => {
              cycleRepeatMode()
              bridge.setRepeat(state.nowPlaying.repeatMode)
              render()
            },
          } as any,
          Text({ content: repeatLabel(), fg: np.repeatMode === "off" ? SOFT : HIGHLIGHT }),
        ),
        Box(
          {
            onMouseDown: () => { bridge.next() },
          } as any,
          Text({ content: "next", fg: SOFT }),
        ),
      ),
    ),
  )

  const main = Box(
    {
      id: "main",
      width: "100%",
      height: "100%",
      flexDirection: "column",
    },
    content,
    bottomBar,
  )

  renderer.root.add(main)
}

async function loadPlaylistTracks(idx: number) {
  const pl = state.playlists[idx]
  if (!pl) return

  state.currentPlaylist = idx
  state.playlistStatus = "loading"
  state.playlistError = null
  render()

  try {
    state.tracks = pl.id === "library" ? cache.tracks : await bridge.getPlaylistTracks(pl.id)
    state.trackSelection = 0
    state.scrollOffset = 0
    state.playlistStatus = "ready"
  } catch (error) {
    state.playlistStatus = "error"
    state.playlistError = describeBridgeError(error)
  }

  render()
}

renderer.keyInput.on("keypress", async (key: KeyEvent) => {
  if (playlistPickerOpen) {
    if (key.name === "escape") {
      playlistPickerOpen = false
      playlistPickerSelection = state.currentPlaylist
      render()
      return
    }
    if (key.name === "j" || key.name === "down") {
      playlistPickerSelection = Math.min(state.playlists.length - 1, playlistPickerSelection + 1)
      render()
      return
    }
    if (key.name === "k" || key.name === "up") {
      playlistPickerSelection = Math.max(0, playlistPickerSelection - 1)
      render()
      return
    }
    if (key.name === "return") {
      playlistPickerOpen = false
      await loadPlaylistTracks(playlistPickerSelection)
      return
    }
    return
  }

  if (key.ctrl && key.name === "c") {
    cleanup()
    renderer.destroy()
    process.exit(0)
  }
  if (key.name === "q") {
    cleanup()
    renderer.destroy()
    process.exit(0)
  }

  switch (key.name) {
    case "j":
    case "down":
      state.trackSelection = Math.min(state.tracks.length - 1, state.trackSelection + 1)
      render()
      break
    case "k":
    case "up":
      state.trackSelection = Math.max(0, state.trackSelection - 1)
      render()
      break
    case "return":
      await playTrackAt(state.trackSelection)
      break
    case "space":
      await bridge.playpause()
      break
    case "n":
      await bridge.next()
      break
    case "p":
      if (key.shift) {
        playlistPickerSelection = state.currentPlaylist
        playlistPickerOpen = true
        render()
      } else {
        await bridge.prev()
      }
      break
    case "s":
      state.nowPlaying.shuffleEnabled = !state.nowPlaying.shuffleEnabled
      await bridge.setShuffle(state.nowPlaying.shuffleEnabled)
      render()
      break
    case "r":
      cycleRepeatMode()
      await bridge.setRepeat(state.nowPlaying.repeatMode)
      render()
      break
    case "g":
      if (key.shift) {
        state.trackSelection = state.tracks.length - 1
      } else {
        state.trackSelection = 0
      }
      render()
      break
    case "tab":
      playlistPickerSelection = state.currentPlaylist
      playlistPickerOpen = !playlistPickerOpen
      render()
      break
  }
})

renderer.on("resize", (nw: number, nh: number) => {
  w = nw
  h = nh
  render()
})

function animLoop() {
  tick++
  render()
  animTimer = setTimeout(animLoop, state.nowPlaying.state === "playing" ? 33 : 220)
}

function cleanup() {
  if (animTimer) {
    clearTimeout(animTimer)
    animTimer = null
  }

  try { stopNowPlayingStream?.() } catch {}
  stopNowPlayingStream = null

  const existingMain = renderer.root.getRenderable("main")
  if (existingMain && !existingMain.isDestroyed) {
    existingMain.destroyRecursively()
  }
}

async function main() {
  state.libraryStatus = "loading"
  state.playlistStatus = "idle"
  state.tracks = []
  render()

  try {
    await cache.load()
    state.playlists = [{ id: "library", name: "Library", trackCount: cache.tracks.length }, ...cache.playlists]
    state.tracks = cache.tracks
    state.libraryStatus = "ready"
    state.libraryError = null
    state.playlistStatus = "ready"
    stopNowPlayingStream = await bridge.subscribeNowPlaying((nowPlaying) => {
      const previousTrackId = state.nowPlaying.track?.id ?? null
      const nextTrackId = nowPlaying.track?.id ?? null
      const previousState = state.nowPlaying.state
      state.nowPlaying = nowPlaying
      if (previousTrackId !== nextTrackId || previousState !== nowPlaying.state || nowPlaying.state !== "playing") {
        render()
      }
    })
  } catch (error) {
    state.libraryStatus = "error"
    state.libraryError = describeBridgeError(error)
  }

  render()
  animLoop()
}

process.on("exit", () => {
  cleanup()
})

main()
