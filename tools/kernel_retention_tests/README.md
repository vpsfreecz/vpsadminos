# Offline kernel retention fixtures

Run from the repository root:

```sh
python3 -B -m unittest discover -s tools/kernel_retention_tests -v
```

The suite uses reserved `.invalid` host names, an evaluated-catalog-shaped
fixture, and mocked curl and GitHub commands. Transaction tests create and
update Git refs only in disposable local repositories. The suite does not
contact production, need credentials, or run a Nix build.

For manual replay, use the `collect` subcommand of
`python3 tools/kernel-retention.py` with `--fixture`, `--acquired-at` and
`--output <new file>` to project the HaveAPI fixture. Pass that file to
`plan --fleet`, together with `--catalog`, `--base`, `--as-of` and
`--expected-fleet-sha256`. The base SHA labels the catalog snapshot supplied
by the caller; `plan` neither reads Git nor evaluates Nix. It uses the selectors
and the retention dates of `X.Y.Z` entries, ignoring package fields. The
write path also runs the full catalog checker. The plan lists eligible kernels
and gives the reasons for keeping the others. An empty plan means nothing is
eligible; an error exits nonzero and produces no plan.

Calculate the expected digest from the **independent** roster, not the public
response: lowercase the DNS names, strip one trailing dot, reject duplicates,
sort bytewise, and SHA-256 hash the UTF-8 names each followed by one newline.
Keep actual roster names and evidence private. The fixture roster is just
`node.example.invalid` followed by `storage.example.invalid`, each with a
newline.

Without `--fixture`, `collect` uses curl (8.4 or newer for streaming size
limits), performs one anonymous HTTPS request and timestamps the completed
transfer. It saves the projection to a new owner-only file, not to stdout.
Do not put it in the repository, logs or an uploaded artifact; delete it when
finished. Use the fixture mode, not the endpoint, for local verification.
