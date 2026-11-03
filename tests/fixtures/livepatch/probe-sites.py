#!/usr/bin/env python3
"""Resolve the nine current-build livepatch test witnesses, or fail closed."""

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from capstone import CS_ARCH_X86, CS_MODE_64, Cs
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_OP_REG
from elftools.dwarf.descriptions import describe_form_class
from elftools.common.exceptions import DWARFError, ELFError
from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection


WITNESSES = (
    "svm_entry", "nft_insert_entry", "sunrpc_worker_entry", "fuse_finish",
    "sunrpc_shadow_alloc", "sunrpc_callback_claim", "sunrpc_callback_release",
    "inet_frag_timer", "tcp_mtu_size",
)
SHADOW_ID = 0x02C5D466E3067E6A  # VPSADMINOS_SUNRPC_TLS_SHADOW_ID, source invariant
ENTRY_FUNCTIONS = {
    "svm_entry": "svm_vcpu_run",
    "nft_insert_entry": "nft_pipapo_insert",
    "sunrpc_worker_entry": "xs_tcp_tls_setup_socket",
}
GPRS = {
    **{alias: "r" + name for name, aliases in {
        "ax": ("rax", "eax", "ax", "al", "ah"),
        "bx": ("rbx", "ebx", "bx", "bl", "bh"),
        "cx": ("rcx", "ecx", "cx", "cl", "ch"),
        "dx": ("rdx", "edx", "dx", "dl", "dh"),
        "si": ("rsi", "esi", "si", "sil"),
        "di": ("rdi", "edi", "di", "dil"),
        "bp": ("rbp", "ebp", "bp", "bpl"),
        "sp": ("rsp", "esp", "sp", "spl"),
    }.items() for alias in aliases},
    **{f"r{n}{suffix}": f"r{n}" for n in range(8, 16)
       for suffix in ("", "d", "w", "b")},
}
CALLEE_SAVED = {"rbx", "rbp", "r12", "r13", "r14", "r15"}


class ResolutionError(ValueError):
    """A requested witness cannot be justified from these exact inputs."""


def require(condition, message):
    if not condition:
        raise ResolutionError(message)


def one(items, description):
    require(len(items) == 1, f"{description}: expected one match, found {len(items)}")
    return items[0]


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def register(insn, operand):
    return GPRS.get(insn.reg_name(operand.reg)) if operand.type == X86_OP_REG else None


def reg_is(insn, operand, name, width=None):
    return register(insn, operand) == name and (width is None or operand.size * 8 == width)


def writes(insn, name):
    return any(GPRS.get(insn.reg_name(r)) == name for r in insn.regs_access()[1])


def last_write(instructions, before, name):
    return next((i for i in reversed(instructions[:before]) if writes(i, name)), None)


def immediate(insn, name, value):
    if insn is None:
        return False
    operands = insn.operands
    return (insn.mnemonic in ("mov", "movabs") and len(operands) == 2
            and reg_is(insn, operands[0], name) and operands[0].size in (4, 8)
            and operands[1].type == X86_OP_IMM and operands[1].imm == value)


def zero(insn, name):
    if insn is None:
        return False
    operands = insn.operands
    return (immediate(insn, name, 0)
            or (insn.mnemonic == "xor" and len(operands) == 2
                and operands[0].size in (4, 8)
                and all(reg_is(insn, op, name, operands[0].size * 8) for op in operands)))


@dataclass
class Function:
    artifact: object
    name: str
    section_index: int
    start: int
    size: int
    instructions: list

    @property
    def section(self):
        return self.artifact.elf.get_section(self.section_index)


class Artifact:
    def __init__(self, path):
        self.stream = open(path, "rb")
        self.elf = ELFFile(self.stream)
        require(self.elf.elfclass == 64 and self.elf.little_endian
                and self.elf["e_machine"] == "EM_X86_64", "expected little-endian x86-64 ELF")
        self.decoder = Cs(CS_ARCH_X86, CS_MODE_64)
        self.decoder.detail = True
        self.symbols = self.elf.get_section_by_name(".symtab")
        require(self.symbols is not None, "missing ELF symbol table")
        self.relocations = {}
        for section in self.elf.iter_sections():
            if not isinstance(section, RelocationSection):
                continue
            if not self.elf.get_section(section["sh_info"])["sh_flags"] & 4:
                continue  # DWARF relocation is handled by pyelftools itself.
            symbols = self.elf.get_section(section["sh_link"])
            entries = self.relocations.setdefault(section["sh_info"], {})
            for relocation in section.iter_relocations():
                entries.setdefault(relocation["r_offset"], []).append((
                    symbols.get_symbol(relocation["r_info_sym"]).name,
                    relocation["r_info_type"], relocation.entry.get("r_addend", None),
                ))
        self._dwarf = None
        self._units = None
        self._functions = {}
        self._inline = {}
        self._types = {}

    def close(self):
        self.stream.close()

    def functions(self, name):
        if name not in self._functions:
            result = []
            for symbol in self.symbols.iter_symbols():
                if (symbol.name != name or symbol["st_info"]["type"] != "STT_FUNC"
                        or not isinstance(symbol["st_shndx"], int)):
                    continue
                section = self.elf.get_section(symbol["st_shndx"])
                require(section["sh_flags"] & 4, f"{name}: function is not executable")
                start, size = symbol["st_value"], symbol["st_size"]
                require(size > 0 and start + size <= section["sh_addr"] + section["sh_size"],
                        f"{name}: invalid symbol size/range")
                data = section.data()[start - section["sh_addr"]:start - section["sh_addr"] + size]
                instructions = list(self.decoder.disasm(data, start))
                require(sum(i.size for i in instructions) == size, f"{name}: undecodable instruction range")
                result.append(Function(self, name, symbol["st_shndx"], start, size, instructions))
            self._functions[name] = result
        return self._functions[name]

    def function(self, name):
        return one(self.functions(name), f"function {name}")

    def target(self, function, insn):
        if not (insn.mnemonic == "call" and insn.size == 5 and insn.bytes[0] == 0xE8):
            return None
        relocations = self.relocations.get(function.section_index, {}).get(insn.address + 1, [])
        if not relocations:
            return None
        name, kind, addend = one(relocations, f"{function.name}: call relocation")
        require(kind in (2, 4) and addend == -4, f"{function.name}: unsupported call relocation")
        if name.startswith(".klp.sym."):
            match = re.fullmatch(r"\.klp\.sym\.([^.]+)\.(.+),(\d+)", name)
            require(match is not None, f"{function.name}: malformed livepatch callee")
            return {"object": match[1], "symbol": match[2], "symbol_pos": int(match[3])}
        return {"object": "vmlinux", "symbol": name, "symbol_pos": 0}

    def calls(self, function, name):
        return [(i, target) for i in function.instructions
                if (target := self.target(function, i)) and target["symbol"] == name]

    @property
    def dwarf(self):
        if self._dwarf is None:
            require(self.elf.has_dwarf_info(), "missing DWARF information")
            self._dwarf = self.elf.get_dwarf_info()
        return self._dwarf

    @staticmethod
    def name(die):
        for _ in range(16):
            if "DW_AT_name" in die.attributes:
                return die.attributes["DW_AT_name"].value.decode("utf-8", "strict")
            key = next((k for k in ("DW_AT_abstract_origin", "DW_AT_specification")
                        if k in die.attributes), None)
            if key is None:
                return None
            die = die.get_DIE_from_attribute(key)
        raise ResolutionError("cyclic DWARF name reference")

    def units(self, suffix):
        if self._units is None:
            self._units = list(self.dwarf.iter_CUs())
        matching = [cu for cu in self._units if (self.name(cu.get_top_DIE()) or "").endswith(suffix)]
        return matching or self._units

    def ranges(self, die):
        attributes = die.attributes
        if "DW_AT_low_pc" in attributes and "DW_AT_high_pc" in attributes:
            low, high = attributes["DW_AT_low_pc"].value, attributes["DW_AT_high_pc"]
            return [(low, high.value if describe_form_class(high.form) == "address" else low + high.value)]
        if "DW_AT_ranges" not in attributes:
            return []
        top = die.cu.get_top_DIE().attributes
        base = top["DW_AT_low_pc"].value if "DW_AT_low_pc" in top else 0
        result = []
        for entry in self.dwarf.range_lists().get_range_list_at_offset(
                attributes["DW_AT_ranges"].value, cu=die.cu):
            if hasattr(entry, "base_address"):
                base = entry.base_address
            else:
                bias = 0 if entry.is_absolute else base
                result.append((bias + entry.begin_offset, bias + entry.end_offset))
        return result

    def inline_at(self, function, name, address):
        key = (function.name, name)
        if key not in self._inline:
            suffix = {"fuse_copy_page": "fs/fuse/dev.c", "tcp_write_xmit": "net/ipv4/tcp_output.c",
                      "inet_frag_find": "net/ipv4/inet_fragment.c"}.get(function.name, "")
            ranges = []
            for cu in self.units(suffix):
                for die in cu.iter_DIEs():
                    if die.tag != "DW_TAG_subprogram" or self.name(die) != function.name:
                        continue
                    if not any(low <= function.start < high for low, high in self.ranges(die)):
                        continue
                    pending = list(die.iter_children())
                    while pending:
                        child = pending.pop()
                        if child.tag == "DW_TAG_inlined_subroutine" and self.name(child) == name:
                            ranges.extend(self.ranges(child))
                        pending.extend(child.iter_children())
            self._inline[key] = ranges
        return any(low <= address < high for low, high in self._inline[key])

    def members(self, structure, names, suffix):
        key = (structure, tuple(names))
        if key not in self._types:
            layouts = set()
            for cu in self.units(suffix):
                for die in cu.iter_DIEs():
                    if die.tag != "DW_TAG_structure_type" or self.name(die) != structure:
                        continue
                    members = {}
                    for member in die.iter_children():
                        if member.tag != "DW_TAG_member" or self.name(member) not in names:
                            continue
                        location = member.attributes.get("DW_AT_data_member_location")
                        require(location is not None and isinstance(location.value, int),
                                f"{structure}: unsupported member location")
                        member_type = member.get_DIE_from_attribute("DW_AT_type")
                        for _ in range(16):
                            size = member_type.attributes.get("DW_AT_byte_size")
                            if size is not None:
                                break
                            if member_type.tag == "DW_TAG_pointer_type":
                                size = member_type.cu["address_size"]
                                break
                            require("DW_AT_type" in member_type.attributes,
                                    f"{structure}: incomplete member type")
                            member_type = member_type.get_DIE_from_attribute("DW_AT_type")
                        require(size is not None, f"{structure}: cyclic member type")
                        members[self.name(member)] = (location.value, size if isinstance(size, int) else size.value)
                    if set(members) == set(names):
                        size = die.attributes.get("DW_AT_byte_size")
                        require(size is not None, f"{structure}: missing complete type size")
                        layouts.add((size.value, tuple(members[n] for n in names)))
            self._types[key] = one(list(layouts), f"{structure} complete type layout")
        return {name: layout[0] for name, layout in zip(names, self._types[key][1])}

    def build_id(self):
        section = self.elf.get_section_by_name(".note.gnu.build-id")
        if section is None:
            return None
        values = [n["n_desc"] for n in section.iter_notes() if n["n_type"] == "NT_GNU_BUILD_ID"]
        return one(values, "GNU build ID")


def record(function, instruction, kind, frame="observe_only", inline=None):
    require(function.start <= instruction.address < function.start + function.size,
            f"{function.name}: instruction outside function")
    return {
        "object": "livepatch_7", "symbol": function.name, "symbol_pos": 0,
        "section": function.section.name, "symbol_size": function.size,
        "offset": instruction.address - function.start, "instruction_length": instruction.size,
        "kind": kind, "frame": frame, "inline": inline, "registers": {},
    }


def entry(artifact, function):
    instructions = function.instructions
    index = 0
    while index < len(instructions) and instructions[index].mnemonic in ("nop", "endbr64"):
        index += 1
    require(index < len(instructions), f"{function.name}: missing entry")
    call = instructions[index]
    target = artifact.target(function, call)
    require(target == {"object": "vmlinux", "symbol": "__fentry__", "symbol_pos": 0},
            f"{function.name}: unsupported pre-fentry prefix")
    require(index + 1 < len(instructions), f"{function.name}: missing preprologue")
    hold = instructions[index + 1]
    # Hold before this push, so subsequent prologue scheduling does not
    # affect entry RSP/arg0. Original FUSE moves RDI to RDX before setting RBP.
    require(hold.mnemonic == "push" and reg_is(hold, hold.operands[0], "rbp", 64),
            f"{function.name}: unsupported entry stack/frame")
    result = record(function, hold, "entry_hold", "preprologue")
    result["registers"] = {"arg0": {"register": "rdi", "width": 64}}
    return result


class Resolver:
    def __init__(self, module, sha256, fuse_module=None, sdk_vmlinux=None):
        require(isinstance(sha256, str) and re.fullmatch(r"[0-9a-f]{64}", sha256),
                "module: expected captured lowercase SHA-256")
        require(digest(module) == sha256, "module: captured SHA-256 does not match")
        self.sha256 = sha256
        self.module = Artifact(module)
        require(self.module.elf["e_type"] == "ET_REL", "module: expected relocatable ELF")
        self.fuse_path, self.sdk_path = fuse_module, sdk_vmlinux
        self._fuse = None
        self._sdk = None

    def close(self):
        for artifact in (self.module, self._fuse, self._sdk):
            if artifact is not None:
                artifact.close()

    @property
    def sdk(self):
        require(self.sdk_path is not None, "matching frozen SDK vmlinux is required")
        if self._sdk is None:
            self._sdk = Artifact(self.sdk_path)
        return self._sdk

    def abi_type(self, structure, members, suffix):
        candidate = self.module.members(structure, members, suffix)
        sdk = self.sdk.members(structure, members, suffix)
        key = (structure, tuple(members))
        require(candidate == sdk and self.module._types[key] == self.sdk._types[key],
                f"{structure}: candidate/SDK member offsets, widths or type size disagree")
        return candidate

    def abi(self):
        frag = self.abi_type("inet_frag_queue", ("timer", "node", "lock"), "net/ipv4/inet_fragment.c")
        sock = self.abi_type("sock_xprt", ("connect_worker",), "net/sunrpc/xprtsock.c")
        return {"sock_xprt_connect_worker": sock["connect_worker"],
                "inet_frag_timer": frag["timer"], "inet_frag_node": frag["node"],
                "inet_frag_lock": frag["lock"]}

    def fuse(self):
        function = self.module.function("fuse_copy_page")
        calls = [(i, t) for i, t in self.module.calls(function, "fuse_copy_finish")
                 if t == {"object": "fuse", "symbol": "fuse_copy_finish", "symbol_pos": 1}
                 and self.module.inline_at(function, "fuse_ref_page", i.address)]
        call, target = one(calls, "fuse_ref_page qualified finish call")
        before = function.instructions[:function.instructions.index(call)]
        arg = last_write(before, len(before), "rdi")
        require(arg is not None and arg.mnemonic == "mov" and len(arg.operands) == 2
                and reg_is(arg, arg.operands[0], "rdi", 64)
                and register(arg, arg.operands[1]) not in (None, "rsp", "rbp"),
                "fuse_ref_page: copy-state arg0 is not preserved")
        require(not any(i.mnemonic == "call" for i in before[before.index(arg) + 1:]),
                "fuse_ref_page: copy-state arg0 is caller-clobbered")
        require(any(self.module.target(function, i) == {
            "object": "fuse", "symbol": "unlock_request.part.0", "symbol_pos": 1}
                    for i in before[-10:]), "fuse_ref_page: missing preceding unlock")
        require(self.fuse_path is not None, "fuse_finish: original FUSE ELF is required")
        if self._fuse is None:
            self._fuse = Artifact(self.fuse_path)
        callee = entry(self._fuse, self._fuse.function(target["symbol"]))
        result = record(function, call, "callee_entry_hold", inline="fuse_ref_page")
        result["registers"] = {"arg0": {"register": "rdi", "width": 64}}
        result["return_offset"] = result["offset"] + call.size
        result["callee"] = {k: callee[k] for k in (
            "section", "symbol_size", "offset", "instruction_length", "frame")}
        result["callee"].update(target)
        return result

    def sunrpc(self, witness):
        name, callee = {
            "sunrpc_shadow_alloc": ("xs_connect", "klp_shadow_alloc"),
            "sunrpc_callback_claim": ("vpsadminos_sunrpc_tls_drain", "cancel_delayed_work_sync"),
            "sunrpc_callback_release": ("vpsadminos_sunrpc_cb_release", "klp_shadow_free"),
        }[witness]
        function = self.module.function(name)
        call, target = one(self.module.calls(function, callee), f"{name}/{callee}")
        require(target["object"] == "vmlinux" and target["symbol_pos"] == 0,
                f"{name}: unexpected callee namespace")
        before = function.instructions[:function.instructions.index(call)]
        arg = last_write(before, len(before), "rdi")
        require(arg is not None and reg_is(arg, arg.operands[0], "rdi", 64),
                f"{name}: invalid arg0 definition")
        require(not any(i.mnemonic == "call" for i in before[before.index(arg) + 1:]),
                f"{name}: arg0 is caller-clobbered")
        if witness == "sunrpc_callback_claim":
            offset = self.abi_type("sock_xprt", ("connect_worker",), "net/sunrpc/xprtsock.c")["connect_worker"]
            require(arg.mnemonic == "lea" and arg.operands[1].type == X86_OP_MEM
                    and arg.operands[1].mem.disp == offset and arg.operands[1].mem.index == 0,
                    f"{name}: arg0 is not the matching SDK work member")
            prior = [i for i in before[-12:] if (t := self.module.target(function, i))
                     and t["symbol"] == "vpsadminos_sunrpc_tls_take_work"]
            require(len(prior) == 1, f"{name}: missing ownership take_work call")
            require(any(i.mnemonic == "test" for i in before[before.index(prior[0]) + 1:]),
                    f"{name}: missing owned-state NULL check")
        else:
            require(arg.mnemonic == "mov" and register(arg, arg.operands[1]) is not None,
                    f"{name}: transport pointer argument unsupported")
            require(immediate(last_write(before, len(before), "rsi"), "rsi", SHADOW_ID),
                    f"{name}: wrong SUNRPC shadow ID")
            if witness == "sunrpc_callback_release":
                require(zero(last_write(before, len(before), "rdx"), "rdx"),
                        f"{name}: shadow destructor is not NULL")
        result = record(function, call, "call_observe")
        result["callee"] = target
        result["registers"] = {"arg0": {"register": "rdi", "width": 64}}
        return result

    def fragment(self):
        self.abi_type("inet_frag_queue", ("timer", "node", "lock"), "net/ipv4/inet_fragment.c")
        matches = []
        for name in ("inet_frag_find", "inet_frag_create"):
            for function in self.module.functions(name):
                for call, target in self.module.calls(function, "mod_timer"):
                    if target != {"object": "vmlinux", "symbol": "mod_timer", "symbol_pos": 0}:
                        continue
                    if name != "inet_frag_create" and not self.module.inline_at(function, "inet_frag_create", call.address):
                        continue
                    index = function.instructions.index(call)
                    before, after = function.instructions[:index], function.instructions[index + 1:]
                    arg = last_write(before, len(before), "rdi")
                    if not (arg and arg.mnemonic == "mov" and reg_is(arg, arg.operands[0], "rdi", 64)
                            and arg.operands[1].type == X86_OP_MEM):
                        continue
                    if not any((t := self.module.target(function, i)) and t["symbol"] == "rhashtable_insert_slow"
                               for i in before[-32:]):
                        continue
                    if not any((t := self.module.target(function, i)) and t["symbol"] == "_raw_spin_unlock_bh"
                               for i in after[:8]):
                        continue
                    matches.append((function, call, target))
        function, call, target = one(matches, "fragment inline timer registration")
        result = record(function, call, "call_observe", inline="inet_frag_create")
        result["callee"] = target
        result["registers"] = {"arg0": {"register": "rdi", "width": 64}}
        return result

    def tcp(self):
        function = self.module.function("tcp_write_xmit")
        instructions = function.instructions
        matches = []
        for index, compare in enumerate(instructions):
            if not (compare.mnemonic == "cmp" and len(compare.operands) == 2
                    and all(op.type == X86_OP_REG and op.size == 8 for op in compare.operands)
                    and self.module.inline_at(function, "tcp_mtu_probe", compare.address)):
                continue
            try:
                roles = tcp_roles(instructions, index)
            except ResolutionError:
                continue
            matches.append((compare, roles))
        compare, roles = one(matches, "TCP wide size-needed comparison")
        result = record(function, compare, "tcp_size_observe", inline="tcp_mtu_probe")
        result["registers"] = {name: {"register": reg, "width": 64 if name == "needed" else 32}
                               for name, reg in roles.items()}
        return result

    def site(self, witness):
        require(witness in WITNESSES, f"unknown witness {witness!r}")
        try:
            if witness in ENTRY_FUNCTIONS:
                return entry(self.module, self.module.function(ENTRY_FUNCTIONS[witness]))
            if witness == "fuse_finish":
                return self.fuse()
            if witness.startswith("sunrpc_"):
                return self.sunrpc(witness)
            if witness == "inet_frag_timer":
                return self.fragment()
            return self.tcp()
        except (ResolutionError, ELFError, DWARFError) as error:
            raise ResolutionError(f"{witness}: {error}") from error


def tcp_roles(instructions, index):
    """Recognize this finite widen/add/multiply/compare block, binding GPR roles."""
    compare = instructions[index]
    needed = register(compare, compare.operands[1])
    require(needed is not None and index + 1 < len(instructions), "invalid needed register")
    branch = instructions[index + 1]
    require(branch.mnemonic == "jb" and branch.operands[0].type == X86_OP_IMM,
            "missing unsigned queued-byte comparison")
    following = instructions[index + 2:index + 9]
    second = [(i, n) for n, i in enumerate(following) if i.mnemonic == "cmp"
              and len(i.operands) == 2 and reg_is(i, i.operands[1], needed, 64)]
    compare2, second_index = one(second, "same needed window comparison")
    require(second_index + 1 < len(following), "missing window branch")
    branch2 = following[second_index + 1]
    require(branch2.mnemonic == "jb" and branch2.operands[0].type == X86_OP_IMM
            and branch2.operands[0].imm == branch.operands[0].imm,
            "comparison failure targets disagree")
    require(not any(writes(i, needed) for i in following[:second_index]), "needed clobbered before window comparison")
    before = instructions[:index]
    add_probe = last_write(before, len(before), needed)
    require(add_probe is not None and add_probe.mnemonic == "add"
            and reg_is(add_probe, add_probe.operands[0], needed, 64)
            and add_probe.operands[1].type == X86_OP_REG and add_probe.operands[1].size == 8,
            "missing wide probe-size addition")
    add_index = instructions.index(add_probe)
    probe = register(add_probe, add_probe.operands[1])
    extend_probe = last_write(instructions, add_index, probe)
    require(extend_probe is not None and extend_probe.mnemonic == "movsxd"
            and extend_probe.operands[0].size == 8 and extend_probe.operands[1].size == 4,
            "unsupported probe-size extension")
    multiply = last_write(instructions, add_index, needed)
    require(multiply is not None and multiply.mnemonic == "imul" and len(multiply.operands) == 2
            and all(op.type == X86_OP_REG and op.size == 8 for op in multiply.operands)
            and reg_is(multiply, multiply.operands[0], needed, 64), "missing wide MSS multiplication")
    multiply_index = instructions.index(multiply)
    mss = register(multiply, multiply.operands[1])
    increment = last_write(instructions, multiply_index, needed)
    require(increment is not None and increment.mnemonic == "add"
            and reg_is(increment, increment.operands[0], needed, 64)
            and increment.operands[1].type == X86_OP_IMM and increment.operands[1].imm == 1,
            "addition does not widen before increment")
    increment_index = instructions.index(increment)
    widen = last_write(instructions, increment_index, needed)
    require(widen is not None and widen.mnemonic == "mov" and len(widen.operands) == 2
            and reg_is(widen, widen.operands[0], needed, 32)
            and widen.operands[1].type == X86_OP_REG and widen.operands[1].size == 4,
            "missing reordering zero-extension")
    reordering = register(widen, widen.operands[1])
    require(len({needed, reordering, mss, probe}) == 4, "overlapping arithmetic register roles")
    begin = instructions.index(widen)
    require(index - begin <= 16, "unsupported arithmetic block span")
    require(not any(i.group_name(g) in ("jump", "call", "ret")
                    for i in instructions[begin:index] for g in i.groups), "control flow inside arithmetic block")
    for role in (reordering, mss):
        require(not any(writes(i, role) for i in instructions[begin:index]), "input register is no longer live")
        definition = last_write(instructions, begin, role)
        require(definition is not None and definition.mnemonic == "mov"
                and reg_is(definition, definition.operands[0], role, 32)
                and definition.operands[1].type == X86_OP_MEM, "missing live 32-bit input load")
        start = instructions.index(definition) + 1
        require(not any(i.mnemonic == "call" for i in instructions[start:begin]) or role in CALLEE_SAVED,
                "input is caller-clobbered before arithmetic")
    return {"needed": needed, "reordering": reordering, "mss": mss}


def resolve_site(witness, module, sha256, fuse_module=None, sdk_vmlinux=None):
    require(witness in WITNESSES, f"unknown witness {witness!r}")
    try:
        resolver = Resolver(module, sha256, fuse_module, sdk_vmlinux)
    except (OSError, ELFError, DWARFError) as error:
        raise ResolutionError(f"{witness}: {error}") from error
    try:
        return resolver.site(witness)
    finally:
        resolver.close()


def resolve(module, sha256, fuse_module, sdk_vmlinux):
    resolver = Resolver(module, sha256, fuse_module, sdk_vmlinux)
    try:
        sites = {name: resolver.site(name) for name in WITNESSES}
        return {"schema_version": 1, "module_sha256": sha256,
                "elf": {"elf_class": 64, "machine": "EM_X86_64", "build_id": resolver.module.build_id()},
                "abi": resolver.abi(), "sites": sites}
    finally:
        resolver.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--fuse-module", required=True)
    parser.add_argument("--sdk-vmlinux", required=True)
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    try:
        result = resolve(args.module, args.sha256, args.fuse_module, args.sdk_vmlinux)
        text = json.dumps(result, sort_keys=True, indent=2) + "\n"
        if args.output:
            Path(args.output).write_text(text)
        else:
            sys.stdout.write(text)
    except (ResolutionError, OSError, ValueError, ELFError, DWARFError) as error:
        print(f"livepatch probe sites: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
