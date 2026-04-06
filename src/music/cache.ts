import type { Track, Playlist } from "./types"
import { bootstrap } from "./bridge"

class LibraryCache {
  tracks: Track[] = []
  trackMap = new Map<string, Track>()
  playlists: Playlist[] = []
  loading = false
  loaded = false
  totalCount = 0
  loadedCount = 0

  async load(): Promise<void> {
    if (this.loading) return

    this.loading = true
    this.loaded = false
    this.tracks = []
    this.trackMap.clear()
    this.playlists = []
    this.totalCount = 0
    this.loadedCount = 0

    try {
      const data = await bootstrap()
      this.tracks = data.libraryTracks
      this.playlists = data.playlists
      this.totalCount = data.libraryTracks.length
      this.loadedCount = data.libraryTracks.length

      for (const track of data.libraryTracks) {
        this.trackMap.set(track.id, track)
      }

      this.loaded = true
    } finally {
      this.loading = false
    }
  }

  getTrack(id: string): Track | undefined {
    return this.trackMap.get(id)
  }
}

export const cache = new LibraryCache()
