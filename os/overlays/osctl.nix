self: super:
{
  osctl = super.callPackage ../packages/osctl {};
  osctld = super.callPackage ../packages/osctld {};
  osup = super.callPackage ../packages/osup {};
  osctl-template = super.callPackage ../packages/osctl-template {};
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec {};
}
