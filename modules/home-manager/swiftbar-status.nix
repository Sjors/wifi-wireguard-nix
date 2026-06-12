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
          icon_path="M23.98 11.645S24.533 0 11.735 0C.418 0 .064 11.17.064 11.17S-1.6 24 11.997 24C25.04 24 23.98 11.645 23.98 11.645zM23.98 11.645S24.533 0 11.735 0C.418 0 .064 11.17.064 11.17S-1.6 24 11.997 24C25.04 24 23.98 11.645 23.98 11.645zM8.155 7.576c2.4-1.47 5.469-.571 6.618 1.638.218.419.246 1.063.108 1.503-.477 1.516-1.601 2.366-3.145 2.728.455-.39.817-.832.933-1.442a2.112 2.112 0 0 0-.364-1.677 2.14 2.14 0 0 0-2.465-.75c-.95.36-1.47 1.228-1.377 2.294.087.99.839 1.632 2.245 1.876-.21.111-.372.193-.53.281a5.113 5.113 0 0 0-1.644 1.43c-.143.192-.24.208-.458.075-2.827-1.729-3.009-6.067.078-7.956zM6.04 18.258c-.455.116-.895.286-1.359.438.227-1.532 2.021-2.943 3.539-2.782a3.91 3.91 0 0 0-.74 2.072c-.504.093-.98.155-1.44.272zM15.703 3.3c.448.017.898.01 1.347.02a2.324 2.324 0 0 1 .334.047 3.249 3.249 0 0 1-.34.434c-.16.15-.341.296-.573.069-.055-.055-.187-.042-.283-.044-.447-.005-.894-.02-1.34-.003a8.323 8.323 0 0 0-1.154.118c-.072.013-.178.25-.146.338.078.207.191.435.359.567.619.49 1.277.928 1.9 1.413.604.472 1.167.99 1.51 1.7.446.928.46 1.9.267 2.877-.322 1.63-1.147 2.98-2.483 3.962-.538.395-1.205.62-1.821.903-.543.25-1.1.465-1.644.712-.98.446-1.53 1.51-1.369 2.615.149 1.015 1.04 1.862 2.059 2.037 1.223.21 2.486-.586 2.785-1.83.336-1.397-.423-2.646-1.845-3.024l-.256-.066c.38-.17.708-.291 1.012-.458q.793-.437 1.558-.925c.15-.096.231-.096.36.014.977.846 1.56 1.898 1.724 3.187.27 2.135-.74 4.096-2.646 5.101-2.948 1.555-6.557-.215-7.208-3.484-.558-2.8 1.418-5.34 3.797-5.83 1.023-.211 1.958-.637 2.685-1.425.47-.508.697-.944.775-1.141a3.165 3.165 0 0 0 .217-1.158 2.71 2.71 0 0 0-.237-.992c-.248-.566-1.2-1.466-1.435-1.656l-2.24-1.754c-.079-.065-.168-.06-.36-.047-.23.016-.815.048-1.067-.018.204-.155.76-.38 1-.56-.726-.49-1.554-.314-2.315-.46.176-.328 1.046-.831 1.541-.888a7.323 7.323 0 0 0-.135-.822c-.03-.111-.154-.22-.263-.283-.262-.154-.541-.281-.843-.434a1.755 1.755 0 0 1 .906-.28 3.385 3.385 0 0 1 .908.088c.54.123.97.042 1.399-.324-.338-.136-.676-.26-1.003-.407a9.843 9.843 0 0 1-.942-.493c.85.118 1.671.437 2.54.32l.022-.118-2.018-.47c1.203-.11 2.323-.128 3.384.388.299.146.61.266.897.432.14.08.233.24.348.365.09.098.164.23.276.29.424.225.89.234 1.366.223l.01-.16c.479.15 1.017.702 1.017 1.105-.776 0-1.55-.003-2.325.004-.083 0-.165.061-.247.094.078.046.155.128.235.131zM14.703 2.153a.118.118 0 0 0-.016.19.179.179 0 0 0 .246.065c.075-.038.148-.078.238-.125-.072-.062-.13-.114-.19-.163-.106-.087-.193-.032-.278.033z"

          build_icon() {
            fill="$1"
            printf '%s' "<svg role=\"img\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><g transform=\"translate(1.8 1.8) scale(0.85)\"><path fill=\"$fill\" d=\"$icon_path\" fill-rule=\"evenodd\"/></g></svg>" | /usr/bin/base64 | /usr/bin/tr -d '\n'
          }

          build_icon_pair() {
            light_fill="$1"
            dark_fill="$2"
            printf '%s,%s' "$(build_icon "$light_fill")" "$(build_icon "$dark_fill")"
          }

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
            up:connected)
              header="| image=$(build_icon_pair '#111827' '#f9fafb')"
              ;;
            up:degraded)
              header="| image=$(build_icon_pair '#d97706' '#f59e0b')"
              ;;
            up:manual|up:manual_excluded_ssid)
              header="| image=$(build_icon_pair '#2563eb' '#60a5fa')"
              ;;
            down:captive|down:error)
              header="| image=$(build_icon_pair '#dc2626' '#f87171')"
              ;;
            down:disabled|down:excluded_ssid|down:stopped)
              header="| image=$(build_icon_pair '#9ca3af' '#9ca3af')"
              ;;
            *)
              header="| image=$(build_icon_pair '#d97706' '#f59e0b')"
              ;;
          esac

          printf '%s\n' "$header"
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
