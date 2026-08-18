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

	pull_guix() {
		local channels="$1"
		local attempt guix_pull_status

		for attempt in 1 2 3; do
			set +e
			guix pull -C "$channels" 2>&1 \
				| tee "$guix_pull_output"
			guix_pull_status=${PIPESTATUS[0]}
			set -e

			if [ "$guix_pull_status" -eq 0 ]; then
				return 0
			fi

			dump_guix_build_logs || true

			if [ "$attempt" -eq 3 ]; then
				return "$guix_pull_status"
			fi

			sleep 30
		done
	}

	guix_pull_output=$(mktemp /tmp/guix-pull.XXXXXXXXXX)
	trap 'rm -f -- "$guix_pull_output"' EXIT

	case "$(guix --version | head -n 1)" in
	*" 1.4.0")
		# Guix 1.4 builds channels with Guile older than 3.0.9, which cannot
		# compile current Guix code using 'spawn'. This authenticated bridge
		# updates the build Guile before the rolling pull. Remove it when the
		# Debian builder moves beyond Guix 1.4.
		pull_guix "$IMAGEDIR/bootstrap-channels-1.4.scm"
		hash guix
		;;
	esac

	pull_guix "$IMAGEDIR/channels.scm"
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
