# Distributions
*osctld* has support for specific distributions, letting it configure hostnames,
networking, or setting the correct LXC configuration. In order for the
distribution recognition to work properly, the table below defines expected
distribution names and versions.

Distribution         | Name                   | Version                | Example
---------------------|------------------------|------------------------|------------------
Alpine Linux         | `alpine`               | `<major>.<minor>`      | `alpine-3.7`
Arch Linux           | `arch`                 | `<YYYYMMDD>`           | `arch-20180210`
CentOS               | `centos`               | `<major>.<minor>`      | `centos-7.3`
Debian               | `debian`               | `<major>.<minor>`      | `debian-9.0`
Devuan               | `devuan`               | `<major>.<minor>`      | `devuan-1.0`
Gentoo               | `gentoo`               | `<profile>-<YYYYMMDD>` | `gentoo-17.0-20180210`
openSUSE Leap        | `opensuse_leap`        | `<major>.<minor>`      | `opensuse_leap-15.1`
openSUSE Tumbleweed  | `opensuse_tumbleweed`  | `<YYMMDD>`             | `opensuse_tumbleweed-20180210`
Slackware            | `slackware`            | `<major>.<minor>`      | `slackware-14.2`
Ubuntu               | `ubuntu`               | `<major>.<minor>`      | `ubuntu-16.04`
Void Linux           | `void`                 | `<YYYYMMDD>`           | `void-20180210`

Distribution name and version is given either via template and naming scheme,
or by appropriate command-line options.
