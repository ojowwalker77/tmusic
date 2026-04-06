export interface Track {
  id: string
  name: string
  artist: string
  album: string
  duration: number
  genre: string
  year: number
  playCount: number
  loved: boolean
  trackNumber: number
}

export interface Playlist {
  id: string
  name: string
  trackCount: number
}

export type PlayerState = "playing" | "paused" | "stopped"
export type RepeatMode = "off" | "one" | "all"

export interface NowPlaying {
  track: Track | null
  state: PlayerState
  position: number
  volume: number
  shuffleEnabled: boolean
  repeatMode: RepeatMode
  energy: number[]
  analysisSource: "file" | "fft" | "fallback" | "idle"
}
