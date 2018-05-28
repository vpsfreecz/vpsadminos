{ config, lib, pkgs, utils, ... }:

with utils;
with lib;

let

  cfg = config.programs.htop;

in

{

  ###### interface

  options = {
    programs.htop = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable htop
        '';
      };
    };
  };

  ###### implementation

  config = mkMerge [
    (mkIf cfg.enable {
      environment.etc."htoprc".source = pkgs.writeText "htoprc" ''
        fields=119 0 120 17 18 38 39 40 2 46 47 49 1
        sort_key=46
        sort_direction=1
        hide_threads=0
        hide_kernel_threads=0
        hide_userland_threads=1
        shadow_other_users=0
        show_thread_names=0
        show_program_path=0
        highlight_base_name=0
        highlight_megabytes=1
        highlight_threads=1
        tree_view=0
        header_margin=1
        detailed_cpu_time=0
        cpu_count_from_zero=0
        update_process_names=0
        account_guest_in_cpu_meter=0
        color_scheme=6
        delay=15
        left_meters=LeftCPUs2 CPU Memory Swap
        left_meter_modes=1 2 1 1
        right_meters=RightCPUs2 Tasks LoadAverage Uptime
        right_meter_modes=1 2 2 2
      '';

      environment.systemPackages = [ pkgs.htop ];
    })
  ];
}
