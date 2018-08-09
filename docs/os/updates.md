# Updates

It is possible to update running system remotely with `os-rebuild` tool (this tool is similar to `nixos-rebuild`
and accepts most of its parameters). You can build `os-rebuild` from `vpsadminos/os` directory by running:

```bash
make os-rebuild
```

which builds `config.system.build.os-rebuild` target. You can then use this tool to upgrade a `QEMU` instance with:

```bash
NIX_SSHOPTS="-p2222 -i~/.ssh/correctKey" ./result/os-rebuild/bin/os-rebuild switch \
  --build-host localhost \
  --target-host root@127.0.0.1
```
