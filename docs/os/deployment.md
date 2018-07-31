# Deployment

`vpsAdminOS` is designed for netboot deployment where each machine has its own image
hosted on a netboot server. Machine runs the image from `RAM` and imports `ZFS` pool
with container data and `osctld` configs.

See [vpsfree-cz-configuration](https://github.com/vpsfreecz/vpsfree-cz-configuration) for
example `NixOps` deployment.

