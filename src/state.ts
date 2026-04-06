import type { NowPlaying, Track, Playlist } from "./music/types"

export type LoadStatus = "idle" | "loading" | "ready" | "error"

export interface AppState {
  nowPlaying: NowPlaying
  playlists: Playlist[]
  currentPlaylist: number
  tracks: Track[]
  trackSelection: number
  scrollOffset: number
  libraryStatus: LoadStatus
  libraryError: string | null
  playlistStatus: LoadStatus
  playlistError: string | null
}

export function createState(): AppState {
  return {
    nowPlaying: {
      track: null,
      state: "stopped",
      position: 0,
      volume: 100,
      shuffleEnabled: false,
      repeatMode: "off",
      energy: [],
      analysisSource: "idle",
    },
    playlists: [],
    currentPlaylist: 0,
    tracks: [],
    trackSelection: 0,
    scrollOffset: 0,
    libraryStatus: "idle",
    libraryError: null,
    playlistStatus: "idle",
    playlistError: null,
  }
}
