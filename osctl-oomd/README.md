# osctl-oomd

`osctl-oomd` restarts or stops containers that meet configured memory, CPU and
load conditions when the host shows distress. The normal trigger is host load;
an optional RTNL watchdog can activate the same checks earlier and temporarily
lower the restart threshold.

On vpsAdminOS, enable the daemon with:

```nix
{
  osctl.oomd.enable = true;
}
```

The daemon can restart or stop containers automatically. Install matching
sampler, watchdog and guarded daemon/client components before enabling its
optional watchdog policy. NFS cancellation and force-kill retain their existing
order; shared kernel locks can still block an action.

- [Policy, configuration, guarded actions and recovery](../docs/os/oomd.md)
- [Standalone RTNL watchdog and Prometheus metrics](../docs/os/rtnl-watchdog.md)
