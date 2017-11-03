{ config, pkgs, lib, ... }:

# Common configuration

{
  imports = [ ./qemu.nix ];
  networking.hostName = lib.mkDefault "vpsadminos";
  services.openssh.enable = lib.mkDefault true;
  vpsadminos.nix = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    less
    ];

  environment.etc = {
    "ssh/authorized_keys.d/root" = {
      text = ''
        ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDUus8o86CftVSj2yJU0P0cCbeWIPt7x0SenQLS7cjnWoXOGWvUr1AVdPl3dAVeoE1pnDNLYxLblQ18lsmnIxfo= rmarko@grampi
        ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA+1ISXuCDVbdwV9BwnTmU8Y0GsHSyRemiIDUGUmbK8A5sK+9hKUVMzUaUT4glHfcBltY+u7bG2h9bCoaw+3UvdW9+tEY1qhgBoU6R+n3qmXAcRnG7jKQKuNtuc/7pPHIqQjWw6c/ONsNIIfP18D3cK+6mnwQ+A87/ujHdLb+RTRo+bqKdve4JnSqq015/HAV6btKiVHoGrhlEorwViPzYCK6yoR2kKqX2kFbKig/7tsOoscfOAnkbMNybUal5xHwZSwlT8FQwBoK9/Q2jXR0JdqUk4vZZfOvUGdpJIVJZq/0KhNxWdBZ5m0q0/sG3tGykFYzw0lB1QE5q400EG4zNyw== sorki@psyche
        ssh-dss AAAAB3NzaC1kc3MAAACBAOV+Cm2HAXiRA5X21PY39YuxIL23onn4OeQVuTref6Vsdxhazvi25uPXr0AIGe6fT3iYODYnga5zGK4LIwM+7YeqaQRmuC+lVizmnGpkZiiHbCzPCIU4nlH5SF3rpHMsA/Ub0/iG+WpEk+HshLq2K153HG6B43ZrYvBnC7H+XIRXAAAAFQCEtPuJCpboWEkt3QrwSepgIYJt1QAAAIBwEf63+9gkcBaSdH0Mc7XYJdeGR/wsTRnh8MYQmIhtbSoXyKzHKzmWKr44lDSTt0OBDtBEv8YjalOyCkdypUPo8nJXPJWeq3CSm1GUA4FWSPfEWq1iX60v2S13j92/GhE1AzP6GXHkZ2LbNCkv0Hcc5egIW1biGRPp+kz4v2KY4AAAAIEAwYUyMdEuMCsRrTjR8u/4HgSBi1mniuWPm/hlaw4Mqf7HFzL2RjWSfGGAxleIze2BrID9ic+dGCsR7DFcajE3HBd2tJxPbpKUm7JxAo8bPa2/8+i+5fqOxVTjRxh1qfiJc6zqdznrPqPkLxccEVkfxf9mSvfPS5tzltmBlSWaqaA= snajpa@alfa
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDPwzvONGTj+vxMdDrZXIebGmXBD1z34AiOTrS/pg+UJlYoIhEvmmITlPEwnl4+34WaxBSXmorvyn2PCETg8xq8jt+RKJHGe1/GKb91yvu3wMpbMCholm4zNF5rzF9irhAa7qsvfLmd55IRNEqxPUYmiXI+QREasD55CHPuw85AnUbrnYKJtEKL7ckTjy/FOJYfZoynjsbIyeMz65yYGF+T5aNDGyA8kkMUieAlkWO0pZKhKhBnLJydPqgy8zWqiiQW31g/q59Q+WT1U7kIBeyPzW8F1cw/CPLNmRhDuwBfxHKWVqSSvtcjuiw62VZxSKBaNc28dU78D4UgDnCGWDel root@nixos1337
      '';
      mode = "0444";
    };
  };

  users.extraUsers.root = {
    subUidRanges = [
        { startUid = 666000; count = 65536; }
      ];
    subGidRanges = [
        { startGid = 666000; count = 65536; }
      ];
  };

  users.extraUsers.lxc = {
    isNormalUser = true;
    home = "/home/lxc";
    subUidRanges = [
        { startUid = 100000; count = 65536; }
      ];
    subGidRanges = [
        { startGid = 100000; count = 65536; }
      ];
  };

  users.motd = ''

    Welcome to vpsAdminOS

    Start test container with:

      lxc-create -n ct_gentoo -t download -- -d gentoo -r current -a amd64
      lxc-create -n ct_alpine -t download -- -d alpine -r edge -a amd64
      lxc-create -n ct_fedora -t download -- -d fedora -r 26 -a amd64
      lxc-create -n ct_arch   -t download -- -d archlinux -r current -a amd64
      lxc-create -n ct_ubuntu -t download -- -d ubuntu -r zesty -a amd64
    '';

  programs.ssh.package = pkgs.openssh;
}
