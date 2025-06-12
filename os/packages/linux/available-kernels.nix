{
  stableKernelVersion = "6.12.33";

  unstableKernelVersion = "6.12.33";

  kernels = {
    "6.12.33" = {
      rev = "0655f700a3545ee3a865824694b77c0d2928f17d";
      sha256 = "sha256-2D8OZsXEW3BJODxDTutV8kjCNRnJG+KKk7t8YtJoLdE=";
      zfs = {
        rev = "6546b7270e6c44e7e90fd5fa4dcb2eaba04b0de2";
        sha256 = "sha256-EFSCMEAN8XYVb+k1khXMJki4HsWkWbaH9VtXlwJINjU=";
      };
    };
    "6.6.21" = {
      rev = "86e0c00fd80469aea354b9fc4ca5913d33ea0d92";
      sha256 = "sha256-zJHOmvyBr0aR97boNZHtfBJviqpmv69RNKqR6eBkJ9A=";
      zfs = {
        rev = "5ee3b2fc6eba2df3b2a4501ccf6c469ebd7889ed";
        sha256 = "sha256-jebuLXVqFPoASF4OptpcCHPSvynGIHiIZgw+nDHtGeU=";
      };
    };
  };
}
