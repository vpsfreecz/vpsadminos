vpsAdminOS Converter
====================

Convert existing containers into vpsAdminOS, currently supporting only OpenVZ
Legacy with vpsAdmin.

## Installation
The converter has to be installed on the OpenVZ node:

    $ gem install vpsadminos-converter

## Usage
To export container `101` from the OpenVZ node into `ct-101.tar`:

    openvz-node $ vpsadminos-convert vz6 export --vpsadmin 101 ct-101.tar

To import the exported archive on vpsAdminOS:

    vpsadminos-node $ osctl ct import ct-101.tar

For more information, see the man page:

    openvz-node % vpsadminos-convert man
