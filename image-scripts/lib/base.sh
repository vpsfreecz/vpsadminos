function parse_opts {
	getopt --test > /dev/null
	if [ $? -ne 4 ]; then
		echo "Unable to continue, `getopt --test` failed in this environment."
		exit 1
	fi

	local OPTIONS=o:b:d:vh
	local LONGOPTIONS=output-dir:,build-dir:,build-dataset:,verbose,help

	local PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
	[ $? -ne 0 ] && exit 2
	eval set -- "$PARSED"

	while true; do
		case "$1" in
			-v|--verbose)
				VERBOSE=y
				shift
				;;
			-o|--output-dir)
				OUTPUT_DIR="$2"
				shift 2
				;;
			-b|--build-dir)
				BUILD_DIR="$2"
				shift 2
				;;
			-d|--build-dataset)
				BUILD_DATASET="$2"
				shift 2
				;;
			-h|--help)
				usage
				exit
				;;
			--)
		        shift
			    break
				;;
	        *)
	            echo "Programming error"
		        exit 3
			    ;;
		esac
	done

	BUILD_TEMPLATES=$@

	if [ "$BUILD_DATASET" != "" ] ; then
		if [ "$BUILD_DIR" != "" ] ; then
			warn "--build-dir cannot be used with --build-dataset, pick one"
			exit 1
		fi

		BUILD_DIR=$(zfs_mountpoint $BUILD_DATASET)
	fi

	[ "$OUTPUT_DIR" == "" ] && OUTPUT_DIR="."
}

function usage {
	cat <<EOF
Usage: $SELF [options] all|<template...>

Options:

  -v, --verbose             Print build log
  -o, --output-dir DIR      Directory where the built templates are placed
  -b, --build-dir DIR       Directory where the templates are built
  -d, --build-dataset NAME  Build the templates inside given ZFS dataset
  -h, --help                Show this message and exit
EOF
	echo -e "\nAvailable templates:\n"
	echo "$(ls -1 $BASEDIR/templates | sed -e 's/\.sh$//g' -e 's/^/  /')"
}

function build_templates {
	[ ! -d "$BUILD_DIR" ] && mkdir "$BUILD_DIR"
	[ ! -d "$OUTPUT_DIR" ] && mkdir "$OUTPUT_DIR"

	. $INCLUDE/common.sh

	if [ "$*" == "all" ]; then
		local templates=$(ls -1 $BASEDIR/templates | sed 's/\.sh$//g')
	else
		local templates=$*
	fi

	if [ "$templates" == "" ] ; then
		warn "Nothing to do: provide at least one template name"
		exit 1
	fi

	for template in $templates; do
		build_template $template
	done
}

function build_template {
	local template="$1"

	[ ! -f "$BASEDIR/templates/${template}.sh" ] && \
		warn "Unknown template name: $template" && \
		exit 1

	echo "Building $template ..."

	# Prepare the build environment
	local RAND_NAME=$(random_string 5)

	if [ "$BUILD_DATASET" == "" ] ; then
		INSTALL=$(mkdir "$BUILD_DIR/install.$template.$RAND_NAME")
		DOWNLOAD=$(mkdir "$BUILD_DIR/install.download.$template.$RAND_NAME")
	else
		INSTALL_DATASET="$BUILD_DATASET/install.$template.$RAND_NAME"
		DOWNLOAD_DATASET="$BUILD_DATASET/install.download.$template.$RAND_NAME"

		zfs create "$INSTALL_DATASET"
		zfs create "$DOWNLOAD_DATASET"

		INSTALL="$(zfs_mountpoint $INSTALL_DATASET)/private"
		DOWNLOAD="$(zfs_mountpoint $DOWNLOAD_DATASET)/private"

		mkdir "$INSTALL"
		mkdir "$DOWNLOAD"
	fi

	trap cleanup SIGINT

	# Prepare output directory for the builder
	local BUILDER_OUTPUT_DIR="$(mktemp -d $BUILD_DIR/builder.output.$template.XXX)"

	for file in DISTNAME RELVER RELNAME EXTRAVER ARCH OUTPUT_SUFFIX ; do
		touch "$BUILDER_OUTPUT_DIR/$file"
	done

	# Call the builder
	if [ "$VERBOSE" == "y" ] ; then
		"$BASEDIR/bin/builder" "$BASEDIR" \
		                       "$INSTALL" \
							   "$DOWNLOAD" \
							   "$BUILDER_OUTPUT_DIR" \
							   "$template"
	else
		local LOGFILE="$(mktemp $BUILD_DIR/$template.XXX.log)"
		echo "Build log file $LOGFILE"

		"$BASEDIR/bin/builder" "$BASEDIR" \
		                       "$INSTALL" \
							   "$DOWNLOAD" \
							   "$BUILDER_OUTPUT_DIR" \
							   "$template" \
                               &> "$LOGFILE"

		if [ "$?" != 0 ] ; then
			warn "Failed to build $template, see $LOGFILE"
			cleanup
			exit 1
		fi

		rm -f "$LOGFILE"
	fi

	# Load the builder's output
	local DISTNAME="$(cat "$BUILDER_OUTPUT_DIR/DISTNAME")"
	local RELVER="$(cat "$BUILDER_OUTPUT_DIR/RELVER")"
	local RELNAME="$(cat "$BUILDER_OUTPUT_DIR/RELNAME")"
	local EXTRAVER="$(cat "$BUILDER_OUTPUT_DIR/EXTRAVER")"
	local ARCH="$(cat "$BUILDER_OUTPUT_DIR/ARCH")"
	local OUTPUT_SUFFIX="$(cat "$BUILDER_OUTPUT_DIR/OUTPUT_SUFFIX")"

	[ "$EXTRAVER" != "" ] && \
		OUTPUT_SUFFIX="-$EXTRAVER"

	TPL_NAME=$DISTNAME-$RELVER-$ARCH-${VENDOR}${OUTPUT_SUFFIX}

	# Generate outputs
	pack "$TPL_NAME.tar.gz" "$INSTALL"
	[ "$BUILD_DATASET" != "" ] && \
		dump_stream "$TPL_NAME.dat.gz" "$INSTALL_DATASET"@template
	cleanup
}

function random_string {
	local LENGTH="$1"
	cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $LENGTH | head -n 1
}

function zfs_mountpoint {
	local DS="$1"
	zfs get -H -o value mountpoint $DS
}
