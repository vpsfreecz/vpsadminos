[
  {
    id = "tcp-stop-failed-migrated-reqsk-timer";
    path = ./patches/tcp-stop-failed-migrated-reqsk-timer.patch;
    fixIds = [ "tcp-reqsk-migration-timer-lifetime" ];
  }
  {
    id = "tcp-refcount-failed-reqsk-cleanup";
    path = ./patches/tcp-refcount-failed-reqsk-cleanup.patch;
    fixIds = [ "tcp-reqsk-refcount-cleanup-preparation" ];
  }
]
