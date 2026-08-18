#!/usr/bin/env python3
"""Integrate the required ReSukiSU SUSFS hooks into a legacy 4.14 tree.

The ReSukiSU inline checker is intentionally strict: on this kernel layout
"inline" still means real source call-sites guarded by CONFIG_KSU_SUSFS.
This helper is fail-closed and never edits the Manager APK.
"""
from pathlib import Path
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "kernel-source")

def once(rel: str, old: str, new: str, label: str) -> None:
    p = ROOT / rel
    if not p.is_file():
        raise SystemExit(f"{label}: required source file missing: {rel}")
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source match in {rel}, found {count}")
    p.write_text(text.replace(old, new, 1))
    print(f"inline hook integrated: {label}")

once("kernel/sys.c", """SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
{
""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_setuid(uid_t new_uid, uid_t old_uid);
#endif

SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
{
""", "setresuid-prototype")

once("kernel/sys.c", """	retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
	if (retval < 0)
		goto error;

	return commit_creds(new);
""", """	retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
	if (retval < 0)
		goto error;

#ifdef CONFIG_KSU_SUSFS
	/* Use the validated transition while current still has zygote credentials. */
	(void)ksu_handle_setuid(new->uid.val, old->uid.val);
#endif
	return commit_creds(new);
""", "setresuid-validated-transition")

# ReSukiSU's stock inline checker only greps the legacy wrapper name. Replace
# that weak check with the direct validated transition this legacy port uses.
once("drivers/kernelsu/tools/inline_hook_check.mk",
     "$(eval $(call check_ksu_hook,ksu_handle_setresuid,$(srctree)/kernel/sys.c))",
     "$(eval $(call check_ksu_hook,ksu_handle_setuid,$(srctree)/kernel/sys.c))",
     "setresuid-inline-checker")

# SUS_MAP needs a live-policy fallback on this legacy task lifecycle. Keep the
# Android app-id classification and isolated-process semantics inside KernelSU.
once("drivers/kernelsu/policy/allowlist.h",
     "bool ksu_uid_should_umount(uid_t uid);\nstruct root_profile *ksu_get_root_profile(uid_t uid);",
     "bool ksu_uid_should_umount(uid_t uid);\nbool ksu_uid_should_hide_sus_map(uid_t uid);\nstruct root_profile *ksu_get_root_profile(uid_t uid);",
     "susmap-policy-declaration")

once("drivers/kernelsu/policy/allowlist.c",
     "\nvoid ksu_put_app_profile(struct app_profile *profile)\n{",
     """
bool ksu_uid_should_hide_sus_map(uid_t uid)
{
    if (!is_appuid(uid) && !is_isolated_process(uid))
        return false;
    if (is_isolated_process(uid))
        return true;
    return ksu_uid_should_umount(uid);
}

void ksu_put_app_profile(struct app_profile *profile)
{""",
     "susmap-policy-implementation")

once("fs/stat.c", """#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;
""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif

#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
""", "stat")

once("fs/exec.c", """int do_execve(struct filename *filename,
	const char __user *const __user *__argv,
	const char __user *const __user *__envp)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif

int do_execve(struct filename *filename,
	const char __user *const __user *__argv,
	const char __user *const __user *__envp)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	int hook_flags = 0;
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_execveat((int[]){ AT_FDCWD }, &filename, &argv, &envp, &hook_flags);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, hook_flags);
}""", "execve")

once("fs/exec.c", """int do_execveat(int fd, struct filename *filename,
		const char __user *const __user *__argv,
		const char __user *const __user *__envp,
		int flags)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };

	return do_execveat_common(fd, filename, argv, envp, flags);
}""", """int do_execveat(int fd, struct filename *filename,
		const char __user *const __user *__argv,
		const char __user *const __user *__envp,
		int flags)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif

	return do_execveat_common(fd, filename, argv, envp, flags);
}""", "execveat-native")

once("fs/exec.c", """static int compat_do_execve(struct filename *filename,
	const compat_uptr_t __user *__argv,
	const compat_uptr_t __user *__envp)
{
	struct user_arg_ptr argv = {
		.is_compat = true,
		.ptr.compat = __argv,
	};
	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}""", """static int compat_do_execve(struct filename *filename,
	const compat_uptr_t __user *__argv,
	const compat_uptr_t __user *__envp)
{
	struct user_arg_ptr argv = {
		.is_compat = true,
		.ptr.compat = __argv,
	};
	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
	int hook_flags = 0;
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_execveat((int[]){ AT_FDCWD }, &filename, &argv, &envp, &hook_flags);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, hook_flags);
}""", "execve-compat")

once("fs/exec.c", """static int compat_do_execveat(int fd, struct filename *filename,
			      const compat_uptr_t __user *__argv,
			      const compat_uptr_t __user *__envp,
			      int flags)
{
	struct user_arg_ptr argv = {
		.is_compat = true,
		.ptr.compat = __argv,
	};
	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
	return do_execveat_common(fd, filename, argv, envp, flags);
}""", """static int compat_do_execveat(int fd, struct filename *filename,
			      const compat_uptr_t __user *__argv,
			      const compat_uptr_t __user *__envp,
			      int flags)
{
	struct user_arg_ptr argv = {
		.is_compat = true,
		.ptr.compat = __argv,
	};
	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif
	return do_execveat_common(fd, filename, argv, envp, flags);
}""", "execveat-compat")

once("fs/open.c", """SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	const struct cred *old_cred;""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif

SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	const struct cred *old_cred;""", "faccessat")

once("fs/read_write.c", """SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
	struct fd f = fdget_pos(fd);""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
				size_t *count_ptr);
#endif

SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_sys_read(fd, &buf, &count);
#endif
	struct fd f = fdget_pos(fd);""", "sys_read")

once("kernel/reboot.c", """SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
				void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
""", "sys_reboot")

once("drivers/input/input.c", """void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;
""", """#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,
				int *value);
#endif

void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_input_handle_event(&type, &code, &value);
#endif
	unsigned long flags;
""", "input_event")

print("all required ReSukiSU SUSFS inline call-sites integrated")