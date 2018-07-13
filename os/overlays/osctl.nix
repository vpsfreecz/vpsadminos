self: super:
{
  osctl = super.callPackage ../packages/osctl {};
  osctld = super.callPackage ../packages/osctld {};
  osup = super.callPackage ../packages/osup {};
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec {};
}
