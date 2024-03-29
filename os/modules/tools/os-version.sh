#! @shell@

case "$1" in
  -h|--help)
    exec man os-version
    exit 1
    ;;
  --hash|--revision)
    echo "@revision@"
    ;;
  *)
    echo "@version@ (@codeName@)"
    ;;
esac
