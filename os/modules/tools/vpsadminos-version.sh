#! @shell@

show_help() {
    cat <<'EOF'
Usage: vpsadminos-version [--hash|--revision|--json]

Print the vpsAdminOS version.
EOF
}

case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
  --hash|--revision)
    if ! [[ @revision@ =~ ^[0-9a-f]+$ ]]; then
      echo "$0: vpsAdminOS commit hash is unknown" >&2
      exit 1
    fi
    echo "@revision@"
    ;;
  --json)
    cat <<EOF
@json@
EOF
    ;;
  *)
    echo "@version@ (@codeName@)"
    ;;
esac
