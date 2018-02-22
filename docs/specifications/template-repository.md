# Template repository
Templates are served via HTTP. The directory structure, relative to the
repository's URL, is:

    .
    ├── <vendor>/
    │   ├── default -> <variant>
    │   └── <variant>/
    │       └── <arch>/
    │           └── <distribution>/
    │               ├── <tag> -> <version>
    │               └── <version>/
    │                   └── rootfs.{dat,tar}.gz
    ├── default -> <vendor>
    └── INDEX.json

`default` entries are symlinks to the default `vendor` and `variant` directories,
which the client can use when he has no particular requirements.

`tag` is a symlink to specific distribution version, it can be one of:

 - *stable*
 - *latest*
 - *testing*

# Index file
The index file, located at `./INDEX.json`, contains a list of all available
templates. The file is formatted in JSON.

## JSON Schema
TODO

## Example
```json
{
    "vendors": {
        "default": "vpsadminos",
        "vpsadminos": "minimal"
    },
    "templates": [
        {
            "vendor": "vpsadminos",
            "variant": "minimal",
            "arch": "x86_64",
            "distribution": "debian",
            "version": "9.0",
            "tags": ["stable", "latest"],
            "rootfs": {
                "tar": "vpsadminos/minimal/x86_64/debian/9.0/rootfs.tar.gz",
                "zfs": "vpsadminos/minimal/x86_64/debian/9.0/rootfs.dat.gz"
            }
        }
    ]
}
```
