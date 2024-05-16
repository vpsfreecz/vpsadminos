#include <ruby.h>

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/time.h>
#include <sys/resource.h>
#include <errno.h>

/**
 * @overload set(pid, resource, soft, hard)
 *   Set process resource limit
 *   @param pid [Integer] process ID
 *   @param resource [Integer] resource type
 *   @param soft [Integer] current limit
 *   @param hard [Integer] maximum limit
 *   @raise [SystemCallError]
 *   @return [Boolean]
 */
VALUE osctld_prlimits_set(VALUE self, VALUE vPid, VALUE vResource, VALUE vSoft, VALUE vHard)
{
	pid_t pid = (pid_t) NUM2LONG(vPid);
	int resource = NUM2INT(vResource);
	struct rlimit limit = {
		.rlim_cur = (rlim_t) NUM2ULONG(vSoft),
		.rlim_max = (rlim_t) NUM2ULONG(vHard)
	};
	int ret;
	char error[255];

	if ((ret = prlimit(pid, resource, &limit, NULL)) == 0)
		return Qtrue;

	rb_raise(
		rb_eSystemCallError,
		"prlimit() failed: %d - %s",
		ret, strerror_r(errno, error, sizeof(error))
	);
}

void Init_native() {
	VALUE OsCtld = rb_define_module("OsCtld");
	VALUE OsCtldPrLimits = rb_define_module_under(OsCtld, "PrLimits");

	rb_define_const(OsCtldPrLimits, "AS", INT2NUM(RLIMIT_AS));
	rb_define_const(OsCtldPrLimits, "CORE", INT2NUM(RLIMIT_CORE));
	rb_define_const(OsCtldPrLimits, "CPU", INT2NUM(RLIMIT_CPU));
	rb_define_const(OsCtldPrLimits, "DATA", INT2NUM(RLIMIT_DATA));
	rb_define_const(OsCtldPrLimits, "FSIZE", INT2NUM(RLIMIT_FSIZE));
	rb_define_const(OsCtldPrLimits, "LOCKS", INT2NUM(RLIMIT_LOCKS));
	rb_define_const(OsCtldPrLimits, "MEMLOCK", INT2NUM(RLIMIT_MEMLOCK));
	rb_define_const(OsCtldPrLimits, "MSGQUEUE", INT2NUM(RLIMIT_MSGQUEUE));
	rb_define_const(OsCtldPrLimits, "NICE", INT2NUM(RLIMIT_NICE));
	rb_define_const(OsCtldPrLimits, "NOFILE", INT2NUM(RLIMIT_NOFILE));
	rb_define_const(OsCtldPrLimits, "NPROC", INT2NUM(RLIMIT_NPROC));
	rb_define_const(OsCtldPrLimits, "RSS", INT2NUM(RLIMIT_RSS));
	rb_define_const(OsCtldPrLimits, "RTPRIO", INT2NUM(RLIMIT_RTPRIO));
	rb_define_const(OsCtldPrLimits, "RTTIME", INT2NUM(RLIMIT_RTTIME));
	rb_define_const(OsCtldPrLimits, "SIGPENDING", INT2NUM(RLIMIT_SIGPENDING));
	rb_define_const(OsCtldPrLimits, "STACK", INT2NUM(RLIMIT_STACK));
	rb_define_const(OsCtldPrLimits, "INFINITY", ULONG2NUM(RLIM_INFINITY));

	rb_define_singleton_method(OsCtldPrLimits, "set", osctld_prlimits_set, 4);
}
