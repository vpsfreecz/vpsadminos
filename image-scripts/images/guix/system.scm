;; Load vpsAdminOS-specific configuration from /etc/config/vpsadminos.scm
(add-to-load-path "/etc/config")
(use-modules (vpsadminos))

;; System configuration
(use-modules (gnu))
(use-package-modules certs linux ssh)
(use-service-modules ssh)

(operating-system
  (host-name "guix")
  ;; Servers usually use UTC regardless of the location.
  (timezone "Etc/UTC")
  (locale "en_US.utf8")
  (firmware '())
  (initrd-modules '())
  ;; The kernel is not used (this is a container), but needs to be specified
  (kernel %ct-dummy-kernel)

  (packages (cons* nss-certs
                   %base-packages))

  (essential-services (modify-services
                          (operating-system-default-essential-services this-operating-system)
                        (delete firmware-service-type)
                        (delete (service-kind %linux-bare-metal-service))))

  (bootloader %ct-bootloader)

  (file-systems %ct-file-systems)

  (services (cons* (service openssh-service-type
                            (openssh-configuration
                             (openssh openssh-sans-x)
                             (permit-root-login #t)
                             (password-authentication? #t)))
                   %ct-services)))
