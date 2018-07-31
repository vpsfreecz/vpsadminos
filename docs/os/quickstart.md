# Quick start

Clone required repositories and prepare environment:

```bash
git clone https://github.com/vpsfreecz/vpsadminos/
cd vpsadminos

# temporarily this needs vpsadminos branch from vpsfreecz/nixpkgs
git clone https://github.com/vpsfreecz/nixpkgs --branch vpsadminos

# set NIX_PATH so vpsadminos can locate nixpkgs
export NIX_PATH=`pwd`
```

Create your `local.nix` configuration file based on `local.nix.sample` provided in `os/configs/` directory:

```
cd os
cp configs/local.nix.sample configs/local.nix
```

Edit `configs/local.nix` to suite your needs - you can set `SSH` keys or add additional software to the `os`.

To test the `os` in `QEMU` you can now run:

```
make qemu
```

Continue with `osctl` examples from login welcome message.
