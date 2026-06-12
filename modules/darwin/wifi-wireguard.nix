{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wifiWireguard;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  excludedWifiProfilePatterns =
    lib.concatMapStringsSep "|" lib.escapeShellArg
      cfg.excludedWifiProfileIds;
  disabledStateFile = "/var/run/wireguard-${cfg.interface}.launchd-disabled-before-activation";

  wireguardDaemon = pkgs.writeShellScript "wireguard-daemon-${cfg.interface}" ''
    set -eu

    interface=${lib.escapeShellArg cfg.interface}
    config_path=${lib.escapeShellArg cfg.configPath}
    status_file=${lib.escapeShellArg cfg.statusFile}
    wifi_interface=${lib.escapeShellArg cfg.wifiInterface}
    probe_url=${lib.escapeShellArg cfg.probe.url}
    probe_expect=${lib.escapeShellArg cfg.probe.expectedText}
    probe_max_time=${toString cfg.probe.maxTime}
    check_interval=${toString cfg.checkInterval}
    failure_threshold=${toString cfg.failureThreshold}
    up=0
    failures=0
    captive_logged=0

    actual_wireguard_interface() {
      ${pkgs.wireguard-tools}/bin/wg show interfaces 2>/dev/null | ${pkgs.gawk}/bin/awk -v wanted="$interface" '
        NF > 0 {
          for (i = 1; i <= NF; i++) {
            if ($i == wanted) {
              print $i
              exit
            }
          }
          print $1
        }
      '
    }

    latest_handshake() {
      actual_interface="$(actual_wireguard_interface)"
      if [ -z "$actual_interface" ]; then
        printf '%s\n' 0
        return 0
      fi

      ${pkgs.wireguard-tools}/bin/wg show "$actual_interface" latest-handshakes 2>/dev/null | ${pkgs.gawk}/bin/awk 'BEGIN { max = 0 } $2 > max { max = $2 } END { print max }'
    }

    write_status() {
      state="$1"
      reason="$2"
      wifi_profile_id="$3"
      last_handshake=0
      if [ "$state" = "up" ]; then
        last_handshake="$(latest_handshake)"
        if [ -z "$last_handshake" ]; then
          last_handshake=0
        fi
      fi

      tmp_file="$status_file.tmp"
      umask 022
      cat > "$tmp_file" <<STATUS_EOF
    state=$state
    reason=$reason
    interface=$interface
    wifi_profile_id=$wifi_profile_id
    last_handshake=$last_handshake
    updated_at=$(/bin/date +%s)
    STATUS_EOF
      chmod 0644 "$tmp_file"
      mv "$tmp_file" "$status_file"
    }

    probe_healthy() {
      output="$(${pkgs.curl}/bin/curl \
        --silent \
        --show-error \
        --location \
        --max-time "$probe_max_time" \
        "$probe_url" 2>/dev/null || true)"
      case "$output" in
        *"$probe_expect"*)
          return 0
          ;;
      esac
      return 1
    }

    primary_network_service() {
      device="$(/sbin/route -n get default 2>/dev/null | ${pkgs.gawk}/bin/awk '/interface: / { print $2; exit }')"
      if [ -z "$device" ]; then
        return 1
      fi

      /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | ${pkgs.gawk}/bin/awk -v target_device="$device" '
        /^\([0-9]+\)/ {
          service = $0
          sub(/^\([0-9]+\)[[:space:]]*/, "", service)
          sub(/^\*[[:space:]]*/, "", service)
        }
        /Device: / {
          if (match($0, /Device: ([^,)]+)/, m) && m[1] == target_device) {
            print service
            exit
          }
        }
      '
    }

    wifi_profile_id() {
      ${pkgs.coreutils}/bin/printf 'show State:/Network/Interface/%s/AirPort\n' "$wifi_interface" \
        | /usr/sbin/scutil 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F': ' '/ProfileID : / { print $2; exit }'
    }

    excluded_wifi_profile_id() {
      profile_id="$1"
    ${lib.optionalString (cfg.excludedWifiProfileIds != [ ]) ''
      case "$profile_id" in
        ${excludedWifiProfilePatterns})
          printf '%s\n' "$profile_id"
          return 0
          ;;
      esac
    ''}
      return 1
    }

    wireguard_dns_servers() {
      ${pkgs.gawk}/bin/awk '
        BEGIN { interface_section = 0 }
        /^[[:space:]]*\[/ { interface_section = 0 }
        /^[[:space:]]*\[Interface\][[:space:]]*$/ { interface_section = 1 }
        interface_section && /^[[:space:]]*DNS[[:space:]]*=/ {
          sub(/^[^=]*=[[:space:]]*/, "")
          sub(/[[:space:]]*(#.*)?$/, "")
          gsub(/[[:space:]]*,[[:space:]]*/, " ")
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^([0-9.]+|.*:.*)$/) {
              print $i
            }
          }
        }
      ' "$config_path" 2>/dev/null | /usr/bin/sort -u
    }

    service_uses_wireguard_dns() {
      service="$1"
      configured_dns="$(wireguard_dns_servers)"
      if [ -z "$configured_dns" ]; then
        return 1
      fi

      current_dns="$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)"
      if [ -z "$current_dns" ]; then
        return 1
      fi

      while IFS= read -r dns_server; do
        if [ -n "$dns_server" ] && printf '%s\n' "$configured_dns" | /usr/bin/grep -Fxq "$dns_server"; then
          return 0
        fi
      done <<DNS_EOF
    $current_dns
    DNS_EOF

      return 1
    }

    reset_dns_service() {
      service="$1"
      if [ -z "$service" ]; then
        return 0
      fi

      printf '%s\n' "wireguard: resetting DNS on $service to DHCP-provided defaults"
      /usr/sbin/networksetup -setdnsservers "$service" Empty >/dev/null 2>&1 || true
      /usr/sbin/networksetup -setsearchdomains "$service" Empty >/dev/null 2>&1 || true
    }

    reset_wireguard_dns() {
      while IFS= read -r service; do
        [ -n "$service" ] || continue
        case "$service" in
          "An asterisk "*"denotes that a network service is disabled." | \**)
            continue
            ;;
        esac

        if service_uses_wireguard_dns "$service"; then
          reset_dns_service "$service"
        fi
      done <<SERVICES_EOF
    $(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null || true)
    SERVICES_EOF
    }

    ensure_fallback_dns() {
    ${lib.optionalString cfg.resetDnsOnDown ''
      service="$(primary_network_service || true)"
      reset_wireguard_dns

      if [ -n "$service" ] && service_uses_wireguard_dns "$service"; then
        reset_dns_service "$service"
        if service_uses_wireguard_dns "$service"; then
          printf '%s\n' "wireguard: DNS on $service still points at $interface; direct connectivity probe may fail"
        fi
      fi
    ''}
      return 0
    }

    bring_down() {
      actual_interface="$(actual_wireguard_interface)"
      if [ "$up" -eq 1 ] || [ -n "$actual_interface" ]; then
        if [ -n "$actual_interface" ] && [ "$actual_interface" != "$interface" ]; then
          printf '%s\n' "wireguard: bringing $interface down from $actual_interface"
        else
          printf '%s\n' "wireguard: bringing $interface down"
        fi
        ${pkgs.wireguard-tools}/bin/wg-quick down "$config_path" >/dev/null 2>&1 || true
        up=0
      fi
      ensure_fallback_dns
    }

    bring_up() {
      rc=0
      output="$(${pkgs.wireguard-tools}/bin/wg-quick up "$config_path" 2>&1)" || rc=$?
      printf '%s\n' "$output"

      if [ "$rc" -ne 0 ]; then
        case "$output" in
          *"already exists as"*)
            ;;
          *)
            write_status down error "$(wifi_profile_id)"
            return "$rc"
            ;;
        esac
      fi

      up=1
      failures=0
      captive_logged=0
      write_status up connected "$(wifi_profile_id)"
      return 0
    }

    cleanup() {
      write_status down stopped "$(wifi_profile_id)"
      bring_down
    }

    trap cleanup INT TERM EXIT
    write_status down starting "$(wifi_profile_id)"

    while true; do
      profile_id="$(wifi_profile_id)"
      if excluded_profile_id="$(excluded_wifi_profile_id "$profile_id")"; then
        printf '%s\n' "wireguard: current Wi-Fi profile \"$excluded_profile_id\" is excluded; leaving $interface down"
        write_status down excluded_ssid "$profile_id"
        bring_down
        sleep "$check_interval"
        continue
      fi

      if [ "$up" -eq 1 ]; then
        if probe_healthy; then
          failures=0
          write_status up connected "$profile_id"
        else
          failures=$((failures + 1))
          if [ "$failures" -ge "$failure_threshold" ]; then
            printf '%s\n' "wireguard: tunnel health probe failed; leaving $interface down until direct connectivity recovers"
            write_status down captive "$profile_id"
            bring_down
          else
            write_status up degraded "$profile_id"
          fi
        fi
      else
        if [ -n "$(actual_wireguard_interface)" ]; then
          printf '%s\n' "wireguard: found stale $interface interface while marked down; resetting tunnel"
          bring_down
        else
          ensure_fallback_dns
        fi
        if probe_healthy; then
          captive_logged=0
          bring_up || printf '%s\n' "wireguard: failed to bring $interface up; will retry"
        else
          write_status down captive "$profile_id"
          if [ "$captive_logged" -eq 0 ]; then
            printf '%s\n' "wireguard: direct network appears captive or offline; waiting before re-enabling $interface"
            captive_logged=1
          fi
        fi
      fi

      sleep "$check_interval"
    done
  '';
in
{
  options.services.wifiWireguard = {
    enable = mkEnableOption "a Wi-Fi aware WireGuard launchd daemon for macOS";

    interface = mkOption {
      type = types.str;
      default = "wg0";
      description = "Logical WireGuard interface name used for status, launchd names, and default paths.";
    };

    configPath = mkOption {
      type = types.str;
      default = "/etc/wireguard/${cfg.interface}.conf";
      defaultText = lib.literalExpression ''"/etc/wireguard/\${config.services.wifiWireguard.interface}.conf"'';
      description = "Path to the wg-quick configuration file. This module does not generate the file.";
    };

    wifiInterface = mkOption {
      type = types.str;
      default = "en0";
      description = "macOS network interface whose AirPort ProfileID should be inspected.";
    };

    excludedWifiProfileIds = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ];
      description = "Wi-Fi ProfileID values where the tunnel should be kept down.";
    };

    launchdLabel = mkOption {
      type = types.str;
      default = "local.wireguard.${cfg.interface}";
      defaultText = lib.literalExpression ''"local.wireguard.\${config.services.wifiWireguard.interface}"'';
      description = "LaunchDaemon label.";
    };

    statusFile = mkOption {
      type = types.str;
      default = "/var/run/wireguard-${cfg.interface}.status";
      defaultText = lib.literalExpression ''"/var/run/wireguard-\${config.services.wifiWireguard.interface}.status"'';
      description = "Machine-readable status file written by the daemon.";
    };

    logPath = mkOption {
      type = types.str;
      default = "/var/log/wireguard-${cfg.interface}.log";
      defaultText = lib.literalExpression ''"/var/log/wireguard-\${config.services.wifiWireguard.interface}.log"'';
      description = "Path for launchd stdout and stderr.";
    };

    probe = {
      url = mkOption {
        type = types.str;
        default = "http://captive.apple.com/hotspot-detect.html";
        description = "URL used to detect direct connectivity and captive portals.";
      };

      expectedText = mkOption {
        type = types.str;
        default = "Success";
        description = "Text expected in the connectivity probe response.";
      };

      maxTime = mkOption {
        type = types.ints.positive;
        default = 15;
        description = "Maximum probe time in seconds.";
      };
    };

    checkInterval = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Main daemon loop interval in seconds.";
    };

    failureThreshold = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Consecutive failed probes before an up tunnel is treated as captive/offline.";
    };

    resetDnsOnDown = mkOption {
      type = types.bool;
      default = true;
      description = "Reset network services using WireGuard DNS back to DHCP defaults when the tunnel is down.";
    };

    manageConfigDirectory = mkOption {
      type = types.bool;
      default = true;
      description = "Create /etc/wireguard with root-only permissions during activation.";
    };

    preserveManualDisable = mkOption {
      type = types.bool;
      default = true;
      description = "Preserve a manual launchctl disable across nix-darwin rebuilds.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.wireguard-go
      pkgs.wireguard-tools
    ];

    system.activationScripts.etc.text = mkIf cfg.manageConfigDirectory (
      lib.mkAfter ''
        install -d -m 0700 -o root -g wheel /etc/wireguard
      ''
    );

    system.activationScripts.preActivation.text = mkIf cfg.preserveManualDisable (
      lib.mkAfter ''
        if /bin/launchctl print-disabled system 2>/dev/null | /usr/bin/grep -q '"${cfg.launchdLabel}" => disabled'; then
          /usr/bin/touch ${disabledStateFile}
        else
          /bin/rm -f ${disabledStateFile}
        fi
      ''
    );

    system.activationScripts.postActivation.text = mkIf cfg.preserveManualDisable (
      lib.mkAfter ''
        if [ -e ${disabledStateFile} ]; then
          printf '%s\n' "wireguard: preserving manual launchd disable for ${cfg.launchdLabel}"
          /bin/launchctl disable system/${cfg.launchdLabel}
          /bin/launchctl bootout system/${cfg.launchdLabel} >/dev/null 2>&1 || true
          ${pkgs.wireguard-tools}/bin/wg-quick down ${cfg.configPath} >/dev/null 2>&1 || true
          /bin/rm -f ${disabledStateFile}
        fi
      ''
    );

    launchd.daemons."wireguard-${cfg.interface}" = {
      command = wireguardDaemon;
      serviceConfig = {
        EnvironmentVariables = {
          PATH = "${pkgs.wireguard-tools}/bin:${pkgs.wireguard-go}/bin:${config.environment.systemPath}";
        };
        KeepAlive = {
          NetworkState = true;
          SuccessfulExit = false;
        };
        Label = cfg.launchdLabel;
        ProcessType = "Background";
        RunAtLoad = true;
        StandardErrorPath = cfg.logPath;
        StandardOutPath = cfg.logPath;
      };
    };
  };
}
