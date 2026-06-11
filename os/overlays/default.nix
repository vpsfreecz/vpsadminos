{
  netlinkrb,
  ruby-lxc,
}:
[
  (import ./minify.nix)
  (import ./osctl.nix { inherit netlinkrb ruby-lxc; })
  (import ./packages.nix)
  (import ./ruby.nix)
]
