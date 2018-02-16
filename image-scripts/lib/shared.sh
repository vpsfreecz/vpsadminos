function warn {
	>&2 echo "$@"
}

function cleanup {
	echo "Cleanup ..."

	if [ "$BUILD_DATASET" == "" ] ; then
		rm -Rf "$INSTALL"
		rm -Rf "$DOWNLOAD"
	else
		zfs destroy "$INSTALL_DATASET"@template
		zfs destroy "$INSTALL_DATASET"
		zfs destroy "$DOWNLOAD_DATASET"
	fi

	rm -rf "$BUILDER_OUTPUT_DIR"
}
