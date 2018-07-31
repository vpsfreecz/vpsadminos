#! @shell@

case "$1" in
  -h|--help)
    exec man os-version
    exit 1
    ;;
  --hash|--revision)
    echo "@osRevision@"
    ;;
  *)
    echo "@osVersion@ (@osCodeName@)"
    ;;
esac
