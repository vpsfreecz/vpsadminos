import ./base.nix {
  distribution = "arch";
  version = "latest";
  setupScript = ''
    # Arch images include legacy iptables, but incus pulls iptables-nft,
    # so remove the conflicting package before installing incus.
    machine.all_succeed(
      "osctl ct exec incusct sh -c 'pacman -Q iptables >/dev/null 2>&1 && pacman -Rdd --noconfirm iptables || true'",
      "osctl ct exec incusct pacman -Syu --noconfirm iptables-nft incus",
    )
  '';
}
