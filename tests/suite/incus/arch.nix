import ./base.nix {
  distribution = "arch";
  tests = [
    {
      version = "latest";
      mapBase = 1000000;
      # Arch currently ships Incus 7.0.0, which always enables LXC core
      # scheduling using lxc.sched.core=1. vpsAdminOS does not provide
      # CONFIG_SCHED_CORE, so inner containers fail to start with
      # "The kernel does not support core scheduling".
      #
      # Upstream fixed this by reintroducing runtime core-scheduling detection:
      # https://github.com/lxc/incus/pull/3311
      # https://github.com/lxc/incus/issues/3304
      # https://github.com/lxc/incus/commit/1e6ce18
      #
      # We confirmed that raw.lxc="lxc.sched.core = 0" works around the issue,
      # but keep the test as an expected failure until Arch packages an Incus
      # release with the upstream fix, then revert this marker.
      expectFailure = true;
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
