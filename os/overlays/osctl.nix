self: super:
{
  osctl = super.callPackage ../packages/osctl {};
  osctld = super.callPackage ../packages/osctld {};
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec {};
}
