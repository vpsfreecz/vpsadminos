#include <ruby.h>

VALUE OsCtld = Qnil;
VALUE OsCtldNative = Qnil;

void Init_native();

void Init_native() {
	OsCtld = rb_define_module("OsCtld");
	OsCtldNative = rb_define_module_under(OsCtld, "Native");
}
