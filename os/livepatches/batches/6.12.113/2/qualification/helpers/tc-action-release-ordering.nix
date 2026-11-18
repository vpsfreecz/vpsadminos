args@{ pkgs, ... }:

import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "tc-action-release-ordering";
      oracleId = "tc-action-lifecycle-operation-safety";
      toolName = "tc-action-lifecycle-operation";
      operationLabel = "traffic-control action create use and delete";
      kernelModules = [
        "act_gact"
        "cls_flower"
      ];
      extraPackages = [ ];
      cleanupFixture = ''
        ip netns del lp-tc >/dev/null 2>&1 || true
      '';
      setupFixture = ''
        cleanup_fixture
        ip netns add lp-tc
        ip -n lp-tc link add tca type veth peer name tcb
        ip -n lp-tc addr add 192.0.2.9/30 dev tca
        ip -n lp-tc addr add 192.0.2.10/30 dev tcb
        ip -n lp-tc link set lo up
        ip -n lp-tc link set tca up
        ip -n lp-tc link set tcb up
      '';
      oneIteration = ''
        ip netns exec lp-tc tc qdisc replace dev tca clsact
        ip netns exec lp-tc tc filter replace dev tca ingress pref 10 protocol ip flower action pass
        ip netns exec lp-tc ping -q -c 1 -W 2 192.0.2.10 >/dev/null
        ip netns exec lp-tc tc filter del dev tca ingress pref 10
        ip netns exec lp-tc tc qdisc del dev tca clsact
      '';
    };
  }
)
