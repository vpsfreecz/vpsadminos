args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "ipv4-fib-rebalance-zero-weight";
      oracleId = "ipv4-fib-rebalance-operation-safety";
      toolName = "ipv4-fib-rebalance-operation";
      operationLabel = "IPv4 multipath route rebalance";
      kernelModules = [

      ];
      extraPackages = [ ];
      cleanupFixture = ''
        ip netns del lp-fib >/dev/null 2>&1 || true
      '';
      setupFixture = ''
        cleanup_fixture
        ip netns add lp-fib
        ip -n lp-fib link set lo up
        ip -n lp-fib link add fib0 type dummy
        ip -n lp-fib link add fib1 type dummy
        ip -n lp-fib link set fib0 up
        ip -n lp-fib link set fib1 up
      '';
      oneIteration = ''
        ip -n lp-fib route replace 198.51.100.0/24 nexthop dev fib0 weight 1 nexthop dev fib1 weight 2
        ip -n lp-fib link set fib0 down
        ip -n lp-fib link set fib0 up
        ip -n lp-fib route replace 198.51.100.0/24 nexthop dev fib0 weight 2 nexthop dev fib1 weight 1
        ip -n lp-fib route del 198.51.100.0/24
      '';
    };
  }
)
