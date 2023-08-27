;; Load vpsAdminOS-specific configuration from /etc/config/vpsadminos.scm
(add-to-load-path "/etc/config")
(use-modules (vpsadminos))

;; System configuration
(use-modules (gnu) (gnu system locale))
(use-service-modules admin networking shepherd ssh sysctl)
(use-package-modules certs ssh bash package-management vim)

(operating-system
 (host-name "guix")
 (timezone "Europe/Amsterdam")
 (locale "en_US.utf8")
 (firmware `())
 (initrd-modules `())
 (kernel hello)
 (packages (append (list vim) %ct-packages))

 (essential-services (modify-services
                      (operating-system-default-essential-services this-operating-system)
                      (delete firmware-service-type)
                      (delete (service-kind %linux-bare-metal-service))))

 (locale-definitions (list (locale-definition
                            (name "en_US.utf8")
                            (source "en_US")
                            (charset "UTF-8"))))

 (bootloader %ct-bootloader)

 (file-systems %ct-file-systems)

 (services (append (list
                    (service openssh-service-type
                          (openssh-configuration
                           (openssh openssh-sans-x)
			   (permit-root-login #true)
			   (password-authentication? #true)))
		    ) %ct-services)))
