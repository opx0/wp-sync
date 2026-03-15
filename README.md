# wp-sync

Sync wallpapers across machines. Drop an image on one, it appears on all.

One script. Syncthing handles the rest.

## Install

```bash
curl -sL https://raw.githubusercontent.com/opx0/wp-sync/main/wp-sync-setup.sh | bash
```

## Add a friend

They run:

```bash
curl -sL https://raw.githubusercontent.com/opx0/wp-sync/main/wp-sync-setup.sh | bash -s -- --join <YOUR_DEVICE_ID>
```

Accept them once in the Syncthing UI at `localhost:8384`. Done.

## What it does

- Installs Syncthing via pacman
- Creates a shared `~/Pictures/Wallpapers` folder
- Auto-applies the newest wallpaper when files change
- Works over the internet — no VPN, no port forwarding
- Syncthing handles discovery, NAT traversal, encryption

## Wallpaper auto-apply

Detects your DE and sets the wallpaper automatically:

GNOME, KDE Plasma, Sway, Hyprland, XFCE, MATE, i3/feh

## How it works

```
Machine A                    Machine B
~/Pictures/Wallpapers/ <---> ~/Pictures/Wallpapers/
         |                            |
    [path watcher]               [path watcher]
         |                            |
    auto-apply                   auto-apply
```

Syncthing syncs the folder. A systemd path unit watches for changes and applies the newest image.

## Requirements

Arch Linux. That's it.

## License

MIT
