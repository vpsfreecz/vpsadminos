# Distributions
*osctld* has support for specific distributions, letting it configure hostnames,
networking, or setting the correct LXC configuration. In order for the
distribution recognition to work properly, the table below defines expected
distribution names and versions.

Distribution         | Name                   | Version                | Example
---------------------|------------------------|------------------------|------------------
Alpine Linux         | `alpine`               | `<major>.<minor>`      | `alpine-3.7`
Arch Linux           | `arch`                 | `<YYYYMMDD>`           | `arch-20180210`
CentOS               | `centos`               | `<major>.<minor>`      | `centos-7`
Chimera Linux        | `chimera`              | `<YYYYMMDD>`           | `chimera-20240707`
Debian               | `debian`               | `<major>.<minor>`      | `debian-9`
Devuan               | `devuan`               | `<major>.<minor>`      | `devuan-1.0`
Gentoo               | `gentoo`               | `<profile>-<YYYYMMDD>` | `gentoo-20180210`
openSUSE Leap        | `opensuse`             | `leap-<major>.<minor>` | `opensuse-leap-15.1`
openSUSE Tumbleweed  | `opensuse`             | `tumbleweed-<YYMMDD>`  | `opensuse-tumbleweed-20180210`
Slackware            | `slackware`            | `<major>.<minor>`      | `slackware-14.2`
Ubuntu               | `ubuntu`               | `<major>.<minor>`      | `ubuntu-16.04`
Void Linux           | `void`                 | `<libc>-<YYYYMMDD>`    | `void-glibc-20180210`
