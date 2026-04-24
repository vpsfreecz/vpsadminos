TMPDIR=$(mktemp -d)
INPUT="$TMPDIR/input"
OUTPUT="$TMPDIR/output"
CONSOLE_PID=

function cleanup {
	exec 3>&- 2>/dev/null || true

	if [ -n "$CONSOLE_PID" ] && kill -0 "$CONSOLE_PID" 2>/dev/null ; then
		kill "$CONSOLE_PID" 2>/dev/null || true
		wait "$CONSOLE_PID" 2>/dev/null || true
	fi

	rm -rf "$TMPDIR"
}

function has_login_prompt {
	grep -aq "login:" "$OUTPUT"
}

function print_console_output {
	echo "Console output:"
	cat -v "$OUTPUT"
}

trap cleanup EXIT

mkfifo "$INPUT" || fail "unable to create console input fifo"

osctl -j ct console "$CTID" < "$INPUT" > "$OUTPUT" 2>&1 &
CONSOLE_PID=$!

exec 3> "$INPUT"
rm -f "$INPUT"

sleep 1

if ! kill -0 "$CONSOLE_PID" 2>/dev/null ; then
	print_console_output
	fail "unable to attach to container console"
fi

osctl ct start "$CTID" || fail "unable to start container"

for i in {1..120} ; do
	has_login_prompt && exit 0

	if ! kill -0 "$CONSOLE_PID" 2>/dev/null ; then
		print_console_output
		fail "container console disconnected before login prompt appeared"
	fi

	sleep 1
done

print_console_output
fail "login prompt not found on container console"
