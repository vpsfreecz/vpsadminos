# Container image repository
Images are served via HTTP. The directory structure, relative to the
repository's URL, is:

    .
    └── <schema version>/
        ├── <vendor>/
        │   ├── default -> <variant>
        │   └── <variant>/
        │       └── <arch>/
        │           └── <distribution>/
        │               ├── <tag> -> <version>
        │               └── <version>/
        │                   └── image-{archive,stream}.tar
        ├── default -> <vendor>
        └── INDEX.json

`default` entries are symlinks to the default `vendor` and `variant` directories,
which the client can use when he has no particular requirements.

`tag` is a symlink to specific distribution version, common tags include:

 - *stable*
 - *unstable*
 - *latest*
 - *testing*

# Index file
The index file, located at `./INDEX.json`, contains a list of all available
images. The file is formatted in JSON.

## Example
```json
{
    "vendors": {
        "default": "vpsadminos",
        "vpsadminos": "minimal"
    },
    "images": [
        {
            "vendor": "vpsadminos",
            "variant": "minimal",
            "arch": "x86_64",
            "distribution": "debian",
            "version": "9",
            "tags": ["stable", "latest"],
            "image": {
                "tar": "vpsadminos/minimal/x86_64/debian/9/image-archive.tar",
                "zfs": "vpsadminos/minimal/x86_64/debian/9/image-stream.tar"
            }
        }
    ]
}
```
