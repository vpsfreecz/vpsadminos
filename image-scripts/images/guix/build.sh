. "$IMAGEDIR/config.sh"

set -e

. /etc/profile

(
	dump_guix_build_logs() {
		local command_output="$1"
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
				"$command_output" || true
		)

		return 0
	}

	guix_time_machine_output=$(mktemp /tmp/guix-time-machine.XXXXXXXXXX)
	trap 'rm -f -- "$guix_time_machine_output"' EXIT
	guix_channel_commit=$(
		guix repl -q "$IMAGEDIR/latest-channel-with-substitutes.scm"
	)

	if [[ ! $guix_channel_commit =~ ^[0-9a-f]{40}$ ]]; then
		printf 'Invalid Guix channel commit: %s\n' "$guix_channel_commit" >&2
		exit 1
	fi

	printf 'Using Guix channel revision %s with substitutes\n' \
		"$guix_channel_commit"

	set +e
	guix time-machine -C "$IMAGEDIR/channels.scm" \
		--commit="$guix_channel_commit" -- \
		system init --verbosity=3 -L "$IMAGEDIR" \
		"$IMAGEDIR/system.scm" "$INSTALL" 2>&1 \
		| tee "$guix_time_machine_output"
	guix_time_machine_status=${PIPESTATUS[0]}
	set -e

	if [ "$guix_time_machine_status" -ne 0 ]; then
		dump_guix_build_logs "$guix_time_machine_output"
		exit "$guix_time_machine_status"
	fi
)

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
