{
  pkgs,
  config,
  lib,
  ...
}:
with lib;
let
  kernelModuleList = pkgs.writeText "kernel-modules" (
    concatStringsSep "\n" config.boot.kernelModules + "\n"
  );

  kernelModuleServiceShell = ''
    set -e

    module_list=/etc/kernel-modules
    state_dir=/run/kernel-modules
    state_file=$state_dir/modules
    sleep_pid=

    log() {
      printf '%s\n' "$*"
      ${pkgs.util-linux}/bin/logger -t kernel-modules -- "$*" || true
    }

    stop_sleep() {
      [ -n "$sleep_pid" ] || return 0
      kill "$sleep_pid" 2> /dev/null || true
      wait "$sleep_pid" 2> /dev/null || true
      sleep_pid=
    }

    wait_for_syslog_socket() {
      for i in $(${pkgs.coreutils}/bin/seq 1 10); do
        [ -S /dev/log ] && return 0
        ${pkgs.coreutils}/bin/sleep 1
      done

      return 1
    }

    load_modules() {
      mkdir -p "$state_dir"

      while IFS= read -r module; do
        [ -n "$module" ] || continue

        log "loading module $module"
        if ! ${pkgs.kmod}/bin/modprobe "$module"; then
          log "failed to load module $module"
        fi
      done < "$module_list"
    }

    unload_removed_modules() {
      [ -s "$state_file" ] || return 0

      ${pkgs.coreutils}/bin/tac "$state_file" | while IFS= read -r module; do
        [ -n "$module" ] || continue
        ${pkgs.gnugrep}/bin/grep -Fxq "$module" "$module_list" && continue

        log "unloading removed module $module"
        if ! ${pkgs.kmod}/bin/modprobe -r "$module"; then
          log "kept removed module $module"
        fi
      done
    }

    reload_modules() {
      log "loading configured kernel modules"
      load_modules
      unload_removed_modules
      cp "$module_list" "$state_file"
      log "configured kernel modules loaded"
    }

    handle_hangup() {
      stop_sleep
      log "reloading kernel-modules service script"
      exec /etc/runit/services/kernel-modules/run
    }

    handle_exit() {
      stop_sleep
      exit 0
    }
  '';
in
{
  config = {
    environment.etc."kernel-modules".source = kernelModuleList;

    runit.services.kernel-modules = {
      check = ''
        ${pkgs.diffutils}/bin/cmp -s /etc/kernel-modules /run/kernel-modules/modules
      '';
      run = ''
        # Module list: ${kernelModuleList}
        ${kernelModuleServiceShell}
        trap handle_hangup HUP
        trap handle_exit TERM INT

        sv up rsyslog 2> /dev/null || true
        waitForService rsyslog 10 || true
        wait_for_syslog_socket || true
        reload_modules

        while true; do
          ${pkgs.coreutils}/bin/sleep infinity &
          sleep_pid=$!
          wait "$sleep_pid" || true
        done
      '';
      control.hangup = ''
        ${kernelModuleServiceShell}
        log "reloading kernel modules from service control"
        reload_modules
      '';
      includeHelpers = true;
      log.enable = true;
      onChange = "reload";
      runlevels = [
        "rescue"
        "default"
      ];
    };
  };
}
