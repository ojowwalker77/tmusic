# tmusic

Apple Music in the terminal.

<img width="1920" height="1015" alt="image" src="https://github.com/user-attachments/assets/db91cff0-d993-4d1a-a18f-00d1be72baf9" />


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
