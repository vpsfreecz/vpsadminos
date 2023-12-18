;; Configuration specific for containers on vpsAdminOS
;;
;; If you're experiencing issues, try updating this file to the latest version
;; from vpsAdminOS repository:
;;
;;  https://github.com/vpsfreecz/vpsadminos/blob/staging/image-scripts/images/guix/vpsadminos.scm
;;
(define-module (vpsadminos)
  #:export (%ct-bootloader
            %ct-dummy-kernel
            %ct-file-systems
            %ct-packages
            %ct-services))

(use-modules (gnu)
             (gnu packages)
             (guix build-system trivial)
             (guix gexp)
             (guix packages))

(use-modules (vpsadminos))
(use-service-modules admin networking shepherd ssh sysctl)
(use-package-modules certs ssh bash package-management)

;;; The bootloader is not required.  This is running inside a container, and the
;;; start menu is populated by parsing /var/guix/profiles.  However bootloader
;;; is a mandatory field, and the typical grub-bootloader requires users to
;;; always pass the --no-bootloader flag.  By providing this bootloader
;;; configuration (it does not do anything, but installs fine), we remove the
;;; need to remember to pass the flag.  At the cost of ~8MB in /boot.
(define %ct-bootloader
  (bootloader-configuration
   (bootloader grub-efi-netboot-removable-bootloader)
   (targets '("/boot"))))

(define %ct-dummy-kernel
  (package
    (name "dummy-kernel")
    (version "1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder #~(mkdir #$output)))
    (synopsis "Dummy kernel")
    (description
     "In container environment, the kernel is provided by the host.  However we
still need to specify a kernel in the operating-system definition, hence this
package.")
    (home-page #f)
    (license #f)))

(define %ct-file-systems
  (list
   ;; Immutable store
   (file-system
     (device "/gnu/store")
     (mount-point "/gnu/store")
     (type "none")
     (check? #f)
     (flags '(read-only bind-mount)))
   ;; Shared memory file system
   (file-system
     (device "tmpfs")
     (mount-point "/dev/shm")
     (type "tmpfs")
     (flags '(no-exec no-suid no-dev))
     (options "mode=1777,size=65536k")
     (create-mount-point? #t)
     (check? #f))
   ;; Dummy rootfs
   (file-system
     (device "/dev/null")
     (mount-point "/")
     (type "dummy"))))

;; Extended list of %base-packages from
;;
;;   https://git.savannah.gnu.org/cgit/guix.git/tree/gnu/system.scm
(define %ct-packages
  (cons* le-certs
         %base-packages))

;; Service which runs network configuration script generated by osctld
;; from vpsAdminOS
(define vpsadminos-networking
  (shepherd-service
   (provision '(vpsadminos-networking loopback))
   (documentation "Setup network on vpsAdminOS")
   (one-shot? #t)
   (start #~(lambda _ (invoke #$(file-append bash "/bin/bash") "/ifcfg.add")))))

;; Modified %base-services from
;;
;;  https://git.savannah.gnu.org/cgit/guix.git/tree/gnu/services/base.scm
;;
;; We start mingetty only on /dev/console and add our own service to handle
;; networking.
(define %ct-services
  (list (service login-service-type)

        (service virtual-terminal-service-type)

        (service syslog-service-type)

        (service mingetty-service-type (mingetty-configuration
                                        (tty "console")))

        (simple-service 'vpsadminos-networking shepherd-root-service-type (list vpsadminos-networking))

        ;; dhcp provisions 'networking and it is useful for development setup.
        ;; Maybe in the future we could handle it by 'vpsadminos-networking
        ;; and to run dhcp only when there is an actual interface.
        (service dhcp-client-service-type)

        (service guix-service-type)
        (service nscd-service-type)

        (service rottlog-service-type)

        ;; Periodically delete old build logs.
        (service log-cleanup-service-type
                 (log-cleanup-configuration
                  (directory "/var/log/guix/drvs")))

        ;; Inside a container, we do not need any udev rules
        (service udev-service-type (udev-configuration (rules '())))

        (service sysctl-service-type)

        (service special-files-service-type
                 `(("/bin/sh" ,(file-append bash "/bin/sh"))
                   ("/usr/bin/env" ,(file-append coreutils "/bin/env"))))))
