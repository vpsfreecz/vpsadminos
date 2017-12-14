NIXPKGS=$(NIX_PATH)/nixpkgs

build:
	$(MAKE) -C os build

qemu:
	$(MAKE) -C os qemu

gems: osctl osctld

osctl:
	./tools/update_gem.sh "$(NIXPKGS)" osctl

osctld:
	./tools/update_gem.sh "$(NIXPKGS)" osctld

.PHONY: build qemu gems osctl osctld all
