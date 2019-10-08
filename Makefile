BUILD_ID := $(shell date +%Y%m%d%H%M%S)
VERSION := $(shell cat .version)
RELEASE_DATE := $(shell date +%Y-%m-%d)

build:
	$(MAKE) -C os build

qemu:
	$(MAKE) -C os qemu

toplevel:
	$(MAKE) -C os toplevel

gems: libosctl osctl-repo osctl osctld osup osctl-image osctl-exporter osctl-exportfs converter svctl
	echo "$(VERSION).build$(BUILD_ID)" > .build_id

libosctl:
	./tools/update_gem.sh _nopkg libosctl $(BUILD_ID)

osctl: libosctl
	./tools/update_gem.sh os/packages osctl $(BUILD_ID)

osctld: libosctl osup
	./tools/update_gem.sh os/packages osctld $(BUILD_ID)

osctl-repo: libosctl
	./tools/update_gem.sh os/packages osctl-repo $(BUILD_ID)

osctl-image: libosctl osctl osctl-repo
	./tools/update_gem.sh os/packages osctl-image $(BUILD_ID)

osctl-exporter: libosctl osctl
	./tools/update_gem.sh os/packages osctl-exporter $(BUILD_ID)

osctl-exportfs: libosctl
	./tools/update_gem.sh os/packages osctl-exportfs $(BUILD_ID)

osup: libosctl
	./tools/update_gem.sh os/packages osup $(BUILD_ID)

converter: libosctl
	./tools/update_gem.sh _nopkg converter $(BUILD_ID)

svctl: libosctl
	./tools/update_gem.sh os/packages svctl $(BUILD_ID)

osctl-env-exec:
	./tools/update_gem.sh os/packages tools/osctl-env-exec $(BUILD_ID)

doc:
	mkdocs build

doc_serve:
	mkdocs serve

version:
	@echo "$(VERSION)" > .version
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctld/lib/osctld/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl/lib/osctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" libosctl/lib/libosctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" converter/lib/vpsadminos-converter/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl-exporter/lib/osctl/exporter/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl-exportfs/lib/osctl/exportfs/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl-repo/lib/osctl/repo/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl-image/lib/osctl/image/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osup/lib/osup/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" svctl/lib/svctl/version.rb
	@sed -ri "s/VERSION = '[^']+'/VERSION = '$(VERSION)'/" tools/osctl-env-exec/osctl-env-exec.gemspec
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' osctl/man/man8/osctl.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' osup/man/man8/osup.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' converter/man/man8/vpsadminos-convert.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' svctl/man/man8/svctl.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl/man/man8/osctl.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl-exportfs/man/man8/osctl-exportfs.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl-image/man/man8/osctl-image.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl-repo/man/man8/osctl-repo.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osup/man/man8/osup.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' converter/man/man8/vpsadminos-convert.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' svctl/man/man8/svctl.8.md

migration:
	$(MAKE) -C osup migration

.PHONY: build converter doc doc_serve qemu gems libosctl osctl osctld osctl-repo osctl-exporter osup svctl osctl-env-exec
.PHONY: version migration
