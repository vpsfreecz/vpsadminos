#!@python3@/bin/python3
"""
Dump the Linux sysinfo(2) struct as JSON.

Fields whose units depend on `mem_unit` (RAM, swap, buffers, etc.)
are emitted in **bytes**.
Load averages are reported as floats (same scale as /proc/loadavg).
"""

import ctypes
import ctypes.util
import json


class Sysinfo(ctypes.Structure):
    _fields_ = [
        ("uptime",      ctypes.c_long),
        ("loads",       ctypes.c_ulong * 3),
        ("totalram",    ctypes.c_ulong),
        ("freeram",     ctypes.c_ulong),
        ("sharedram",   ctypes.c_ulong),
        ("bufferram",   ctypes.c_ulong),
        ("totalswap",   ctypes.c_ulong),
        ("freeswap",    ctypes.c_ulong),
        ("procs",       ctypes.c_ushort),
        ("pad",         ctypes.c_ushort),
        ("totalhigh",   ctypes.c_ulong),
        ("freehigh",    ctypes.c_ulong),
        ("mem_unit",    ctypes.c_uint),
        ("_f",          ctypes.c_char * 20), # Unused/padding
    ]


libc = ctypes.CDLL(ctypes.util.find_library("c"))
info = Sysinfo()
if libc.sysinfo(ctypes.byref(info)) != 0:
    raise OSError("sysinfo() failed")

to_bytes = lambda x: x * info.mem_unit

result = {
    "uptime":         info.uptime,
    "loads":          [l / 65536.0 for l in info.loads],
    "totalram":       to_bytes(info.totalram),
    "freeram":        to_bytes(info.freeram),
    "sharedram":      to_bytes(info.sharedram),
    "bufferram":      to_bytes(info.bufferram),
    "totalswap":      to_bytes(info.totalswap),
    "freeswap":       to_bytes(info.freeswap),
    "procs":          info.procs,
    "totalhigh":      to_bytes(info.totalhigh),
    "freehigh":       to_bytes(info.freehigh),
    "mem_unit":       info.mem_unit,
}

print(json.dumps(result, separators=(",", ":")))
