;; Image builds provide the current configuration with -L.  Installed systems
;; use /etc/config, but it can contain an older module in the builder image.
(eval-when (expand load eval)
  (unless (search-path %load-path "vpsadminos.scm")
    (add-to-load-path "/etc/config")))

;; Current Guix discards this anonymous configuration module before it forces
;; operating-system service fields.  Resolve the platform base from the
;; retained named module at run time, then inherit it to keep user configuration
;; in this file.
(let ((platform-system
       (module-ref (resolve-interface '(vpsadminos))
                   '%ct-operating-system-base)))
  (operating-system
    (inherit platform-system)

    ;; User configuration
    (host-name "guix")
    ;; Servers usually use UTC regardless of the location.
    (timezone "Etc/UTC")
    (locale "en_US.utf8")))
