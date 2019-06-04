self: super:
{
  osctl = super.callPackage ../packages/osctl {};
  osctld = super.callPackage ../packages/osctld {};
  osup = super.callPackage ../packages/osup {};
  osctl-image = super.callPackage ../packages/osctl-image {};
  osctl-repo = super.callPackage ../packages/osctl-repo {};
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec {};
}
