CORES = 0
JOBS = 2
TEMPLATE_CHANNEL = stable
OS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(OS_DIR)/..)
NIX ?= nix
OUTPUT ?= toplevel
NIX_IMPURE =

ifneq ($(VPSADMINOS_CONFIG),)
  export VPSADMINOS_CONFIG
  NIX_IMPURE = --impure
endif

ifeq ($(DEBUG),0)
  TRACE =
else
  TRACE = --show-trace
endif

# default build (configs/qemu.nix)
build: result
	$(NIX) build $(NIX_IMPURE) \
	 --out-link result/qemu \
	 --cores $(CORES) -j $(JOBS) $(TRACE) \
	 $(ROOT)#qemu

# build the system closure without building the squashfs image
toplevel: result
	$(NIX) build $(NIX_IMPURE) \
	 --out-link result/toplevel \
	 --cores $(CORES) $(TRACE) \
	 $(ROOT)#$(OUTPUT)

# build iso image
iso: result
	$(NIX) build $(NIX_IMPURE) \
	 --out-link result/iso \
	 --cores $(CORES) $(TRACE) \
	 $(ROOT)#iso || exit 1

# build iso image runner
iso-local: result
	$(NIX) build $(NIX_IMPURE) \
	 --out-link result/iso \
	 --cores $(CORES) $(TRACE) \
	 $(ROOT)#iso-local || exit 1

qemu: build
	./result/qemu

# boot ISO in qemu
qemu-iso: iso-local
	./result/iso

build-qemu-script:
	$(NIX) build $(NIX_IMPURE) \
	 --out-link result/qemu-script \
	 --cores $(CORES) -j $(JOBS) $(TRACE) \
	 $(ROOT)#qemu-script

qemu-script: build-qemu-script
	./result/qemu-script

# flash ISO to /dev/disk/by-label/VPSADMINOS_BOOT_CD
flash: iso
	sudo dd if=result/iso/vpsadminos.iso of=/dev/disk/by-label/VPSADMINOS_BOOT_CD bs=1M

# build nixos container template (rootfs tarball)
template:
	$(NIX) build \
	 --out-link result/template \
	 --cores $(CORES) $(TRACE) \
	 $(ROOT)#template-$(TEMPLATE_CHANNEL)

template-impermanence:
	$(NIX) build \
	 --out-link result/template-impermanence \
	 --cores $(CORES) $(TRACE) \
	 $(ROOT)#template-impermanence-$(TEMPLATE_CHANNEL)

os-rebuild:
	$(NIX) build $(NIX_IMPURE) \
	 --out-link result/os-rebuild \
	 --cores $(CORES) $(TRACE) \
	 $(ROOT)#os-rebuild

result:
	mkdir -p result
