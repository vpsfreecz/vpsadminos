CORES = 0
VPSADMIN = ../../vpsadmin
VPSADMIN_ABSPATH := $(shell readlink -m "$(VPSADMIN)")

# default build (configs/default.nix)
build:
	nix-build \
	 --arg configuration ./configs/default.nix \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 --cores $(CORES)

# production build (configs/prod.nix)
prod:
	nix-build \
	 --arg configuration "{ imports  = [ ./configs/prod.nix ]; }" \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.tftpdir \
	 -o result_prod \
	 --cores $(CORES) || exit 1

# production build for local testing in QEMU (configs/prod.nix)
prod-local:
	nix-build \
	 --arg configuration "{ imports  = [ ./configs/prod.nix ./configs/qemu.nix ]; }" \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.runvm \
	 --cores $(CORES) || exit 1

# build iso image
iso:
	nix-build \
	 --arg configuration "{ imports  = [ ./configs/iso.nix ]; }" \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.isoImage \
	 --cores $(CORES) || exit 1

# build iso image runner
iso-local:
	nix-build \
	 --arg configuration "{ imports  = [ ./configs/iso.nix ./configs/qemu.nix ]; }" \
	 --arg vpsadmin "$(VPSADMIN_ABSPATH)" \
	 -A config.system.build.runvm \
	 --cores $(CORES) || exit 1

qemu: build
	./result

# boot configs/prod.nix configuration in qemu
qemu-prod: prod-local
	./result

# boot ISO in qemu
qemu-iso: iso-local
	./result

# flash ISO to /dev/disk/by-label/VPSADMINOS_BOOT_CD
flash: iso
	sudo dd if=result/iso/vpsadminos.iso of=/dev/disk/by-label/VPSADMINOS_BOOT_CD bs=1M

# boot iso image in qemu
deploy: prod
	scp -r result_prod/* root@pxe:/srv/www/vpsadminos/

test:
	nix-build \
	--arg system \"x86_64-linux\" \
	tests/boot.nix

# build nixos container template (rootfs tarball)
template:
	nix-build \
	'<nixpkgs/nixos>' \
	--arg configuration ./lib/nixos-container/configuration.nix \
	-A config.system.build.tarball
