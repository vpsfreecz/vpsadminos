(use-modules (guix channels))

;; Last authenticated revision before (guix ui) started requiring Guile's
;; 'spawn' binding. Its self-build uses a new enough Guile for the rolling pull.
(list (channel
       (inherit %default-guix-channel)
       (url "https://git.guix.gnu.org/guix.git")
       (commit "6c03bb1da2b81bb5b1ebf4e6942bee2454b5950a")))
