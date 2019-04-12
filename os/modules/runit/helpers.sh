function warn {
  echo "$@" 1>&2
}

function fail {
  warn "$@"
  exit 1
}

function osctldStarted {
  @osctl@ ping &> /dev/null
}

function waitForOsctld {
 until osctldStarted ; do
   warn "Waiting for osctld to respond"
   sleep 1
 done
}

function ensureOsctldStarted {
  osctldStarted || fail "Waiting for osctld to start"
}

function osctlEntityExists {
  local entity="$1"
  local ident="$2"

  case "$entity" in
    pool|user|group|repository|id-range)
      @osctl@ "$entity" show -o name "$ident" &> /dev/null
      return $?
      ;;
    ct|container)
      @osctl@ ct show -o id "$ident" &> /dev/null
      return $?
      ;;
    *)
      warn "Unknown osctl entity '$entity'"
      return 1
      ;;
  esac
}

function waitForOsctlEntity {
  local entity="$1"
  local ident="$2"

  until osctlEntityExists "$entity" "$ident" ; do
    warn "Waiting for osctl $entity $ident"
    sleep 1
  done
}

function ensureOsctlEntityExists {
  local entity="$1"
  local ident="$2"

  osctlEntityExists "$entity" "$ident" && return 0
  fail "osctl $entity $ident not found, aborting"
}

function serviceStarted {
  local service="$1"

  sv check "$service" > /dev/null
}

function waitForService {
  local service="$1"

  until serviceStarted "$service" ; do
    warn "Waiting for service $service to start"
    sleep 1
  done
}

function ensureServiceStarted {
  local service="$1"

  serviceStarted "$service" && return 0
  fail "Service $service not started, aborting"
}
