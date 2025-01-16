#include <ruby.h>

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/**
 * @overload setns(fd, nstype)
 *   setns() system call
 *
 *   This function provides a workaround for Ruby >=3.3 extra system thread,
 *   which causes the kernel to deny setns() with EINVAL. It requires patched
 *   Ruby that exports rb_thread_start_timer_thread and rb_thread_stop_timer_thread
 *   functions.
 *
 *   @param fd [Integer] file descriptor number
 *   @param nstype [Integer] namespace type
 *   @raise [SystemCallError]
 *   @return [nil]
 */
static VALUE osctl_lib_native_setns(VALUE _self, VALUE vFd, VALUE vNstype) {
  int const fd = NUM2INT(vFd);
  int const nstype = NUM2INT(vNstype);
  int ret;

  rb_thread_stop_timer_thread();

  // It takes some time for the thread to be cleaned up
  usleep(1000);

  // Retry several times in case the delay would be insufficient
  for (int i = 0; i < 2; i++) {
    ret = setns(fd, nstype);

    if (ret == 0)
        break;

    usleep(1000);
  }

  rb_thread_start_timer_thread();

  if (ret != 0)
    rb_sys_fail_str(rb_sprintf("setns(%#x, %#x)", fd, nstype));

  return Qnil;
}

/**
 * @overload unshare(flags)
 *
 *   This function provides a workaround for Ruby >=3.3 extra system thread,
 *   which causes the kernel to deny unshare() with EINVAL. It requires patched
 *   Ruby that exports rb_thread_start_timer_thread and rb_thread_stop_timer_thread
 *   functions.
 *
 *   unshare() system call
 *   @param flags [Integer]
 *   @raise [SystemCallError]
 *   @return [nil]
 */
static VALUE osctl_lib_native_unshare(VALUE _self, VALUE vFlags) {
  int const flags = NUM2INT(vFlags);
  int ret;

  rb_thread_stop_timer_thread();

  // It takes some time for the thread to be cleaned up
  usleep(1000);

  // Retry several times in case the delay would be insufficient
  for (int i = 0; i < 2; i++) {
    ret = unshare(flags);

    if (ret == 0)
        break;

    usleep(1000);
  }

  rb_thread_start_timer_thread();

  if (ret != 0)
    rb_sys_fail_str(rb_sprintf("unshare(%#x)", flags));

  return Qnil;
}

void Init_native() {
  VALUE OsCtl = rb_define_module("OsCtl");
  VALUE OsCtlLib = rb_define_module_under(OsCtl, "Lib");
  VALUE OsCtlLibNative = rb_define_module_under(OsCtlLib, "Native");

  rb_define_singleton_method(OsCtlLibNative, "setns", osctl_lib_native_setns, 2);
  rb_define_singleton_method(OsCtlLibNative, "unshare", osctl_lib_native_unshare, 1);
}
