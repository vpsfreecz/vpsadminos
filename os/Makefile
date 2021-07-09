CORES = 0

# default build (configs/qemu.nix)
build: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),./configs/qemu.nix) \
	 --out-link result/qemu \
	 --cores $(CORES)

# build the system closure without building the squashfs image
toplevel: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),./configs/qemu.nix) \
	 --attr config.system.build.toplevel \
	 --out-link result/toplevel \
	 --cores $(CORES)

# build iso image
iso: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),"{ imports  = [ ./configs/iso.nix ]; }") \
	 -A config.system.build.isoImage \
	 --out-link result/iso \
	 --cores $(CORES) || exit 1

# build iso image runner
iso-local: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),"{ imports  = [ \
	     ./configs/iso.nix \
	     ./configs/qemu.nix \
	   ]; }") \
	 -A config.system.build.runvm \
	 --out-link result/iso \
	 --cores $(CORES) || exit 1

qemu: build
	./result/qemu

# boot ISO in qemu
qemu-iso: iso-local
	./result/iso

# flash ISO to /dev/disk/by-label/VPSADMINOS_BOOT_CD
flash: iso
	sudo dd if=result/iso/vpsadminos.iso of=/dev/disk/by-label/VPSADMINOS_BOOT_CD bs=1M

# build nixos container template (rootfs tarball)
template:
	nix-build \
	'<nixpkgs/nixos>' \
	--arg configuration ./lib/nixos-container/configuration.nix \
	-A config.system.build.tarball \
	--out-link result/template

os-rebuild:
	nix-build \
	 --arg configuration ./configs/qemu.nix \
	 --out-link result/os-rebuild \
	 --cores $(CORES) \
	 -A config.system.build.os-rebuild

result:
	mkdir -p result
