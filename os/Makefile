# default build (conf.nix and conf_common.nix)
build:
	nix-build \
	 --arg configuration "import ./conf.nix" \
	 --cores 0

# production build (conf_prod.nix and conf_common.nix)
prod:
	nix-build \
	 --arg configuration "import ./conf_prod.nix" \
	 -A config.system.build.tftpdir \
	 -o result_prod \
	 --cores 0 || exit 1

# production build for local testing in QEMU (conf_prod_qemu.nix including conf_prod.nix)
prod-local:
	nix-build \
	 --arg configuration "import ./conf_prod_qemu.nix" \
	 -A config.system.build.runvm \
	 --cores 0 || exit 1

qemu-prod: prod-local
	./result

deploy: prod
	scp -r result_prod/* root@pxe:/srv/www/vpsadminos/

qemu: build
	./result

test:
	nix-build \
	--arg system \"x86_64-linux\" \
	tests/boot.nix
