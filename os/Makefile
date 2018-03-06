CORES = 0

# default build (conf.nix and conf_common.nix)
build:
	nix-build \
	 --arg configuration "import ./conf.nix" \
	 --cores $(CORES)

# production build (conf_prod.nix and conf_common.nix)
prod:
	nix-build \
	 --arg configuration "import ./conf_prod.nix" \
	 -A config.system.build.tftpdir \
	 -o result_prod \
	 --cores $(CORES) || exit 1

# production build for local testing in QEMU (conf_prod_qemu.nix including conf_prod.nix)
prod-local:
	nix-build \
	 --arg configuration "import ./conf_prod_qemu.nix" \
	 -A config.system.build.runvm \
	 --cores $(CORES) || exit 1

# build iso image
iso:
	nix-build \
	 --arg configuration "import ./conf_iso.nix" \
	 -A config.system.build.isoImage \
	 --cores $(CORES) || exit 1

# build iso image runner
iso-local:
	nix-build \
	 --arg configuration "import ./conf_iso_qemu.nix" \
	 -A config.system.build.runvm \
	 --cores $(CORES) || exit 1

qemu: build
	./result

# boot conf_prod.nix configuration in qemu
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
