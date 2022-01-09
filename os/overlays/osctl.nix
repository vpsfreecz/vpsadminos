self: super:
{
  ctstartmenu = super.callPackage ../packages/ctstartmenu {};
  osctl = super.callPackage ../packages/osctl {};
  osctld = super.callPackage ../packages/osctld {};
  osup = super.callPackage ../packages/osup {};
  osctl-exporter = super.callPackage ../packages/osctl-exporter {};
  osctl-exportfs = super.callPackage ../packages/osctl-exportfs {};
  osctl-image = super.callPackage ../packages/osctl-image {};
  osctl-repo = super.callPackage ../packages/osctl-repo {};
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec {};
}
