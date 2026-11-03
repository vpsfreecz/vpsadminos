"""Independent public-contract controls using tiny, unexecuted host ELFs."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from elftools.elf.elffile import ELFFile


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("probe_sites", HERE / "probe-sites.py")
RESOLVER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RESOLVER
SPEC.loader.exec_module(RESOLVER)

ENTRIES = {
    "svm_entry": "svm_vcpu_run",
    "nft_insert_entry": "nft_pipapo_insert",
    "sunrpc_worker_entry": "xs_tcp_tls_setup_socket",
}
CALLS = {
    "sunrpc_shadow_alloc": ("xs_connect", "sunrpc_shadow_alloc_call"),
    "sunrpc_callback_claim": (
        "vpsadminos_sunrpc_tls_drain", "sunrpc_callback_claim_call"
    ),
    "sunrpc_callback_release": (
        "vpsadminos_sunrpc_cb_release", "sunrpc_callback_release_call"
    ),
    "inet_frag_timer": ("inet_frag_find", "inet_frag_timer_call"),
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def symbols(path):
    """Use fixture-authored labels, rather than resolver-selected instructions."""
    with Path(path).open("rb") as stream:
        elf = ELFFile(stream)
        table = elf.get_section_by_name(".symtab")
        return {
            symbol.name: (symbol["st_shndx"], symbol["st_value"])
            for symbol in table.iter_symbols()
        }


def special_relocation_fixture(original, destination):
    # GNU objcopy regenerates relocation names from their target section.
    # Change only this tiny fixture's section-name metadata through pyelftools;
    # keep the real SHT_RELA entries, linked symbol table and target untouched.
    contents = bytearray(Path(original).read_bytes())
    elf = ELFFile(io.BytesIO(contents))
    sections = list(elf.iter_sections())
    relocation_index = next(i for i, s in enumerate(sections) if s.name == ".rela.text")
    strings_index = elf.header["e_shstrndx"]
    strings = sections[strings_index]
    old_strings = strings.data()
    replacement = old_strings + b".klp.rela.fuse..text\0"
    relocation_header = sections[relocation_index].header
    relocation_header["sh_name"] = len(old_strings)
    strings_header = strings.header
    strings_header["sh_offset"] = len(contents)
    strings_header["sh_size"] = len(replacement)
    contents.extend(replacement)
    for index, header in ((relocation_index, relocation_header),
                          (strings_index, strings_header)):
        offset = elf.header["e_shoff"] + index * elf.header["e_shentsize"]
        encoded = elf.structs.Elf_Shdr.build(header)
        contents[offset:offset + len(encoded)] = encoded
    Path(destination).write_bytes(contents)


class ProbeSitesContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="livepatch-probe-sites-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        cls.compiler = shlex.split(os.environ.get("CC", "cc"))
        cls.objcopy = shlex.split(os.environ.get("OBJCOPY", "objcopy"))
        cls.fixtures = {}

    def command(self, argv):
        result = subprocess.run(argv, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def fixture(self, *defines, debug=True, split_sections=False):
        key = (defines, debug, split_sections)
        if key in self.fixtures:
            return self.fixtures[key]
        directory = self.work / str(len(self.fixtures))
        directory.mkdir()
        self.fixtures[key] = directory / "candidate.o"
        flags = [
            "-O2", "-gdwarf-4", "-g" if debug else "-g0", "-fno-pie",
            "-fno-stack-protector", "-fno-omit-frame-pointer", "-mno-red-zone",
        ]
        if split_sections:
            flags.append("-ffunction-sections")
        flags.extend("-D" + define for define in defines)
        objects = []
        for name in ("entries.S", "sites.c"):
            target = directory / (name + ".o")
            self.command(self.compiler + flags + [
                "-c", str(HERE / "probe-sites-tests" / name), "-o", str(target)
            ])
            objects.append(str(target))
        self.command(self.compiler + [
            "-r", "-nostdlib", "-no-pie", "-Wl,--build-id=sha1", *objects,
            "-o", str(self.fixtures[key])
        ])
        return self.fixtures[key]

    def original_fuse(self, unsafe=False, duplicate=False, scheduled=False):
        directory = self.work / f"fuse-{unsafe}-{duplicate}-{scheduled}"
        directory.mkdir(exist_ok=True)
        result = directory / "fuse.o"
        if result.exists():
            return result
        first = directory / "first.o"
        flags = ["-DUNSAFE_CALLEE_FRAME"] if unsafe else []
        if scheduled:
            flags.append("-DSCHEDULED_CALLEE_PROLOGUE")
        self.command(self.compiler + flags + [
            "-c", str(HERE / "probe-sites-tests" / "callee.S"), "-o", str(first)
        ])
        objects = [str(first)]
        if duplicate:
            second = directory / "second.o"
            second.write_bytes(first.read_bytes())
            objects.append(str(second))
        self.command(self.compiler + [
            "-r", "-nostdlib", "-no-pie", *objects, "-o", str(result)
        ])
        return result

    def resolve(self, witness, module=None, **kwargs):
        module = module or self.fixture()
        return RESOLVER.resolve_site(witness, module, digest(module), **kwargs)

    def rejects(self, witness, module, **kwargs):
        with self.assertRaises(RESOLVER.ResolutionError) as error:
            self.resolve(witness, module, **kwargs)
        self.assertIn(witness, str(error.exception))

    def assert_marker(self, site, module, caller, marker):
        oracle = symbols(module)
        caller_section, caller_offset = oracle[caller]
        marker_section, marker_offset = oracle["fixture_" + marker]
        self.assertEqual(marker_section, caller_section)
        self.assertEqual(site["symbol"], caller)
        self.assertEqual(site["symbol_pos"], 0)
        self.assertEqual(site["offset"], marker_offset - caller_offset)

    def test_entry_boundaries_follow_the_selected_function(self):
        for defines in ((), ("TEXT_PADDING=113",)):
            module = self.fixture(*defines)
            for witness, caller in ENTRIES.items():
                with self.subTest(witness=witness, defines=defines):
                    site = self.resolve(witness, module)
                    self.assert_marker(site, module, caller, caller + "_entry")
                    self.assertEqual(site["frame"], "preprologue")
                    self.assertEqual(site["registers"]["arg0"], {
                        "register": "rdi", "width": 64
                    })

    def test_entry_rejects_prefix_that_clobbers_arg0(self):
        module = self.fixture("UNSAFE_ENTRY_PREFIX")
        for witness in ENTRIES:
            with self.subTest(witness=witness):
                self.rejects(witness, module)

    def test_entry_rejects_fentry_after_an_established_frame(self):
        module = self.fixture("UNSAFE_ENTRY_FRAME")
        for witness in ENTRIES:
            with self.subTest(witness=witness):
                self.rejects(witness, module)

    def test_digest_is_checked_before_decoding(self):
        module = self.fixture()
        for expected in (None, "", "not-a-sha256", "0" * 63, "A" * 64, "0" * 64):
            with self.subTest(expected=expected):
                with self.assertRaises(RESOLVER.ResolutionError):
                    RESOLVER.resolve_site("svm_entry", module, expected)

    def test_module_changed_after_capture_is_rejected(self):
        original = self.fixture()
        expected = digest(original)
        changed = self.work / "changed.o"
        changed.write_bytes(original.read_bytes() + b"changed after capture")
        with self.assertRaises(RESOLVER.ResolutionError):
            RESOLVER.resolve_site("svm_entry", changed, expected)

    def test_unknown_witness_is_not_a_generic_probe_mode(self):
        with self.assertRaises(RESOLVER.ResolutionError):
            self.resolve("arbitrary_function")

    def test_missing_function_symbol_is_rejected(self):
        original = self.fixture()
        changed = self.work / "without-svm.o"
        self.command(self.objcopy + [
            "--redefine-sym", "svm_vcpu_run=not_svm_vcpu_run",
            str(original), str(changed)
        ])
        self.rejects("svm_entry", changed)

    def test_duplicate_exact_function_symbol_is_rejected(self):
        duplicate = self.work / "duplicate.o"
        self.command(self.compiler + [
            "-c", str(HERE / "probe-sites-tests" / "duplicate.S"),
            "-o", str(duplicate)
        ])
        changed = self.work / "duplicate-candidate.o"
        self.command(self.compiler + [
            "-r", "-nostdlib", "-no-pie", str(self.fixture()), str(duplicate),
            "-o", str(changed)
        ])
        self.rejects("svm_entry", changed)

    def test_fuse_selects_inline_path_not_the_other_identical_callee(self):
        for defines in ((), ("CALL_PADDING=37", "FIXTURE_LINE=1500")):
            module = self.fixture(*defines)
            site = self.resolve("fuse_finish", module, fuse_module=self.original_fuse())
            self.assert_marker(site, module, "fuse_copy_page", "fuse_finish_call")
            self.assertNotEqual(site["offset"],
                                symbols(module)["fixture_fuse_other_call"][1])
            self.assertEqual(site["inline"], "fuse_ref_page")
            self.assertEqual(site["return_offset"],
                             site["offset"] + site["instruction_length"])
            self.assertEqual(site["instruction_length"], 5)
            self.assertEqual(site["callee"]["object"], "fuse")
            self.assertEqual(site["callee"]["symbol"], "fuse_copy_finish")
            self.assertEqual(site["callee"]["symbol_pos"], 1)
            self.assertEqual(site["callee"]["frame"], "preprologue")

    def test_fuse_rejects_wrong_inline_callee_namespace_and_ordinal(self):
        variants = (
            'FUSE_INLINE=not_fuse_ref_page', 'FUSE_CALLEE="not_finish"',
            'FUSE_OBJECT="not_fuse"', 'FUSE_ORDINAL="2"',
            "DUPLICATE_FUSE_CALL", "MISSING_FUSE_CALL",
            "FUSE_RELOCATION_WITHOUT_CALL",
        )
        for define in variants:
            with self.subTest(define=define):
                self.rejects("fuse_finish", self.fixture(define),
                             fuse_module=self.original_fuse())

    def test_fuse_accepts_prologue_scheduling_after_hold_boundary(self):
        original = self.original_fuse(scheduled=True)
        site = self.resolve("fuse_finish", fuse_module=original)
        oracle = symbols(original)
        section, start = oracle["fuse_copy_finish"]
        hold_section, hold = oracle["fixture_fuse_hold"]
        self.assertEqual(hold_section, section)
        self.assertEqual(site["callee"]["offset"], hold - start)
        self.assertEqual(site["callee"]["instruction_length"], 1)
        self.assertEqual(site["callee"]["frame"], "preprologue")

    def test_fuse_requires_inline_metadata(self):
        self.rejects("fuse_finish", self.fixture(debug=False),
                     fuse_module=self.original_fuse())

    def test_fuse_rejects_unsafe_or_ambiguous_original_callee(self):
        for options in ({"unsafe": True}, {"duplicate": True}):
            with self.subTest(options=options):
                self.rejects("fuse_finish", self.fixture(),
                             fuse_module=self.original_fuse(**options))

    def test_named_call_offsets_point_to_opcode_not_displacement(self):
        module = self.fixture()
        for witness, (caller, marker) in CALLS.items():
            with self.subTest(witness=witness):
                site = self.resolve(witness, module, sdk_vmlinux=module)
                self.assert_marker(site, module, caller, marker)
                self.assertEqual(site["instruction_length"], 5)

    def test_callback_release_accepts_complete_null_pointer_definitions(self):
        for width in (32, 64):
            for move in (False, True):
                defines = [f"DESTRUCTOR_ZERO_WIDTH={width}"]
                if move:
                    defines.append("DESTRUCTOR_ZERO_MOVE")
                with self.subTest(width=width, move=move):
                    module = self.fixture(*defines)
                    site = self.resolve("sunrpc_callback_release", module)
                    self.assert_marker(site, module, "vpsadminos_sunrpc_cb_release",
                                       "sunrpc_callback_release_call")
                    self.assertEqual(site["callee"]["symbol"], "klp_shadow_free")

    def test_callback_release_rejects_partial_null_pointer_definitions(self):
        for width in (8, 16):
            for move in (False, True):
                defines = [f"DESTRUCTOR_ZERO_WIDTH={width}"]
                if move:
                    defines.append("DESTRUCTOR_ZERO_MOVE")
                with self.subTest(width=width, move=move):
                    self.rejects("sunrpc_callback_release", self.fixture(*defines))

    def test_fragment_standalone_allocation_function_is_supported(self):
        module = self.fixture("STANDALONE_INET_FRAG_CREATE")
        site = self.resolve("inet_frag_timer", module, sdk_vmlinux=self.fixture())
        self.assert_marker(site, module, "inet_frag_create", "inet_frag_timer_call")
        self.assertEqual(site["object"], "livepatch_7")
        self.assertEqual(site["inline"], "inet_frag_create")
        self.assertEqual(site["kind"], "call_observe")
        self.assertEqual(site["frame"], "observe_only")
        self.assertEqual(site["instruction_length"], 5)
        self.assertEqual(site["callee"], {"object": "vmlinux", "symbol": "mod_timer",
                                          "symbol_pos": 0})

    def test_fragment_candidate_and_sdk_layout_must_agree(self):
        self.rejects("inet_frag_timer", self.fixture("TIMER_PADDING=56"),
                     sdk_vmlinux=self.fixture())

    def test_tcp_wide_observation_survives_supported_register_allocation(self):
        for defines, needed, reorder, mss in (
            ((), "rax", "rbx", "r15"),
            (("TCP_REGISTER_DRIFT", "FIXTURE_LINE=3000"), "r10", "r12", "r14"),
        ):
            with self.subTest(defines=defines):
                module = self.fixture(*defines)
                site = self.resolve("tcp_mtu_size", module)
                self.assert_marker(site, module, "tcp_write_xmit", "tcp_mtu_size_cmp")
                self.assertEqual(site["kind"], "tcp_size_observe")
                for role, register, width in (
                    ("needed", needed, 64), ("reordering", reorder, 32), ("mss", mss, 32)
                ):
                    self.assertEqual(site["registers"][role], {
                        "register": register, "width": width
                    })

    def test_tcp_rejects_wrapped_narrow_or_dead_values(self):
        for define in (
            "TCP_WRAP_BEFORE_WIDEN", "TCP_NARROW_ADD", "TCP_NARROW_MULTIPLY",
            "TCP_CLOBBER_RESULT", "TCP_CLOBBER_REORDER", "TCP_CLOBBER_MSS",
        ):
            with self.subTest(define=define):
                self.rejects("tcp_mtu_size", self.fixture(define))

    def test_tcp_requires_inline_metadata(self):
        self.rejects("tcp_mtu_size", self.fixture(debug=False))

    def test_function_sections_are_not_assumed_to_be_coalesced_text(self):
        module = self.fixture(split_sections=True)
        for witness, caller in ENTRIES.items():
            with self.subTest(witness=witness):
                site = self.resolve(witness, module)
                self.assert_marker(site, module, caller, caller + "_entry")
        site = self.resolve("tcp_mtu_size", module)
        self.assert_marker(site, module, "tcp_write_xmit", "tcp_mtu_size_cmp")

    def test_special_livepatch_relocation_section_is_resolved(self):
        changed = self.work / "special-relocations.o"
        special_relocation_fixture(self.fixture(), changed)
        with changed.open("rb") as stream:
            section = ELFFile(stream).get_section_by_name(".klp.rela.fuse..text")
            self.assertEqual(section["sh_type"], "SHT_RELA")
        site = self.resolve("fuse_finish", changed, fuse_module=self.original_fuse())
        self.assert_marker(site, changed, "fuse_copy_page", "fuse_finish_call")

    def test_full_output_binds_all_nine_sites_and_type_facts(self):
        module = self.fixture()
        result = RESOLVER.resolve(module, digest(module), self.original_fuse(), module)
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["module_sha256"], digest(module))
        self.assertEqual(result["elf"]["elf_class"], 64)
        self.assertEqual(result["elf"]["machine"], "EM_X86_64")
        self.assertTrue(result["elf"]["build_id"])
        self.assertEqual(set(result["sites"]),
                         set(ENTRIES) | set(CALLS) | {"fuse_finish", "tcp_mtu_size"})
        self.assertEqual(result["abi"], {
            "sock_xprt_connect_worker": 1600,
            "inet_frag_timer": 56,
            "inet_frag_node": 0,
            "inet_frag_lock": 96,
        })


if __name__ == "__main__":
    unittest.main()
