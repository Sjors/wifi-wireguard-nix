{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.wifiWireguardStatus;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  rootControlScript = pkgs.writeShellScript "wifi-wireguard-swiftbar-root-control" ''
    set -eu

    action="''${1:-}"
    config_path=${lib.escapeShellArg cfg.configPath}
    status_file=${lib.escapeShellArg cfg.statusFile}
    interface=${lib.escapeShellArg cfg.interface}
    launchd_label=${lib.escapeShellArg cfg.launchdLabel}
    launchd_plist=${lib.escapeShellArg cfg.launchdPlist}

    write_status() {
      state="$1"
      reason="$2"
      tmp_file="$status_file.tmp"
      umask 022
      cat > "$tmp_file" <<STATUS_EOF
    state=$state
    reason=$reason
    interface=$interface
    wifi_profile_id=
    last_handshake=0
    updated_at=$(/bin/date +%s)
    STATUS_EOF
      chmod 0644 "$tmp_file"
      mv "$tmp_file" "$status_file"
    }

    disable_wireguard() {
      /bin/launchctl disable "system/$launchd_label"
      /bin/launchctl bootout "system/$launchd_label" >/dev/null 2>&1 || true
      ${pkgs.wireguard-tools}/bin/wg-quick down "$config_path" >/dev/null 2>&1 || true
      write_status down disabled
    }

    enable_wireguard() {
      write_status down starting
      /bin/launchctl enable "system/$launchd_label"
      /bin/launchctl bootstrap system "$launchd_plist" >/dev/null 2>&1 || true
      /bin/launchctl kickstart -k "system/$launchd_label"
    }

    case "$action" in
      disable)
        disable_wireguard
        ;;
      enable)
        enable_wireguard
        ;;
      *)
        printf '%s\n' "usage: $0 enable|disable" >&2
        exit 64
        ;;
    esac
  '';

  controlScript = pkgs.writeShellScript "wifi-wireguard-swiftbar-control" ''
    set -eu

    action="''${1:-}"
    case "$action" in
      disable|enable)
        if [ "$(/usr/bin/id -u)" -eq 0 ]; then
          exec ${rootControlScript} "$action"
        fi
        exec /usr/bin/sudo ${rootControlScript} "$action"
        ;;
      *)
        printf '%s\n' "usage: $0 enable|disable" >&2
        exit 64
        ;;
    esac
  '';
in
{
  options.programs.wifiWireguardStatus = {
    enable = mkEnableOption "a SwiftBar menu for a wifiWireguard daemon";

    interface = mkOption {
      type = types.str;
      default = "wg0";
      description = "WireGuard interface name displayed in the menu.";
    };

    launchdLabel = mkOption {
      type = types.str;
      default = "local.wireguard.${cfg.interface}";
      defaultText = lib.literalExpression ''"local.wireguard.\${config.programs.wifiWireguardStatus.interface}"'';
      description = "LaunchDaemon label controlled by the menu.";
    };

    launchdPlist = mkOption {
      type = types.str;
      default = "/Library/LaunchDaemons/${cfg.launchdLabel}.plist";
      defaultText = lib.literalExpression ''"/Library/LaunchDaemons/\${config.programs.wifiWireguardStatus.launchdLabel}.plist"'';
      description = "LaunchDaemon plist path.";
    };

    configPath = mkOption {
      type = types.str;
      default = "/etc/wireguard/${cfg.interface}.conf";
      defaultText = lib.literalExpression ''"/etc/wireguard/\${config.programs.wifiWireguardStatus.interface}.conf"'';
      description = "wg-quick configuration path.";
    };

    statusFile = mkOption {
      type = types.str;
      default = "/var/run/wireguard-${cfg.interface}.status";
      defaultText = lib.literalExpression ''"/var/run/wireguard-\${config.programs.wifiWireguardStatus.interface}.status"'';
      description = "Status file written by the system daemon.";
    };

    logPath = mkOption {
      type = types.str;
      default = "/var/log/wireguard-${cfg.interface}.log";
      defaultText = lib.literalExpression ''"/var/log/wireguard-\${config.programs.wifiWireguardStatus.interface}.log"'';
      description = "WireGuard daemon log path displayed in the menu.";
    };

    pluginPath = mkOption {
      type = types.str;
      default = "Library/Application Support/SwiftBar/Plugins/wireguard.30s.sh";
      description = "Home-relative path where the SwiftBar plugin should be installed.";
    };

    enableSystemControl = mkOption {
      type = types.bool;
      default = true;
      description = "Show enable/disable actions that run through sudo.";
    };

    installSwiftBar = mkOption {
      type = types.bool;
      default = false;
      description = "Install pkgs.swiftbar into the Home Manager profile.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = lib.optional cfg.installSwiftBar pkgs.swiftbar;

    home.file.${cfg.pluginPath} = {
      executable = true;
      text = ''
          #!/bin/bash
          set -eu

          status_file=${lib.escapeShellArg cfg.statusFile}
          launchd_label=${lib.escapeShellArg cfg.launchdLabel}
          interface=${lib.escapeShellArg cfg.interface}
          log_path=${lib.escapeShellArg cfg.logPath}

          state="unknown"
          reason="missing"
          last_handshake="0"
          updated_at="0"

          if [ -r "$status_file" ]; then
            while IFS='=' read -r key value; do
              case "$key" in
                state) state="$value" ;;
                reason) reason="$value" ;;
                interface) interface="$value" ;;
                last_handshake) last_handshake="$value" ;;
                updated_at) updated_at="$value" ;;
              esac
            done < "$status_file"
          fi

          age_string() {
            seconds="$1"
            if [ "$seconds" -lt 60 ]; then
              printf '%ss' "$seconds"
            elif [ "$seconds" -lt 3600 ]; then
              printf '%sm' "$((seconds / 60))"
            elif [ "$seconds" -lt 86400 ]; then
              printf '%sh' "$((seconds / 3600))"
            else
              printf '%sd' "$((seconds / 86400))"
            fi
          }

          wg_interfaces="$(${pkgs.wireguard-tools}/bin/wg show interfaces 2>/dev/null || true)"
          actual_wireguard_up=0
          actual_wireguard_interface=""
          if [ -n "$wg_interfaces" ]; then
            for wg_interface in $wg_interfaces; do
              if [ -z "$actual_wireguard_interface" ] || [ "$wg_interface" = "$interface" ]; then
                actual_wireguard_up=1
                actual_wireguard_interface="$wg_interface"
              fi
              if [ "$wg_interface" = "$interface" ]; then
                actual_wireguard_interface="$wg_interface"
              fi
            done
          fi

          if [ "$actual_wireguard_up" -eq 1 ] && [ "$state" = "down" ]; then
            state="up"
            reason="manual"
            last_handshake="$(${pkgs.wireguard-tools}/bin/wg show "$actual_wireguard_interface" latest-handshakes 2>/dev/null | ${pkgs.gawk}/bin/awk 'BEGIN { max = 0 } $2 > max { max = $2 } END { print max }')"
            if [ -z "$last_handshake" ]; then
              last_handshake=0
            fi
          fi

          launchd_disabled=0
          if /bin/launchctl print-disabled system 2>/dev/null | /usr/bin/grep -q "\"$launchd_label\" => disabled"; then
            launchd_disabled=1
            if [ "$actual_wireguard_up" -eq 0 ]; then
              state="down"
              reason="disabled"
            fi
          fi

          now=$(/bin/date +%s)
          if [ "$last_handshake" -gt 0 ] 2>/dev/null; then
            handshake_age=$((now - last_handshake))
            handshake_label="$(age_string "$handshake_age") ago"
          else
            handshake_label="none"
          fi

          if [ "$updated_at" -gt 0 ] 2>/dev/null; then
            updated_age=$((now - updated_at))
            updated_label="$(age_string "$updated_age") ago"
          else
            updated_label="unknown"
          fi

          case "$state:$reason" in
            up:connected) color="#111827" ;;
            up:degraded) color="#d97706" ;;
            up:manual) color="#2563eb" ;;
            down:captive|down:error) color="#dc2626" ;;
            down:disabled|down:excluded_ssid|down:stopped) color="#9ca3af" ;;
            *) color="#d97706" ;;
          esac

          printf 'WG | color=%s\n' "$color"
          printf '%s\n' '---'
          printf 'Interface: %s\n' "$interface"
          printf 'State: %s\n' "$state"
          printf 'Reason: %s\n' "$reason"
          printf 'Last handshake: %s\n' "$handshake_label"
          printf 'Status age: %s\n' "$updated_label"
          printf 'Log: %s\n' "$log_path"
          printf '%s\n' '---'
        ${lib.optionalString cfg.enableSystemControl ''
          if [ "$launchd_disabled" -eq 1 ]; then
            printf 'Enable WireGuard | bash="%s" param1=enable terminal=true refresh=true\n' "${controlScript}"
          else
            printf 'Disable WireGuard | bash="%s" param1=disable terminal=true refresh=true\n' "${controlScript}"
          fi
        ''}
      '';
    };
  };
}
