function image_has_variants {
	local variant="$1"

	[[ "$variant" == *","* ]]
	return $?
}

function image_variants {
	local variant="$1"

	ORIG_IFS="$IFS"

	IFS=","

	for v in $variant; do
		echo "$v"
	done

	IFS="$ORIG_IFS"
}

function image_parse_name {
	local input="$1"

	if [[ "$input" != *'#'* ]]; then
		DIRNAME="$input"
		return 0
	fi

	DIRNAME="${input%%#*}" # before hash
	PARAMETERS="${input#*#}" # after hash

	ORIG_IFS="$IFS"
	IFS='&'

	for kv in $PARAMETERS; do
		IFS='=' read -r key value <<< "$kv"

		case "$key" in
		variant)
			BUILD_VARIANT="$value"
			;;
		*)
			echo "Unsupported image parameter "$key=$value""
			exit 1
			;;
		esac
	done

	IFS="$ORIG_IFS"
}