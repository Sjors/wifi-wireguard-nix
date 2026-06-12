# wifi-wireguard-nix

Reusable nix-darwin and Home Manager modules for running WireGuard on macOS with Wi-Fi-aware behavior.

**100% vibe coded, be careful when using this**

The Darwin module runs a foreground `wg-quick` supervisor under launchd. It can keep a tunnel down on selected Wi-Fi networks, avoid re-enabling during captive portal or offline states, reset WireGuard DNS when the tunnel is down, and preserve a manual `launchctl disable` across rebuilds.

The Home Manager module installs an optional SwiftBar plugin that displays daemon status and can enable or disable the launchd service through `sudo`.

## What This Flake Does Not Manage

This flake does not generate WireGuard private keys or peer configuration. Keep your real configuration in a root-owned file such as `/etc/wireguard/wg0.conf`, or manage that file with your own secret-management setup.

It also does not include any Wi-Fi ProfileIDs by default. You provide the networks where the tunnel should stay down.

## Outputs

- `darwinModules.wifi-wireguard` / `darwinModules.default`
- `homeManagerModules.swiftbar-status` / `homeManagerModules.default`

## nix-darwin Usage

```nix
{
  inputs.wifi-wireguard-nix.url = "github:Sjors/wifi-wireguard-nix";

  outputs = { nix-darwin, nixpkgs, wifi-wireguard-nix, ... }: {
    darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
      modules = [
        wifi-wireguard-nix.darwinModules.wifi-wireguard
        {
          services.wifiWireguard = {
            enable = true;
            interface = "wg0";
            configPath = "/etc/wireguard/wg0.conf";

            # Use the ProfileID values from macOS, not SSID names.
            excludedWifiProfileIds = [
              "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ];
          };
        }
      ];
    };
  };
}
```

Useful options:

- `services.wifiWireguard.interface`
- `services.wifiWireguard.configPath`
- `services.wifiWireguard.wifiInterface`
- `services.wifiWireguard.excludedWifiProfileIds`
- `services.wifiWireguard.launchdLabel`
- `services.wifiWireguard.statusFile`
- `services.wifiWireguard.logPath`
- `services.wifiWireguard.probe.url`
- `services.wifiWireguard.probe.expectedText`
- `services.wifiWireguard.checkInterval`
- `services.wifiWireguard.failureThreshold`
- `services.wifiWireguard.resetDnsOnDown`
- `services.wifiWireguard.preserveManualDisable`

## Home Manager SwiftBar Usage

```nix
{
  imports = [ wifi-wireguard-nix.homeManagerModules.swiftbar-status ];

  programs.wifiWireguardStatus = {
    enable = true;
    interface = "wg0";
    configPath = "/etc/wireguard/wg0.conf";
    installSwiftBar = true;
  };
}
```

The plugin reads the status file written by the Darwin daemon and checks the live WireGuard and launchd state. When `enableSystemControl` is true, it shows Enable/Disable actions that call `sudo`.

## Finding Wi-Fi ProfileIDs

On macOS the daemon compares ProfileIDs, not SSIDs. One way to inspect the current Wi-Fi ProfileID is:

```sh
sudo sh -c "printf 'show State:/Network/Interface/en0/AirPort\n' | /usr/sbin/scutil"
```

Look for the `ProfileID` field and put that value in `excludedWifiProfileIds`.

## Manual Control

Disable and keep disabled across rebuilds:

```sh
sudo launchctl disable system/local.wireguard.wg0
sudo launchctl bootout system/local.wireguard.wg0
sudo wg-quick down /etc/wireguard/wg0.conf
```

Enable again:

```sh
sudo launchctl enable system/local.wireguard.wg0
sudo launchctl kickstart -k system/local.wireguard.wg0
```

Adjust the label and config path for your `interface` if you do not use `wg0`.
