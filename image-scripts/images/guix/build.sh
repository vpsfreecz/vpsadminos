. "$IMAGEDIR/config.sh"

. /etc/profile.d/guix.sh

set -e

(
	dump_guix_build_logs() {
		local build_log

		while IFS= read -r build_log; do
			printf 'Guix build log: %s\n' "$build_log" >&2

			if [ ! -r "$build_log" ]; then
				printf 'Unable to read Guix build log: %s\n' "$build_log" >&2
				continue
			fi

			case "$build_log" in
			*.gz)
				gzip -cd -- "$build_log" || true
				;;
			*.bz2)
				bzip2 -cd -- "$build_log" || true
				;;
			*)
				cat -- "$build_log" || true
				;;
			esac
		done < <(
			sed -n "s/.*View build log at '\([^']*\)'\..*/\1/p" \
				"$guix_pull_output" || true
		)

		return 0
	}

	guix_pull_output=$(mktemp /tmp/guix-pull.XXXXXXXXXX)
	trap 'rm -f -- "$guix_pull_output"' EXIT

	for attempt in 1 2 3; do
		set +e
		guix pull -C "$IMAGEDIR/channels.scm" 2>&1 \
			| tee "$guix_pull_output"
		guix_pull_status=${PIPESTATUS[0]}
		set -e

		if [ "$guix_pull_status" -eq 0 ]; then
			exit 0
		fi

		dump_guix_build_logs || true

		if [ "$attempt" -eq 3 ]; then
			exit "$guix_pull_status"
		fi

		sleep 30
	done
)
hash guix

guix system init --verbosity=3 -L "$IMAGEDIR" "$IMAGEDIR"/system.scm "$INSTALL"

mkdir "$INSTALL"/etc/config "$INSTALL"/sbin

cp "$IMAGEDIR"/system.scm "$INSTALL"/etc/config/system.scm
cp "$IMAGEDIR"/vpsadminos.scm "$INSTALL"/etc/config/vpsadminos.scm
cp "$IMAGEDIR"/channels.scm "$INSTALL"/etc/config/channels.scm
chmod u+w \
	"$INSTALL"/etc/config/system.scm \
	"$INSTALL"/etc/config/vpsadminos.scm \
	"$INSTALL"/etc/config/channels.scm

cp "$IMAGEDIR"/sbin-init.scm "$INSTALL"/sbin/init
chmod +x "$INSTALL"/sbin/init
