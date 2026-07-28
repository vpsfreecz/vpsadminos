#!@python@

import ipaddress
import os
import re
import secrets
import stat
import subprocess
import sys


BACKEND = "@backend@"
RESOLVCONF = "@resolvconf@"
SYSTEMCTL = "@systemctl@"

RUNTIME_PARENT = "/run"
RUNTIME_DIRECTORY = "vpsadminos"
RUNTIME_FILE = "resolv.conf"
RESOLVED_PARENT = "/run/systemd"
RESOLVED_DIRECTORY = "resolved.conf.d"
RESOLVED_FILE = "50-vpsadminos.conf"

MAX_PAYLOAD_BYTES = 4096
ADDRESS_RE = re.compile(r"^[0-9A-Fa-f:.]+$")
DIRECTORY_MODE = 0o755
FILE_MODE = 0o644
OPEN_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class ResolverInputError(ValueError):
    pass


def validate_payload(data):
    if not data or len(data) > MAX_PAYLOAD_BYTES:
        raise ResolverInputError("resolver payload is empty or too large")
    if not data.endswith(b"\n"):
        raise ResolverInputError("resolver payload must end with a newline")

    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise ResolverInputError("resolver payload is not ASCII") from error

    lines = text[:-1].split("\n")
    if len(lines) < 2 or lines[-1] != "options edns0":
        raise ResolverInputError("resolver payload has an invalid options line")

    addresses = []
    for line in lines[:-1]:
        if not line.startswith("nameserver "):
            raise ResolverInputError("resolver payload has an invalid line")

        address = line.removeprefix("nameserver ")
        if not ADDRESS_RE.fullmatch(address):
            raise ResolverInputError("resolver payload has an invalid address")

        try:
            ipaddress.ip_address(address)
        except ValueError as error:
            raise ResolverInputError("resolver payload has an invalid address") from error

        addresses.append(address)

    if not addresses:
        raise ResolverInputError("resolver payload has no nameserver")

    return addresses


def open_managed_directory(parent_path, name, create=True):
    parent_fd = os.open(parent_path, OPEN_DIRECTORY_FLAGS)

    try:
        if create:
            try:
                os.mkdir(name, DIRECTORY_MODE, dir_fd=parent_fd)
            except FileExistsError:
                pass

        directory_fd = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)

    metadata = os.fstat(directory_fd)
    if metadata.st_uid != os.geteuid() or metadata.st_gid != os.getegid():
        os.close(directory_fd)
        raise PermissionError("managed resolver directory has an unexpected owner")

    os.fchmod(directory_fd, DIRECTORY_MODE)
    return directory_fd


def validate_existing_regular(directory_fd, name):
    try:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return

    if not stat.S_ISREG(metadata.st_mode):
        raise OSError("managed resolver target is not a regular file")
    if metadata.st_uid != os.geteuid() or metadata.st_gid != os.getegid():
        raise PermissionError("managed resolver target has an unexpected owner")


def atomic_write(parent_path, directory, name, data):
    directory_fd = open_managed_directory(parent_path, directory)
    temporary = f".{name}.{os.getpid()}.{secrets.token_hex(12)}"
    created = False

    try:
        validate_existing_regular(directory_fd, name)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        temporary_fd = os.open(
            temporary,
            flags,
            FILE_MODE,
            dir_fd=directory_fd,
        )
        created = True

        with os.fdopen(temporary_fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), FILE_MODE)
            os.fsync(output.fileno())

        os.replace(
            temporary,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        created = False
        os.fsync(directory_fd)
    finally:
        if created:
            os.unlink(temporary, dir_fd=directory_fd)
        os.close(directory_fd)


def unlink_regular(parent_path, directory, name):
    try:
        directory_fd = open_managed_directory(
            parent_path,
            directory,
            create=False,
        )
    except FileNotFoundError:
        return

    try:
        validate_existing_regular(directory_fd, name)
        try:
            os.unlink(name, dir_fd=directory_fd)
        except FileNotFoundError:
            return
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def write_runtime_input(data):
    atomic_write(
        RUNTIME_PARENT,
        RUNTIME_DIRECTORY,
        RUNTIME_FILE,
        data,
    )


def clear_runtime_input():
    unlink_regular(
        RUNTIME_PARENT,
        RUNTIME_DIRECTORY,
        RUNTIME_FILE,
    )


def apply_openresolv(data):
    subprocess.run(
        [RESOLVCONF, "-x", "-m", "0", "-a", "vpsadminos"],
        input=data,
        check=True,
    )


def clear_openresolv():
    subprocess.run(
        [RESOLVCONF, "-f", "-d", "vpsadminos"],
        check=True,
    )


def apply_resolved(addresses):
    config = (
        "[Resolve]\n"
        f"DNS={' '.join(addresses)}\n"
        "FallbackDNS=\n"
    ).encode("ascii")
    atomic_write(
        RESOLVED_PARENT,
        RESOLVED_DIRECTORY,
        RESOLVED_FILE,
        config,
    )
    reload_resolved()


def clear_resolved():
    unlink_regular(
        RESOLVED_PARENT,
        RESOLVED_DIRECTORY,
        RESOLVED_FILE,
    )
    reload_resolved()


def reload_resolved():
    subprocess.run(
        [SYSTEMCTL, "reload-or-restart", "systemd-resolved.service"],
        check=True,
    )


def apply(data):
    addresses = validate_payload(data)
    write_runtime_input(data)

    if BACKEND == "openresolv":
        apply_openresolv(data)
    elif BACKEND == "resolved":
        apply_resolved(addresses)
    else:
        raise RuntimeError(f"unsupported resolver backend {BACKEND!r}")


def clear():
    clear_runtime_input()

    if BACKEND == "openresolv":
        clear_openresolv()
    elif BACKEND == "resolved":
        clear_resolved()
    else:
        raise RuntimeError(f"unsupported resolver backend {BACKEND!r}")


def main(argv):
    try:
        if argv == ["--clear"]:
            clear()
        elif not argv:
            apply(sys.stdin.buffer.read(MAX_PAYLOAD_BYTES + 1))
        else:
            raise ResolverInputError("usage: vpsadminos-dns-update [--clear]")
    except (
        OSError,
        ResolverInputError,
        RuntimeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"vpsadminos-dns-update: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
