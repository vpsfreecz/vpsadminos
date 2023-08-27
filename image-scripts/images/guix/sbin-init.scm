#!/var/guix/profiles/system/profile/bin/guile \
--no-auto-compile -q -e main -s
!#
; This is an /sbin/init file for Guix on vpsAdminOS containers
(define (main args)
  (setenv "GUIX_NEW_SYSTEM" "/var/guix/profiles/system")
  (execl "/var/guix/profiles/system/profile/bin/guile" "guile" "/var/guix/profiles/system/boot"))
