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

## Managed public and run repositories

The [osctl-repo-server](../../osctl-repo-server/README.md) component serves this
same v1 protocol from immutable ordinary files and SQLite catalog references.
Public clients retain the repository URL and canonical paths above. A sealed
workflow run uses `/runs/<run-key>` before `v1`, containing its pinned public
baseline plus independently verified replacements. A failed or missing selected
replacement cannot be satisfied by the baseline. Run URLs are unavailable until
sealing and return an explicit expiration response after their lease expires.

The service resolves default/vendor/variant/tag aliases in metadata. It streams
the selected bytes directly, because current clients reconstruct canonical paths
and ignore the pathname values in the index. Public index and image requests are
separate; logical public pruning retains the existing old-index race boundary.
Private run references retain their bytes without keeping pruned public URLs
visible. Logical GC keeps the configured native grouping, matcher order, sorted
version order and keep counts; physical cleanup waits for all retained references.

The service is the sole writer and file-lifetime owner. Native `osctl-repo local`
commands remain useful for offline repositories, but must not mutate managed
storage. Adoption requires excluding legacy writers and validating a coherent
index, payloads and aliases. Portable generation export/import and a static-tree
recovery export are documented with the component; restoring an old rsync tree
without reconciling newer catalog contents is not a supported rollback.
