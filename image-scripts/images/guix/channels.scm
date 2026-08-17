(use-modules (guix channels))

(list (channel
       (inherit %default-guix-channel)
       (url "https://git.guix.gnu.org/guix.git")))
