#!/usr/bin/env python3
"""Idempotently add the ReSukiSU manual hooks to this exact 4.14 tree."""
from pathlib import Path

ROOT = Path(".")

def edit(rel: str, replacements: list[tuple[str, str]], required: list[str]) -> None:
    p = ROOT / rel
    s = p.read_text()
    for old, new in replacements:
        if new in s:
            continue
        if old not in s:
            raise SystemExit(f"{rel}: hook anchor missing: {old[:100]!r}")
        s = s.replace(old, new, 1)
    for marker in required:
        if marker not in s:
            raise SystemExit(f"{rel}: required hook missing after patch: {marker}")
    p.write_text(s)

# ReSukiSU's 4.14 manual integration contract. These are real call sites,
# not validator bypasses. Keep each call guarded so CONFIG_KSU=n remains valid.
edit("fs/open.c", [
    ("#include \"internal.h\"\n", "#include \"internal.h\"\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n"),
    ("SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n", "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n"),
], ["ksu_handle_faccessat(&dfd, &filename, &mode, NULL);"])

edit("fs/read_write.c", [
    ("SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n", "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_read(fd, &buf, &count);\n#endif\n"),
    ("#include <linux/syscalls.h>\n", "#include <linux/syscalls.h>\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n"),
], ["ksu_handle_sys_read(fd, &buf, &count);"])

edit("fs/stat.c", [
    ("#include <asm/unistd.h>\n", "#include <asm/unistd.h>\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\nextern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);\n#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)\nextern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);\n#endif\n#endif\n"),
    ("SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n\t\tstruct stat __user *, statbuf, int, flag)\n{\n", "SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n\t\tstruct stat __user *, statbuf, int, flag)\n{\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n"),
    ("SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)\n{\n", "SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)\n{\n"),
    ("\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat", "\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat"),
    ("SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)\n{\n", "SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)\n{\n"),
    ("\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64", "\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64"),
], ["ksu_handle_stat(&dfd, &filename, &flag);", "ksu_handle_newfstat_ret(&fd, &statbuf)", "ksu_handle_fstat64_ret(&fd, &statbuf)"])

edit("kernel/reboot.c", [
    ("static DEFINE_MUTEX(reboot_mutex);\n", "static DEFINE_MUTEX(reboot_mutex);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n"),
    ("\tint ret = 0;\n\n\t/* We only trust the superuser", "\tint ret = 0;\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\n\t/* We only trust the superuser"),
], ["ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);"])

edit("drivers/input/input.c", [
    ("static void input_handle_event(struct input_dev *dev,\n", "#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif\n\nstatic void input_handle_event(struct input_dev *dev,\n"),
    ("\tint disposition = input_get_disposition(dev, type, code, &value);\n", "\tint disposition = input_get_disposition(dev, type, code, &value);\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n"),
], ["ksu_handle_input_handle_event(&type, &code, &value);"])

print("ReSukiSU manual hooks verified: faccessat, read, stat/newfstat, fstat64, reboot, input")
