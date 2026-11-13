#!/usr/bin/env python3

import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path


CALLBACK_KINDS = (
    "pre_patch",
    "post_patch",
    "pre_unpatch",
    "post_unpatch",
)
KLP_STATE_RECORD_SIZE = 24


def canonical_functions(functions):
    return sorted(
        functions,
        key=lambda value: (value["object"], value["symbol"], value["sympos"]),
    )


def canonical_callbacks(callbacks):
    return sorted(
        callbacks,
        key=lambda value: (value["kind"], value["object"], value["symbol"]),
    )


def read_json(path):
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, value):
    with Path(path).open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def modinfo(module, field):
    result = subprocess.run(
        ["modinfo", "-F", field, module],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def symbol_map(symtab):
    ret = {}
    for symbol in symtab.iter_symbols():
        ret.setdefault(symbol.name, symbol)
    return ret


def symbol_value(symbols, name):
    symbol = symbols.get(name)
    return None if symbol is None else symbol["st_value"]


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def c_string(data, offset):
    if offset < 0 or offset >= len(data):
        raise ValueError(f"string offset {offset} is outside .kpatch.strings")
    end = data.find(b"\0", offset)
    if end == -1:
        raise ValueError(f"string offset {offset} is not NUL-terminated")
    return data[offset:end].decode("utf-8")


def relocation_symbol_name(elf, symbol):
    if symbol["st_info"]["type"] != "STT_SECTION":
        return symbol.name

    section_index = symbol["st_shndx"]
    if type(section_index) is not int:
        raise ValueError("section relocation symbol has a special ELF section index")
    if section_index < 0:
        raise ValueError("section relocation symbol has an invalid ELF section index")
    try:
        section = elf.get_section(section_index)
    except (AttributeError, IndexError, KeyError, TypeError):
        section = None
    if section is None or not section.name:
        raise ValueError("section relocation symbol has an invalid ELF section index")
    return section.name


def inspect_functions(elf, symtab):
    section = elf.get_section_by_name(".kpatch.funcs")
    relocations = elf.get_section_by_name(".rela.kpatch.funcs")
    strings = elf.get_section_by_name(".kpatch.strings")
    if section is None or relocations is None or strings is None:
        raise ValueError("module is missing kpatch function inventory sections")

    if elf.elfclass != 64:
        raise ValueError(f"unsupported ELF class {elf.elfclass}")

    word_size = 8
    entry_size = 7 * word_size
    data = section.data()
    if len(data) == 0 or len(data) % entry_size != 0:
        raise ValueError("invalid .kpatch.funcs size")

    relocation_symtab = elf.get_section(relocations["sh_link"])
    by_offset = {}
    for relocation in relocations.iter_relocations():
        symbol = relocation_symtab.get_symbol(relocation["r_info_sym"])
        by_offset[relocation["r_offset"]] = (
            relocation_symbol_name(elf, symbol),
            relocation["r_addend"],
        )

    byte_order = "<" if elf.little_endian else ">"
    string_data = strings.data()
    functions = []
    for base in range(0, len(data), entry_size):
        name_relocation = by_offset.get(base + 5 * word_size)
        object_relocation = by_offset.get(base + 6 * word_size)
        if name_relocation is None or object_relocation is None:
            raise ValueError("function entry is missing name or object relocation")
        if name_relocation[0] != ".kpatch.strings" or object_relocation[0] != ".kpatch.strings":
            raise ValueError("function entry does not reference .kpatch.strings")

        sympos = struct.unpack_from(f"{byte_order}Q", data, base + 4 * word_size)[0]
        functions.append(
            {
                "object": c_string(string_data, object_relocation[1]),
                "symbol": c_string(string_data, name_relocation[1]),
                "sympos": sympos,
            }
        )

    return canonical_functions(functions)


def relocation_map(elf, section):
    relocations = elf.get_section_by_name(f".rela{section.name}")
    if relocations is None:
        return {}
    if not relocations.is_RELA():
        raise ValueError(f"{relocations.name} must use RELA records")

    relocation_symtab = elf.get_section(relocations["sh_link"])
    by_offset = {}
    for relocation in relocations.iter_relocations():
        offset = relocation["r_offset"]
        if offset in by_offset:
            raise ValueError(f"duplicate relocation at offset {offset} in {section.name}")
        symbol = relocation_symtab.get_symbol(relocation["r_info_sym"])
        by_offset[offset] = (relocation_symbol_name(elf, symbol), relocation["r_addend"])
    return by_offset


def decode_callback_records(kind, start, end, relocations, string_data, word_size=8):
    record_size = 2 * word_size
    size = end - start
    if size < 0 or size % record_size != 0:
        raise ValueError(f"invalid {kind} callback inventory size")

    callbacks = []
    used_relocations = set()
    for base in range(start, end, record_size):
        function_relocation = relocations.get(base)
        object_relocation = relocations.get(base + word_size)
        if function_relocation is None or object_relocation is None:
            raise ValueError(f"{kind} callback record is missing a relocation")
        if not function_relocation[0] or function_relocation[0] == ".kpatch.strings":
            raise ValueError(f"{kind} callback function relocation is invalid")
        if object_relocation[0] != ".kpatch.strings":
            raise ValueError(f"{kind} callback object does not reference .kpatch.strings")
        callbacks.append(
            {
                "kind": kind,
                "object": c_string(string_data, object_relocation[1]),
                "symbol": function_relocation[0],
            }
        )
        used_relocations.update((base, base + word_size))

    unexpected = sorted(
        offset for offset in relocations if start <= offset < end and offset not in used_relocations
    )
    if unexpected:
        raise ValueError(f"{kind} callback inventory has unexpected relocations: {unexpected}")
    return callbacks


def inspect_callbacks(elf, symbols):
    strings = elf.get_section_by_name(".kpatch.strings")
    if strings is None:
        raise ValueError("module is missing .kpatch.strings")

    callbacks = []
    for kind in CALLBACK_KINDS:
        start = symbol_value(symbols, f"__kpatch_callbacks_{kind}")
        end = symbol_value(symbols, f"__kpatch_callbacks_{kind}_end")
        section = elf.get_section_by_name(f".kpatch.callbacks.{kind}")
        if start is None or end is None:
            raise ValueError(f"module is missing the {kind} callback inventory")
        if start == end and section is None:
            continue
        if section is None:
            raise ValueError(f"module is missing the {kind} callback section")
        section_address = section["sh_addr"]
        callbacks.extend(
            decode_callback_records(
                kind,
                start - section_address,
                end - section_address,
                relocation_map(elf, section),
                strings.data(),
                elf.elfclass // 8,
            )
        )
    return canonical_callbacks(callbacks)


def format_word(value):
    return f"0x{value:016x}"


def decode_state_section(data, start, sentinel, end, byte_order, alignment):
    if sentinel - start != KLP_STATE_RECORD_SIZE:
        raise ValueError("system-state section must contain exactly one state record")
    if end - sentinel != KLP_STATE_RECORD_SIZE:
        raise ValueError("system-state section must contain exactly one full sentinel")
    if start < 0 or end > len(data):
        raise ValueError("system-state inventory is outside its ELF section")
    if alignment <= 0 or start % alignment != 0 or sentinel % alignment != 0:
        raise ValueError("system-state records are not naturally aligned")

    state_id = struct.unpack_from(f"{byte_order}Q", data, start)[0]
    state_version = struct.unpack_from(f"{byte_order}I", data, start + 8)[0]
    state_data = struct.unpack_from(f"{byte_order}Q", data, start + 16)[0]
    sentinel_data = data[sentinel:end]
    sentinel_id = struct.unpack_from(f"{byte_order}Q", sentinel_data, 0)[0]
    sentinel_version = struct.unpack_from(f"{byte_order}I", sentinel_data, 8)[0]
    sentinel_pointer = struct.unpack_from(f"{byte_order}Q", sentinel_data, 16)[0]

    states = [
        {
            "id": format_word(state_id),
            "version": state_version,
            "data": format_word(state_data),
        }
    ]
    state_section = {
        "recordSize": KLP_STATE_RECORD_SIZE,
        "alignment": alignment,
        "sentinel": {
            "id": format_word(sentinel_id),
            "version": sentinel_version,
            "data": format_word(sentinel_pointer),
            "size": len(sentinel_data),
            "zero": not any(sentinel_data),
        },
    }
    return states, state_section


def inspect_states(elf, symbols):
    start_symbol = symbols.get("__kpatch_system_states")
    sentinel_symbol = symbols.get("kpatch_system_state_sentinel")
    end_symbol = symbols.get("__kpatch_system_states_end")
    if start_symbol is None or sentinel_symbol is None or end_symbol is None:
        raise ValueError("module is missing the system-state inventory or sentinel")
    section_indexes = {
        start_symbol["st_shndx"],
        sentinel_symbol["st_shndx"],
        end_symbol["st_shndx"],
    }
    if len(section_indexes) != 1 or not all(isinstance(index, int) for index in section_indexes):
        raise ValueError("system-state symbols do not share one ELF section")
    section = elf.get_section(start_symbol["st_shndx"])
    if section.name != ".kpatch.system_states":
        raise ValueError("system-state inventory is in an unexpected ELF section")
    if sentinel_symbol["st_size"] != KLP_STATE_RECORD_SIZE:
        raise ValueError("system-state sentinel has an unexpected symbol size")
    if relocation_map(elf, section):
        raise ValueError("initial system-state inventory must not contain relocations")

    section_address = section["sh_addr"]
    start = start_symbol["st_value"] - section_address
    sentinel = sentinel_symbol["st_value"] - section_address
    end = end_symbol["st_value"] - section_address
    byte_order = "<" if elf.little_endian else ">"
    return decode_state_section(
        section.data(),
        start,
        sentinel,
        end,
        byte_order,
        section["sh_addralign"],
    )


def inspect_framework(args, functions, changed_objects):
    source = Path(args.framework_source).read_text(encoding="utf-8")
    guard_return_count = source.count("return -ESTALE;")
    return {
        "frameworkPatchSha256": sha256_file(args.framework_source),
        "generatedHeaderSha256": sha256_file(args.generated_header),
        "guardErrno": "-ESTALE" if guard_return_count == 1 else None,
        "guardReturnCount": guard_return_count,
        "carrier": {
            "object": args.framework_carrier_object,
            "present": args.framework_carrier_object in changed_objects,
        },
        "replacementFunctions": [
            function
            for function in functions
            if function["symbol"].startswith("vpsadminos_uname_level_p")
        ],
    }


def read_changed_objects(path):
    if path is None:
        return []
    return [line.strip() for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def inspect_module(args):
    try:
        from elftools.elf.elffile import ELFFile
    except ImportError as exc:
        raise RuntimeError("pyelftools is required for module inspection") from exc

    module = Path(args.module)
    module_bytes = module.read_bytes()
    with module.open("rb") as handle:
        elf = ELFFile(handle)
        symtab = elf.get_section_by_name(".symtab")
        if symtab is None:
            raise ValueError("module is stripped or has no symbol table")
        symbols = symbol_map(symtab)
        undefined = sorted(
            {
                symbol.name
                for symbol in symtab.iter_symbols()
                if symbol.name and symbol["st_shndx"] == "SHN_UNDEF"
            }
        )
        imports = sorted(name for name in symbols if name.startswith(".klp.sym."))
        relocations = sorted(
            section.name
            for section in elf.iter_sections()
            if section.name.startswith(".klp.rela.")
        )
        functions = inspect_functions(elf, symtab)
        callbacks = inspect_callbacks(elf, symbols)
        states, state_section = inspect_states(elf, symbols)
        elf_class = elf.elfclass

    changed_objects = read_changed_objects(args.changed_objects)
    forbidden = set(args.forbidden_skipped_object)
    skipped_changed_objects = sorted(forbidden.intersection(changed_objects))
    shadow_imports = sorted(
        name
        for name in undefined
        if name.startswith("klp_shadow_") or name.startswith("kpatch_shadow_")
    )

    return {
        "schemaVersion": 1,
        "buildInvocation": {
            "flags": sorted(args.build_flag),
            "nonReplaceRequested": "--non-replace" in args.build_flag,
        },
        "module": {
            "elfClass": elf_class,
            "livepatch": modinfo(str(module), "livepatch"),
            "name": modinfo(str(module), "name"),
            "sha256": hashlib.sha256(module_bytes).hexdigest(),
            "sigId": modinfo(str(module), "sig_id"),
            "sigKey": modinfo(str(module), "sig_key"),
            "signer": modinfo(str(module), "signer"),
            "stripped": False,
            "vermagic": modinfo(str(module), "vermagic"),
        },
        "functions": functions,
        "imports": imports,
        "relocations": relocations,
        "callbacks": callbacks,
        "states": states,
        "stateSection": state_section,
        "framework": inspect_framework(args, functions, changed_objects),
        "shadowImports": shadow_imports,
        "skippedChangedObjects": skipped_changed_objects,
    }


def compare_closure(expected, actual):
    mismatches = {}

    expected_values = {
        "functions": canonical_functions(expected["functions"]),
        "imports": sorted(expected["imports"]),
        "relocations": sorted(expected["relocations"]),
        "callbacks": canonical_callbacks(expected["callbacks"]),
        "states": expected["states"],
        "stateSection": expected["stateSection"],
        "framework": expected["framework"],
    }
    for field, value in expected_values.items():
        actual_value = actual[field]
        if field == "functions":
            actual_value = canonical_functions(actual_value)
        elif field in ("imports", "relocations"):
            actual_value = sorted(actual_value)
        elif field == "callbacks":
            actual_value = canonical_callbacks(actual_value)
        if actual_value != value:
            mismatches[field] = {"expected": value, "actual": actual_value}

    module_expectations = {
        "name": expected["moduleName"],
        "livepatch": "Y",
        "stripped": False,
    }
    for field, value in module_expectations.items():
        if actual["module"][field] != value:
            mismatches[f"module.{field}"] = {
                "expected": value,
                "actual": actual["module"][field],
            }

    if actual["module"]["vermagic"] != expected["vermagic"]:
        mismatches["module.vermagic"] = {
            "expected": expected["vermagic"],
            "actual": actual["module"]["vermagic"],
        }

    signature = expected["signature"]
    signature_values = {
        "signer": signature["signer"] if signature["required"] else "",
        "sigId": signature["sigId"] if signature["required"] else "",
        "sigKey": signature["sigKey"] if signature["required"] else "",
    }
    for field, value in signature_values.items():
        if actual["module"][field] != value:
            mismatches[f"module.{field}"] = {
                "expected": value,
                "actual": actual["module"][field],
            }

    if actual["buildInvocation"]["nonReplaceRequested"] is not True:
        mismatches["buildInvocation.nonReplaceRequested"] = {
            "expected": True,
            "actual": actual["buildInvocation"]["nonReplaceRequested"],
        }

    for field in ("shadowImports", "skippedChangedObjects"):
        if actual[field]:
            mismatches[field] = {"expected": [], "actual": actual[field]}

    return {
        "schemaVersion": 1,
        "matches": not mismatches,
        "mismatches": mismatches,
    }


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--inspection", required=True)
    parser.add_argument("--closure", required=True)
    parser.add_argument("--changed-objects")
    parser.add_argument("--framework-source", required=True)
    parser.add_argument("--generated-header", required=True)
    parser.add_argument("--framework-carrier-object", required=True)
    parser.add_argument("--build-flag", action="append", default=[])
    parser.add_argument("--forbidden-skipped-object", action="append", default=[])
    return parser.parse_args()


def main():
    args = parse_args()
    expected = read_json(args.expected)
    actual = inspect_module(args)
    closure = compare_closure(expected, actual)
    write_json(args.inspection, actual)
    write_json(args.closure, closure)
    if not closure["matches"]:
        json.dump(closure, sys.stderr, indent=2, sort_keys=True)
        sys.stderr.write("\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
