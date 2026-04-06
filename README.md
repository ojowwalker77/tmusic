# tmusic

Apple Music in the terminal.

## Requirements

- macOS
- Apple Music
- Bun

## Clone

```sh
git clone git@github.com:ojowwalker77/tmusic.git
cd tmusic
```

## Build

```sh
bun install
bun run build:helper
```

## Create Alias

```sh
echo "alias tmusic=\"$PWD/tmusic\"" >> ~/.zshrc
source ~/.zshrc
```

## Run

```sh
tmusic
```

On first launch, macOS may ask for Music access.
