# Exercise predecessor-owned veth/IFB state across activation, then the
# supported stopped-only interface rename/replacement and live shaper changes.
args: import ./from-6.18.nix (args // { inheritedNetifMutation = true; })
