CORES = 0
VPSADMIN = ../../vpsadmin
VPSADMIN_ABSPATH := $(shell readlink -m "$(VPSADMIN)")

# default build (configs/default.nix)
build: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),./configs/default.nix) \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 --out-link result/qemu \
	 --cores $(CORES)

# production build (configs/prod.nix)
prod: result
	nix-build \
	 --arg configuration "{ imports  = [ ./configs/prod.nix ]; }" \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.tftpdir \
	 --out-link result/prod \
	 --cores $(CORES) || exit 1

# production build for local testing in QEMU (configs/prod.nix)
prod-local: result
	nix-build \
	 --arg configuration "{ imports  = [ ./configs/prod.nix ./configs/qemu.nix ]; }" \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.runvm \
	 --out-link result/prod \
	 --cores $(CORES) || exit 1

# build the system closure without building the squashfs image
toplevel: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),./configs/default.nix) \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 --attr config.system.build.toplevel \
	 --out-link result/toplevel \
	 --cores $(CORES)

# build iso image
iso: result
	nix-build \
	 --arg configuration $(or $(VPSADMINOS_CONFIG),"{ imports  = [ ./configs/iso.nix ]; }") \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
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
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.runvm \
	 --out-link result/iso \
	 --cores $(CORES) || exit 1

qemu: build
	./result/qemu

# boot configs/prod.nix configuration in qemu
qemu-prod: prod-local
	./result/prod

# boot ISO in qemu
qemu-iso: iso-local
	./result/iso

# flash ISO to /dev/disk/by-label/VPSADMINOS_BOOT_CD
flash: iso
	sudo dd if=result/iso/vpsadminos.iso of=/dev/disk/by-label/VPSADMINOS_BOOT_CD bs=1M

# boot iso image in qemu
deploy: prod
	scp -r result/prod/* root@pxe:/srv/www/vpsadminos/

test:
	nix-build \
	--arg system \"x86_64-linux\" \
	tests/boot.nix

# build nixos container template (rootfs tarball)
template:
	nix-build \
	'<nixpkgs/nixos>' \
	--arg configuration ./lib/nixos-container/configuration.nix \
	-A config.system.build.tarball \
	--out-link result/template

os-rebuild:
	nix-build \
	 --arg configuration ./configs/default.nix \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 --out-link result/os-rebuild \
	 --cores $(CORES) \
	 -A config.system.build.os-rebuild

result:
	mkdir -p result
