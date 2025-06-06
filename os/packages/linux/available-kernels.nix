{
  stableKernelVersion = "6.12.29";

  unstableKernelVersion = "6.12.29";

  kernels = {
    "6.12.29" = {
      rev = "e7a0b7edb22842d0188046201ed15217c7239fbf";
      sha256 = "sha256-4IIXcjoT+lipBsIBRncfqPCLDS6/JO068j3qCiZ8zFA=";
      zfs = {
        rev = "e4f44b41c662e46d14462166b96592d0d7635818";
        sha256 = "sha256-D9pEP0NAsZNEXJCA912mE4VMFTSQIHBNx5NU04+W3n0=";
      };
    };
    "6.9.12-2" = {
      rev = "3a74cce5425ef5182df2410e62923b4c0b3ea899";
      sha256 = "sha256-7AhUVFT9AKkkcJPjyEsFz1r4ydk4lGfFUrf0kj2XEB0=";
      zfs = {
        rev = "e81cc7c3efd78a90092e60d239eb93b9174bbf7e";
        sha256 = "sha256-NJwYoTgi3ahis7kzlrjycM7IlDZx2eZFcWGrB0P+0h8=";
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
