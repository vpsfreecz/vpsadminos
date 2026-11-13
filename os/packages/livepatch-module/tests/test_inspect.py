import copy
import importlib.util
import struct
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "inspect.py"
SPEC = importlib.util.spec_from_file_location("livepatch_inspect", MODULE_PATH)
INSPECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSPECT)


FRAMEWORK_PATCH_SHA256 = (
    "46c9e631d4c8a767e32d49e3ee1e8cef7ca43f926628cd9c817e7fd47983a597"
)
GENERATED_HEADER_SHA256 = "a" * 64
CALLBACKS = [
    {
        "kind": "pre_patch",
        "object": "vmlinux",
        "symbol": "vpsadminos_uname_level_p1_pre_patch",
    },
    {
        "kind": "post_patch",
        "object": "vmlinux",
        "symbol": "vpsadminos_uname_level_p1_post_patch",
    },
    {
        "kind": "post_unpatch",
        "object": "vmlinux",
        "symbol": "vpsadminos_uname_level_p1_post_unpatch",
    },
]
STATES = [
    {
        "id": "0x48573a1786d6fe85",
        "version": 1,
        "data": "0x0000000000000000",
    }
]
STATE_SECTION = {
    "recordSize": 24,
    "alignment": 8,
    "sentinel": {
        "id": "0x0000000000000000",
        "version": 0,
        "data": "0x0000000000000000",
        "size": 24,
        "zero": True,
    },
}
FRAMEWORK = {
    "frameworkPatchSha256": FRAMEWORK_PATCH_SHA256,
    "generatedHeaderSha256": GENERATED_HEADER_SHA256,
    "guardErrno": "-ESTALE",
    "guardReturnCount": 1,
    "carrier": {"object": "kernel/bpf/core.o", "present": True},
    "replacementFunctions": [],
}


class FakeSymbol:
    def __init__(self, name, symbol_type, section_index):
        self.name = name
        self.values = {
            "st_info": {"type": symbol_type},
            "st_shndx": section_index,
        }

    def __getitem__(self, key):
        return self.values[key]


class FakeSection:
    def __init__(self, name, data=b""):
        self.name = name
        self.section_data = data

    def data(self):
        return self.section_data


class FakeRelocation:
    def __init__(self, offset, symbol_index, addend):
        self.values = {
            "r_offset": offset,
            "r_info_sym": symbol_index,
            "r_addend": addend,
        }

    def __getitem__(self, key):
        return self.values[key]


class FakeRelocationSection(FakeSection):
    def __init__(self, name, symbol_table_index, relocations):
        super().__init__(name)
        self.symbol_table_index = symbol_table_index
        self.relocations = relocations

    def __getitem__(self, key):
        if key == "sh_link":
            return self.symbol_table_index
        raise KeyError(key)

    def is_RELA(self):
        return True

    def iter_relocations(self):
        return iter(self.relocations)


class FakeSymbolTable:
    def __init__(self, symbols):
        self.symbols = symbols

    def get_symbol(self, index):
        return self.symbols[index]


class FakeElf:
    elfclass = 64
    little_endian = True

    def __init__(self, sections_by_name, sections_by_index):
        self.sections_by_name = sections_by_name
        self.sections_by_index = sections_by_index

    def get_section_by_name(self, name):
        return self.sections_by_name.get(name)

    def get_section(self, index):
        return self.sections_by_index.get(index)


class CompareClosureTest(unittest.TestCase):
    def expected(self):
        return {
            "moduleName": "lp_612113_1_deadbeef0000",
            "functions": [
                {"object": "vmlinux", "symbol": "target", "sympos": 0}
            ],
            "imports": [
                ".klp.sym.vmlinux.helper,0",
                ".klp.sym.vmlinux.init_uts_ns,0",
                ".klp.sym.vmlinux.uts_proc_notify,0",
                ".klp.sym.vmlinux.uts_sem,0",
            ],
            "relocations": [
                ".klp.rela.vmlinux.text.target",
                ".klp.rela.vmlinux.text.vpsadminos_uname_level_p1_publish",
                ".klp.rela.vmlinux.text.vpsadminos_uname_level_p1_release_matches",
            ],
            "signature": {
                "required": False,
                "signer": None,
                "sigId": None,
                "sigKey": None,
            },
            "callbacks": copy.deepcopy(CALLBACKS),
            "states": copy.deepcopy(STATES),
            "stateSection": copy.deepcopy(STATE_SECTION),
            "framework": copy.deepcopy(FRAMEWORK),
            "vermagic": "6.12.113 SMP preempt mod_unload",
        }

    def actual(self):
        return {
            "buildInvocation": {
                "flags": ["--non-replace"],
                "nonReplaceRequested": True,
            },
            "module": {
                "name": "lp_612113_1_deadbeef0000",
                "livepatch": "Y",
                "sigId": "",
                "sigKey": "",
                "signer": "",
                "stripped": False,
                "vermagic": "6.12.113 SMP preempt mod_unload",
            },
            "functions": [
                {"object": "vmlinux", "symbol": "target", "sympos": 0}
            ],
            "imports": [
                ".klp.sym.vmlinux.helper,0",
                ".klp.sym.vmlinux.init_uts_ns,0",
                ".klp.sym.vmlinux.uts_proc_notify,0",
                ".klp.sym.vmlinux.uts_sem,0",
            ],
            "relocations": [
                ".klp.rela.vmlinux.text.target",
                ".klp.rela.vmlinux.text.vpsadminos_uname_level_p1_publish",
                ".klp.rela.vmlinux.text.vpsadminos_uname_level_p1_release_matches",
            ],
            "callbacks": copy.deepcopy(CALLBACKS),
            "states": copy.deepcopy(STATES),
            "stateSection": copy.deepcopy(STATE_SECTION),
            "framework": copy.deepcopy(FRAMEWORK),
            "shadowImports": [],
            "skippedChangedObjects": [],
        }

    def test_matching_closure(self):
        result = INSPECT.compare_closure(self.expected(), self.actual())
        self.assertTrue(result["matches"])
        self.assertEqual({}, result["mismatches"])

    def test_extra_generated_function_fails(self):
        actual = self.actual()
        actual["functions"].append(
            {"object": "vmlinux", "symbol": "unexpected", "sympos": 0}
        )
        result = INSPECT.compare_closure(self.expected(), actual)
        self.assertFalse(result["matches"])
        self.assertIn("functions", result["mismatches"])

    def test_requested_mode_is_not_runtime_state(self):
        actual = self.actual()
        self.assertNotIn("replace", actual)
        actual["buildInvocation"]["nonReplaceRequested"] = False
        result = INSPECT.compare_closure(self.expected(), actual)
        self.assertFalse(result["matches"])
        self.assertIn(
            "buildInvocation.nonReplaceRequested", result["mismatches"]
        )

    def test_exact_vermagic_and_signature_mismatch_fail(self):
        actual = self.actual()
        actual["module"]["vermagic"] = "6.12.113 SMP mod_unload"
        actual["module"]["signer"] = "unexpected"
        result = INSPECT.compare_closure(self.expected(), actual)
        self.assertFalse(result["matches"])
        self.assertIn("module.vermagic", result["mismatches"])
        self.assertIn("module.signer", result["mismatches"])

    def test_framework_callback_violations_fail(self):
        mutations = (
            lambda actual: actual["callbacks"].pop(),
            lambda actual: actual["callbacks"][0].update(object="module"),
            lambda actual: actual["callbacks"][0].update(symbol="wrong"),
            lambda actual: actual["callbacks"].append(
                {
                    "kind": "pre_unpatch",
                    "object": "vmlinux",
                    "symbol": "unexpected",
                }
            ),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                actual = self.actual()
                mutate(actual)
                result = INSPECT.compare_closure(self.expected(), actual)
                self.assertFalse(result["matches"])
                self.assertIn("callbacks", result["mismatches"])

    def test_framework_state_and_source_violations_fail(self):
        mutations = (
            lambda actual: actual["states"][0].update(id="0x0000000000000001"),
            lambda actual: actual["states"][0].update(version=2),
            lambda actual: actual["states"][0].update(data="0x0000000000000001"),
            lambda actual: actual["stateSection"].update(recordSize=48),
            lambda actual: actual["stateSection"].update(alignment=4),
            lambda actual: actual["stateSection"]["sentinel"].update(
                id="0x0000000000000001"
            ),
            lambda actual: actual["stateSection"]["sentinel"].update(version=1),
            lambda actual: actual["stateSection"]["sentinel"].update(
                data="0x0000000000000001"
            ),
            lambda actual: actual["stateSection"]["sentinel"].update(size=48),
            lambda actual: actual["stateSection"]["sentinel"].update(zero=False),
            lambda actual: actual["framework"].update(
                frameworkPatchSha256="b" * 64
            ),
            lambda actual: actual["framework"].update(
                generatedHeaderSha256="b" * 64
            ),
            lambda actual: actual["framework"].update(guardErrno=None),
            lambda actual: actual["framework"].update(guardReturnCount=2),
            lambda actual: actual["framework"]["carrier"].update(present=False),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                actual = self.actual()
                mutate(actual)
                result = INSPECT.compare_closure(self.expected(), actual)
                self.assertFalse(result["matches"])

    def test_payload_and_generated_closure_violations_fail(self):
        actual = self.actual()
        actual["shadowImports"] = ["klp_shadow_get"]
        actual["skippedChangedObjects"] = ["net/core/filter.o"]
        actual["imports"].append(".klp.sym.vmlinux.unexpected,0")
        actual["relocations"].append(".klp.rela.vmlinux.text.unexpected")
        replacement = {
            "object": "vmlinux",
            "symbol": "vpsadminos_uname_level_p1_publish",
            "sympos": 0,
        }
        actual["functions"].append(replacement)
        actual["framework"]["replacementFunctions"].append(replacement)
        result = INSPECT.compare_closure(self.expected(), actual)
        self.assertFalse(result["matches"])
        self.assertIn("functions", result["mismatches"])
        self.assertIn("imports", result["mismatches"])
        self.assertIn("relocations", result["mismatches"])
        self.assertIn("framework", result["mismatches"])
        self.assertIn("shadowImports", result["mismatches"])
        self.assertIn("skippedChangedObjects", result["mismatches"])


class InventoryDecoderTest(unittest.TestCase):
    def test_section_symbols_resolve_function_name_and_object_relocations(self):
        data = bytearray(56)
        struct.pack_into("<Q", data, 32, 1)
        strings = FakeSection(".kpatch.strings", b"target\0vmlinux\0")
        functions = FakeSection(".kpatch.funcs", bytes(data))
        symbol_table = FakeSymbolTable([FakeSymbol("", "STT_SECTION", 7)])
        function_relocations = FakeRelocationSection(
            ".rela.kpatch.funcs",
            8,
            [
                FakeRelocation(40, 0, 0),
                FakeRelocation(48, 0, 7),
            ],
        )
        elf = FakeElf(
            {
                ".kpatch.funcs": functions,
                ".rela.kpatch.funcs": function_relocations,
                ".kpatch.strings": strings,
            },
            {7: strings, 8: symbol_table},
        )

        self.assertEqual(
            [{"object": "vmlinux", "symbol": "target", "sympos": 1}],
            INSPECT.inspect_functions(elf, symbol_table),
        )

    def test_section_symbol_resolves_callback_object_relocation(self):
        callbacks_section = FakeSection(".kpatch.callbacks.pre_patch")
        strings = FakeSection(".kpatch.strings", b"vmlinux\0")
        symbol_table = FakeSymbolTable(
            [
                FakeSymbol(
                    "vpsadminos_uname_level_p1_pre_patch",
                    "STT_FUNC",
                    3,
                ),
                FakeSymbol("", "STT_SECTION", 7),
            ]
        )
        callback_relocations = FakeRelocationSection(
            ".rela.kpatch.callbacks.pre_patch",
            8,
            [
                FakeRelocation(0, 0, 0),
                FakeRelocation(8, 1, 0),
            ],
        )
        elf = FakeElf(
            {".rela.kpatch.callbacks.pre_patch": callback_relocations},
            {7: strings, 8: symbol_table},
        )

        self.assertEqual(
            [CALLBACKS[0]],
            INSPECT.decode_callback_records(
                "pre_patch",
                0,
                16,
                INSPECT.relocation_map(elf, callbacks_section),
                strings.data(),
            ),
        )

    def test_ordinary_relocation_symbol_name_is_unchanged(self):
        symbol = FakeSymbol("ordinary", "STT_FUNC", "SHN_UNDEF")
        self.assertEqual(
            "ordinary",
            INSPECT.relocation_symbol_name(FakeElf({}, {}), symbol),
        )

    def test_section_symbol_rejects_special_or_invalid_index(self):
        for section_index in ("SHN_ABS", "SHN_UNDEF", -1, 99):
            with self.subTest(section_index=section_index):
                symbol = FakeSymbol("", "STT_SECTION", section_index)
                with self.assertRaises(ValueError):
                    INSPECT.relocation_symbol_name(FakeElf({}, {}), symbol)

    def test_exact_callback_record(self):
        callbacks = INSPECT.decode_callback_records(
            "pre_patch",
            0,
            16,
            {
                0: ("vpsadminos_uname_level_p1_pre_patch", 0),
                8: (".kpatch.strings", 0),
            },
            b"vmlinux\0",
        )
        self.assertEqual([CALLBACKS[0]], callbacks)

    def test_empty_callback_inventory(self):
        self.assertEqual(
            [],
            INSPECT.decode_callback_records("pre_unpatch", 0, 0, {}, b""),
        )

    def test_callback_requires_both_exact_relocations(self):
        with self.assertRaises(ValueError):
            INSPECT.decode_callback_records(
                "pre_patch",
                0,
                16,
                {0: ("vpsadminos_uname_level_p1_pre_patch", 0)},
                b"vmlinux\0",
            )

    def test_callback_rejects_extra_record_relocation(self):
        with self.assertRaises(ValueError):
            INSPECT.decode_callback_records(
                "pre_patch",
                0,
                16,
                {
                    0: ("vpsadminos_uname_level_p1_pre_patch", 0),
                    4: ("unexpected", 0),
                    8: (".kpatch.strings", 0),
                },
                b"vmlinux\0",
            )

    def test_exact_state_and_zero_sentinel(self):
        state = struct.pack("<QI4xQ", 0x48573A1786D6FE85, 1, 0)
        states, section = INSPECT.decode_state_section(
            state + bytes(24), 0, 24, 48, "<", 8
        )
        self.assertEqual(STATES, states)
        self.assertEqual(STATE_SECTION, section)

    def test_extra_state_record_is_rejected(self):
        state = struct.pack("<QI4xQ", 0x48573A1786D6FE85, 1, 0)
        with self.assertRaises(ValueError):
            INSPECT.decode_state_section(
                state + state + bytes(24), 0, 48, 72, "<", 8
            )

    def test_misaligned_state_record_is_rejected(self):
        state = struct.pack("<QI4xQ", 0x48573A1786D6FE85, 1, 0)
        with self.assertRaises(ValueError):
            INSPECT.decode_state_section(
                bytes(4) + state + bytes(24), 4, 28, 52, "<", 8
            )


if __name__ == "__main__":
    unittest.main()
