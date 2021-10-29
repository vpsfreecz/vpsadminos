self: super:
{
  mbuffer = super.mbuffer.overrideAttrs (oldAttrs: rec {
    version = "20211018";

    src = super.fetchurl {
      url = "http://www.maier-komor.de/software/mbuffer/mbuffer-${version}.tgz";
      sha256 = "sha256:1qxnbpyly00kml3sjan9iqg6pqacsi3yqq66x25w455cwkjc2h72";
    };

    nativeBuildInputs = [ super.which ];
  });
}
