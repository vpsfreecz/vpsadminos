/*
 * Independent, unexecuted instruction contracts for the host resolver tests.
 * Always-inline wrappers provide real compiler-generated inline DWARF. Named
 * fixture labels are the oracle for probe offsets, independent of selection.
 */
#ifndef FIXTURE_LINE
#define FIXTURE_LINE 20
#endif
#ifndef CALL_PADDING
#define CALL_PADDING 0
#endif
#ifndef FUSE_OBJECT
#define FUSE_OBJECT "fuse"
#endif
#ifndef FUSE_ORDINAL
#define FUSE_ORDINAL "1"
#endif
#ifndef FUSE_CALLEE
#define FUSE_CALLEE "fuse_copy_finish"
#endif
#ifndef FUSE_INLINE
#define FUSE_INLINE fuse_ref_page
#endif
#ifndef TIMER_PADDING
#define TIMER_PADDING 48
#endif
#ifndef DESTRUCTOR_ZERO_WIDTH
#define DESTRUCTOR_ZERO_WIDTH 32
#endif

#if DESTRUCTOR_ZERO_WIDTH == 8
#define DESTRUCTOR_REGISTER "%dl"
#elif DESTRUCTOR_ZERO_WIDTH == 16
#define DESTRUCTOR_REGISTER "%dx"
#elif DESTRUCTOR_ZERO_WIDTH == 32
#define DESTRUCTOR_REGISTER "%edx"
#elif DESTRUCTOR_ZERO_WIDTH == 64
#define DESTRUCTOR_REGISTER "%rdx"
#else
#error Unsupported destructor control width
#endif

#define INLINE static __attribute__((always_inline)) inline
#define FUNCTION __attribute__((noinline, noclone, used))
#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)
#define LABEL(name) ".globl fixture_" #name "\nfixture_" #name ":\n"
#ifdef FUSE_RELOCATION_WITHOUT_CALL
#define FINISH_CALL \
  "nop\n.long \".klp.sym." FUSE_OBJECT "." FUSE_CALLEE "," FUSE_ORDINAL "\" - . - 4\n"
#else
#define FINISH_CALL \
  "call \".klp.sym." FUSE_OBJECT "." FUSE_CALLEE "," FUSE_ORDINAL "\"\n"
#endif

/* These are type facts, not an emulation of kernel operations. */
struct rhash_head { void *next; };
struct timer_list { unsigned char opaque[40]; };
struct inet_frag_queue {
  struct rhash_head node;
  unsigned char before_timer[TIMER_PADDING];
  struct timer_list timer;
  unsigned int lock;
};
struct inet_frag_queue fixture_queue;
struct work_struct { unsigned char opaque[32]; };
struct delayed_work { struct work_struct work; };
struct sock_xprt {
  unsigned char before_connect_worker[1600];
  struct delayed_work connect_worker;
};
struct sock_xprt fixture_transport;

#line FIXTURE_LINE "probe-sites-fixture.c"
INLINE void fuse_try_move_page(void)
{
  __asm__ volatile (
    "call \".klp.sym.fuse.unlock_request.part.0,1\"\n"
    "mov %r14, %rdi\n"
    LABEL(fuse_other_call)
    FINISH_CALL
  );
}

INLINE void FUSE_INLINE(void)
{
  __asm__ volatile (
    ".if " STRINGIFY(CALL_PADDING) "\n"
    ".space " STRINGIFY(CALL_PADDING) ", 0x90\n"
    ".endif\n"
    "call \".klp.sym.fuse.unlock_request.part.0,1\"\n"
    "mov %r14, %rdi\n"
    LABEL(fuse_finish_call)
#ifndef MISSING_FUSE_CALL
    FINISH_CALL
#endif
#ifdef DUPLICATE_FUSE_CALL
    FINISH_CALL
#endif
  );
}

FUNCTION void fuse_copy_page(void)
{
  fuse_try_move_page();
  FUSE_INLINE();
}

FUNCTION void xs_connect(void)
{
  __asm__ volatile (
    "mov %rbx, %rdi\n"
    "movabs $0x2c5d466e3067e6a, %rsi\n"
    "mov $0x30, %edx\n"
    LABEL(sunrpc_shadow_alloc_call)
    "call klp_shadow_alloc\n"
  );
}

FUNCTION void vpsadminos_sunrpc_tls_drain(void)
{
  __asm__ volatile (
    "call vpsadminos_sunrpc_tls_take_work\n"
    "mov %rax, %rbx\n"
    "test %rbx, %rbx\n"
    "je 1f\n"
    "mov 0x18(%rbx), %rax\n"
    "lea 0x640(%rax), %rdi\n"
    LABEL(sunrpc_callback_claim_call)
    "call cancel_delayed_work_sync\n"
    "1:\n"
  );
}

FUNCTION void vpsadminos_sunrpc_cb_release(void)
{
  __asm__ volatile (
    "mov 0x18(%rdi), %rax\n"
    "mov %rax, %rdi\n"
    "movabs $0x2c5d466e3067e6a, %rsi\n"
    /* Partial writes leave the known nonzero upper pointer bits intact. */
    "movabs $0x1122334455667788, %rdx\n"
#ifdef DESTRUCTOR_ZERO_MOVE
    "mov $0, " DESTRUCTOR_REGISTER "\n"
#else
    "xor " DESTRUCTOR_REGISTER ", " DESTRUCTOR_REGISTER "\n"
#endif
    LABEL(sunrpc_callback_release_call)
    "call klp_shadow_free\n"
  );
}

#ifdef STANDALONE_INET_FRAG_CREATE
FUNCTION void inet_frag_create(void)
#else
INLINE void inet_frag_create(void)
#endif
{
  __asm__ volatile (
    "call rhashtable_insert_slow\n"
    "test %rax, %rax\n"
    "jne 1f\n"
    "mov -0x58(%rbp), %rdi\n"
    LABEL(inet_frag_timer_call)
    "call mod_timer\n"
    "mov -0x50(%rbp), %rdi\n"
    "call _raw_spin_unlock_bh\n"
    "1:\n"
  );
}

FUNCTION void inet_frag_find(void)
{
  inet_frag_create();
}

#ifdef TCP_REGISTER_DRIFT
#define REORDER32 "%r12d"
#define MSS32 "%r14d"
#define MSS64 "%r14"
#define RESULT32 "%r10d"
#define RESULT64 "%r10"
#define PROBE64 "%r11"
#else
#define REORDER32 "%ebx"
#define MSS32 "%r15d"
#define MSS64 "%r15"
#define RESULT32 "%eax"
#define RESULT64 "%rax"
#define PROBE64 "%rdx"
#endif

INLINE void tcp_mtu_probe(void)
{
  __asm__ volatile (
    "mov 0x578(%rbx), " REORDER32 "\n"
    "mov 0x5a0(%rax), " MSS32 "\n"
    "mov " REORDER32 ", " RESULT32 "\n"
    "mov -0x30(%rbp), %rdi\n"
    "movslq %r8d, " PROBE64 "\n"
#if defined(TCP_WRAP_BEFORE_WIDEN) || defined(TCP_NARROW_ADD)
    "add $1, " RESULT32 "\n"
#else
    "add $1, " RESULT64 "\n"
#endif
#ifdef TCP_NARROW_MULTIPLY
    "imul " MSS32 ", " RESULT32 "\n"
#else
    "imul " MSS64 ", " RESULT64 "\n"
#endif
    "mov 0x674(%rdi), %ecx\n"
    "add " PROBE64 ", " RESULT64 "\n"
#ifdef TCP_CLOBBER_RESULT
    "xor " RESULT32 ", " RESULT32 "\n"
#endif
#ifdef TCP_CLOBBER_REORDER
    "xor " REORDER32 ", " REORDER32 "\n"
#endif
#ifdef TCP_CLOBBER_MSS
    "xor " MSS32 ", " MSS32 "\n"
#endif
    "mov 0x624(%rdi), %edx\n"
    "sub %ecx, %edx\n"
    LABEL(tcp_mtu_size_cmp)
    "cmp " RESULT64 ", %rdx\n"
    "jb 1f\n"
    "mov 0x59c(%rdi), %esi\n"
    "mov %rsi, %rdx\n"
    "cmp " RESULT64 ", %rsi\n"
    "jb 1f\n"
    "1:\n"
  );
}

FUNCTION void tcp_write_xmit(void)
{
  tcp_mtu_probe();
}
