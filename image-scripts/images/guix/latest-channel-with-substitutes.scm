(use-modules (guix channels)
             (guix ci))

(let* ((channel (channel-with-substitutes-available
                 %default-guix-channel
                 "https://ci.guix.gnu.org"))
       (commit (channel-commit channel)))
  (unless commit
    (error "no Guix channel revision with substitutes is available"))

  (display commit)
  (newline))
