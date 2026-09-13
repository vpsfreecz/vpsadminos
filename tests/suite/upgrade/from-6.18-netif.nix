# Exercise predecessor-owned veth/IFB state across activation, fail-closed
# live IFB loss and explicit recovery, then supported stopped-only interface
# replacement and live shaper changes. Running rename remains unsupported.
args: import ./from-6.18.nix (args // { inheritedNetifMutation = true; })
