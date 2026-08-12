# dirdiffz

The goal of this project is to build a TUI that can replace BetterCompare / WinMerge / etc for my workflow.

<img width="3720" height="2210" alt="image" src="https://github.com/user-attachments/assets/da4fbc47-9076-4b7b-be6a-56e38efe329d" />


***Progress:***
 - [x] recursively walk and diff as needed
 - [x] build a two panel TUI that shows the resulting tree
 - [x] add filters for same / different / orphans
 - [x] add the navigation and a minimal help popup
 - [X] integrate with vimdiff / neovim -d
 - [X] implement copy-to-left / copy-to-right / delete
 - [ ] add confirm dialogs when copying / deleting
 - [ ] preserve state when refreshing
 - [ ] extract separate App struct from main
 - [ ] add optional arguments for --no-color and --ignore
 - [ ] add windows specific code (low priority for now)

