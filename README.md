# dirdiffz

The goal of this project is to build a TUI that can replace BetterCompare / WinMerge / etc for my workflow.

<img width="3720" height="2210" alt="image" src="https://github.com/user-attachments/assets/da4fbc47-9076-4b7b-be6a-56e38efe329d" />

## Installation

*** macOS or Linux using brew ***
```sh
brew tap vakata/tap
brew trust --formula vakata/tap/dirdiffz
brew install dirdiffz
```

*** Linux manual install *** 
Using prebuild binaries from the releases page.

```sh
# x86_64
curl -L https://github.com/vakata/dirdiffz/releases/latest/download/dirdiffz-linux-x86_64.tar.gz | tar -xz
sudo install dirdiffz /usr/local/bin/dirdiffz

# arm
curl -L https://github.com/vakata/dirdiffz/releases/latest/download/dirdiffz-linux-aarch64.tar.gz | tar -xz
sudo install dirdiffz /usr/local/bin/dirdiffz
```

## Progress:
 - [x] recursively walk and diff as needed
 - [x] build a two panel TUI that shows the resulting tree
 - [x] add filters for same / different / orphans
 - [x] add the navigation and a minimal help popup
 - [X] integrate with vimdiff / neovim -d
 - [X] implement copy-to-left / copy-to-right / delete
 - [X] add confirm dialogs when copying / deleting
 - [X] preserve state when refreshing
 - [X] extract separate App struct from main
 - [X] add optional arguments for --no-color and --ignore
 - [ ] add windows specific code (low priority for now)

