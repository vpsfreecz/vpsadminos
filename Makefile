BUILD_ID := $(shell date +%Y%m%d%H%M%S)
VERSION := $(shell cat .version)
GEM_VERSION := "$(VERSION).0"
RELEASE_DATE := $(shell date +%Y-%m-%d)

build:
	$(MAKE) -C os build

qemu:
	$(MAKE) -C os qemu

toplevel:
	$(MAKE) -C os toplevel

gems: libosctl osctl-repo osctl osctld osup osctl-image osctl-exporter osctl-exportfs converter svctl test-runner osvm
	echo "$(GEM_VERSION).build$(BUILD_ID)" > .build_id

commit-gems:
	git commit -e -m "os: update gems to $(shell cat .build_id)" .build_id os/packages/*/{Gemfile,Gemfile.lock,gemset.nix}

build-commit-gems: gems
	$(MAKE) commit-gems

amend-gems:
	git commit --amend -e -m "os: update gems to $(shell cat .build_id)" --date=now .build_id os/packages/*/{Gemfile,Gemfile.lock,gemset.nix}

build-amend-gems: gems
	$(MAKE) amend-gems

libosctl:
	./tools/update_gem.sh _nopkg libosctl $(BUILD_ID)

osctl: libosctl
	./tools/update_gem.sh os/packages osctl $(BUILD_ID)

osctld: libosctl osctl-repo osup
	./tools/update_gem.sh os/packages osctld $(BUILD_ID)

osctl-repo: libosctl
	./tools/update_gem.sh os/packages osctl-repo $(BUILD_ID)

osctl-image: libosctl osctl osctl-repo
	./tools/update_gem.sh os/packages osctl-image $(BUILD_ID)

osctl-exporter: libosctl osctl osctl-exportfs
	./tools/update_gem.sh os/packages osctl-exporter $(BUILD_ID)

osctl-exportfs: libosctl
	./tools/update_gem.sh os/packages osctl-exportfs $(BUILD_ID)

osup: libosctl
	./tools/update_gem.sh os/packages osup $(BUILD_ID)

converter: libosctl
	./tools/update_gem.sh _nopkg converter $(BUILD_ID)

svctl: libosctl
	./tools/update_gem.sh os/packages svctl $(BUILD_ID)

test-runner: libosctl osvm
	./tools/update_gem.sh os/packages test-runner $(BUILD_ID)

osvm: libosctl
	./tools/update_gem.sh os/packages osvm $(BUILD_ID)

osctl-env-exec:
	./tools/update_gem.sh os/packages tools/osctl-env-exec $(BUILD_ID)

doc:
	mkdocs build

doc_serve:
	mkdocs serve

version:
	@echo "$(VERSION)" > .version
	@sed -ri "s/nixos-[0-9]+\.[0-9]+/nixos-$(VERSION)/" .github/workflows/*.yml
	@sed -ri "s/nixos-[0-9]+\.[0-9]+/nixos-$(VERSION)/" README.md
	@sed -ri "s/nixos-[0-9]+\.[0-9]+/nixos-$(VERSION)/" docs/user-guide/setup.md
	@sed -ri "s/ [0-9]+\.[0-9]+\.[0-9]+/ $(GEM_VERSION)/" image-scripts/README.md
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osctld/lib/osctld/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osctl/lib/osctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" libosctl/lib/libosctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" converter/lib/vpsadminos-converter/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osctl-exporter/lib/osctl/exporter/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osctl-exportfs/lib/osctl/exportfs/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osctl-repo/lib/osctl/repo/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osctl-image/lib/osctl/image/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osup/lib/osup/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" svctl/lib/svctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" test-runner/lib/test-runner/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(GEM_VERSION)'/" osvm/lib/osvm/version.rb
	@sed -ri "s/VERSION = '[^']+'/VERSION = '$(GEM_VERSION)'/" tools/osctl-env-exec/osctl-env-exec.gemspec
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' osctl/man/man8/osctl.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' osctl-exportfs/man/man8/osctl-exportfs.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' osctl-image/man/man8/osctl-image.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' osctl-repo/man/man8/osctl-repo.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' osup/man/man8/osup.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' osvm/man/man1/osvm.1.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' converter/man/man8/vpsadminos-convert.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' svctl/man/man8/svctl.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(GEM_VERSION)/' test-runner/man/man1/test-runner.1.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl/man/man8/osctl.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl-exportfs/man/man8/osctl-exportfs.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl-image/man/man8/osctl-image.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl-repo/man/man8/osctl-repo.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osup/man/man8/osup.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' converter/man/man8/vpsadminos-convert.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' svctl/man/man8/svctl.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' test-runner/man/man1/test-runner.1.md

migration:
	$(MAKE) -C osup migration

.PHONY: build converter doc doc_serve qemu gems libosctl osctl osctld osctl-repo osctl-exporter osup svctl test-runner osvm osctl-env-exec
.PHONY: commit-gems build-commit-gems amend-gems build-amend-gems
.PHONY: version migration
