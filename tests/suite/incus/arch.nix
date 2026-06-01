import ./base.nix {
  distribution = "arch";
  tests = [
    {
      version = "latest";
      mapBase = 1000000;
      setup = ''
        # Arch images include legacy iptables, but incus pulls iptables-nft,
        # so remove the conflicting package before installing incus.
        machine.all_succeed(
          "osctl ct exec #{ct} sh -c 'pacman -Q iptables >/dev/null 2>&1 && pacman -Rdd --noconfirm iptables || true'",
          "osctl ct exec #{ct} pacman -Syu --noconfirm iptables-nft incus",
        )
      '';
    }
  ];
}
