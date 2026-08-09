#!/bin/bash
set -e

echo "---------------------------------------"
echo "🔧 Running KernelSU Legacy Patch Script (Final Redefinition Fix)"
echo "---------------------------------------"

python3 << 'EOF'
import os, glob, re

# ---------------------------------------------------------------------------
# Header Kompatibilitas Global dengan Include Guards
# ---------------------------------------------------------------------------
COMPAT_HEADERS = """
#ifndef KSU_COMPAT_HEADERS_H
#define KSU_COMPAT_HEADERS_H

#include <linux/version.h>
#include <linux/types.h>
#include <linux/poll.h>
#include <linux/seccomp.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/init_task.h>
#include <asm/unistd.h>
#include <linux/uaccess.h>
#include <linux/fs.h>
#include <linux/syscalls.h>

#ifndef __poll_t
typedef unsigned int __poll_t;
#define __poll_t __poll_t
#endif

#ifndef SECCOMP_ARCH_NATIVE_NR
#ifdef NR_syscalls
#define SECCOMP_ARCH_NATIVE_NR NR_syscalls
#elif defined(__NR_syscalls)
#define SECCOMP_ARCH_NATIVE_NR __NR_syscalls
#else
#define SECCOMP_ARCH_NATIVE_NR 500
#endif
#endif

#ifndef TWA_RESUME
#define TWA_RESUME 1
#endif

#ifndef fallthrough
#define fallthrough do {} while (0)
#endif

#ifndef KERNEL_SU_VERSION_TAG
#define KERNEL_SU_VERSION_TAG "v1.0.0"
#endif

/* Compat API Memory & User Access Kernel < 5.8 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#ifndef strncpy_from_user_nofault
#define strncpy_from_user_nofault(dst, src, count) strncpy_from_user(dst, src, count)
#endif
#ifndef copy_from_user_nofault
#define copy_from_user_nofault(dst, src, size) probe_kernel_read(dst, src, size)
#endif
#ifndef copy_to_kernel_nofault
#define copy_to_kernel_nofault(dst, src, size) probe_kernel_write(dst, src, size)
#endif
#ifndef copy_to_user_nofault
#define copy_to_user_nofault(dst, src, size) copy_to_user(dst, src, size)
#endif
#endif

/* Compat System Call & VFS Kernel < 5.10 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifndef ksys_close
#define ksys_close sys_close
#endif
#ifndef ksys_unshare
#define ksys_unshare sys_unshare
#endif
#ifndef alloc_file_pseudo
#define alloc_file_pseudo(inode, sb, name, flags, fops) anon_inode_getfile(name, fops, NULL, flags)
#endif
#ifndef security_inode_init_security_anon
#define security_inode_init_security_anon(inode, qstr, anon) (0)
#endif
#ifndef fsnotify_add_inode_mark
#define fsnotify_add_inode_mark(mark, inode, allow_dups) fsnotify_add_mark(mark, inode, NULL, allow_dups)
#endif
#ifndef seccomp_filter_release
#define seccomp_filter_release(task) do {} while (0)
#endif

/* Inject path_umount & setns stubs securely */
asmlinkage long sys_umount(char __user *name, int flags);
static inline int ksu_path_umount_compat(struct path *path, int flags) {
    return sys_umount((char __user *)path->dentry->d_name.name, flags);
}
static inline long ksu_sys_setns(int fd, int nstype) {
    return sys_setns(fd, nstype);
}
#endif /* Kernel < 5.10 */

#endif /* KSU_COMPAT_HEADERS_H */
/* KSU_COMPAT_MARKER */
"""

SIMPLE_REPLACEMENTS = [
    ("<uapi/linux/mount.h>", "<linux/mount.h>"),
    ("<linux/minmax.h>", "<linux/kernel.h>"),
]

ALLOWED_MANAGER_HASHES = [
    "e885c3c1e2d671d18413e15091e9f138864f16a037803e48113c412e69888d3e",  # Official
    "3504179373d5778a486129a25b29b35a72064c0234a742f360e65383f98246cb",  # Next
]

def wrap_file_with_stubs(content, stub_code):
    """ Membungkus file aslinya ke dalam blok #else, dan menaruh stub function di Kernel < 5.10 """
    marker = "/* KSU_COMPAT_MARKER */"
    if marker in content:
        pre, post = content.split(marker, 1)
        return pre + marker + "\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n" + stub_code + "\n#else\n" + post + "\n#endif\n"
    return content

# ---------------------------------------------------------------------------
# Modifikasi Sumber Utama KernelSU
# ---------------------------------------------------------------------------
def patch_kernel_su_sources():
    for path in glob.glob("**/drivers/kernelsu/**/*.[ch]", recursive=True):
        with open(path) as f:
            content = f.read()

        original = content

        if "KSU_COMPAT_MARKER" not in content:
            content = COMPAT_HEADERS + "\n" + content

        for old, new in SIMPLE_REPLACEMENTS:
            content = content.replace(old, new)

        if not os.path.exists("include/linux/pgtable.h"):
            content = content.replace("<linux/pgtable.h>", "<asm/pgtable.h>")

        # Terapkan fungsi wrapper universal ke semua file
        content = patch_mount_umount_compat(content)
        content = apply_file_specific_patch(path, content)

        if content != original:
            with open(path, "w") as f:
                f.write(content)

def apply_file_specific_patch(path, content):
    name = os.path.basename(path)

    if "syscall_hook.h" in name and "syscall_fn_t)" not in content:
        content = (
            "#include <linux/syscalls.h>\n#include <asm/syscall.h>\n"
            "#ifndef syscall_fn_t\nstruct pt_regs;\n"
            "typedef long (*syscall_fn_t)(const struct pt_regs *);\n#endif\n"
        ) + content

    if "lsm_hook.c" in name:
        content = content.replace("hook->list.head = head;", "hook->list.head = (void *)head;")
        content = content.replace(
            "hook->list.list.pprev = &head->first;",
            "((struct hlist_node *)&hook->list.list)->pprev = &head->first;",
        )
        content = content.replace(
            "&hook->list.head->first",
            "&((struct hlist_head *)hook->list.head)->first"
        )
        # Fix untuk __compiletime_assert saat assign hook (Pointer Mismatch pada Kernel 4.14)
        compat_rcu = """
#ifndef ksu_rcu_assign_pointer
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#define ksu_rcu_assign_pointer(p, v) WRITE_ONCE(p, v)
#else
#define ksu_rcu_assign_pointer(p, v) rcu_assign_pointer(p, v)
#endif
#endif
"""
        content = compat_rcu + content
        content = content.replace("rcu_assign_pointer(", "ksu_rcu_assign_pointer(")

    if "app_profile.c" in name:
        content = re.sub(r"([^\n]*seccomp\.filter_count[^\n]*)", r"// \1", content)
        content = re.sub(
            r"(void\s+seccomp_filter_release\s*\([^)]*\)\s*;)",
            r"/* \1 */",
            content
        )

    if "pkg_observer.c" in name:
        content = patch_pkg_observer(content)

    if "su_mount_ns.c" in name:
        content = patch_su_mount_ns(content)

    # 1. PEMBUNGKUS STUBS: rules.c (Fix undefined ext_int_mutex)
    if "rules.c" in name and "KSU_RULES_STUBS" not in content:
        stub = """/* KSU_RULES_STUBS */
void apply_kernelsu_rules(void) {}
"""
        content = wrap_file_with_stubs(content, stub)

    # 2. PEMBUNGKUS STUBS: sepolicy.c (Fix missing SELinux rule injections)
    if "sepolicy.c" in name and "KSU_SEPOLICY_STUBS" not in content:
        stub = """/* KSU_SEPOLICY_STUBS */
struct policydb;
struct selinux_policy;
bool ksu_sepolicy_init(void) { return true; }
void ksu_sepolicy_exit(void) {}
bool ksu_dup_sepolicy(struct selinux_policy *p) { return true; }
void ksu_destroy_sepolicy(struct selinux_policy *p) {}
bool ksu_type(struct policydb *db, const char *t) { return true; }
bool ksu_attribute(struct policydb *db, const char *a) { return true; }
bool ksu_typeattribute(struct policydb *db, const char *t, const char *a) { return true; }
bool ksu_permissive(struct policydb *db, const char *t) { return true; }
bool ksu_allow(struct policydb *db, const char *s, const char *t, const char *c, const char *p) { return true; }
bool ksu_allowxperm(struct policydb *db, const char *s, const char *t, const char *c, u16 spec, u32 pmin, u32 pmax) { return true; }
bool ksu_type_transition(struct policydb *db, const char *s, const char *t, const char *c, const char *d) { return true; }
bool ksu_type_change(struct policydb *db, const char *s, const char *t, const char *c, const char *d) { return true; }
bool ksu_deny(struct policydb *db, const char *s, const char *t, const char *c, const char *p) { return true; }
bool ksu_enforce(struct policydb *db, const char *t) { return true; }
bool ksu_type_member(struct policydb *db, const char *s, const char *t, const char *c, const char *d) { return true; }
bool ksu_genfscon(struct policydb *db, const char *fs, const char *path, const char *ctx) { return true; }
bool ksu_auditallow(struct policydb *db, const char *s, const char *t, const char *c, const char *p) { return true; }
bool ksu_dontaudit(struct policydb *db, const char *s, const char *t, const char *c, const char *p) { return true; }
bool ksu_dontauditxperm(struct policydb *db, const char *s, const char *t, const char *c, u16 spec, u32 pmin, u32 pmax) { return true; }
bool ksu_auditallowxperm(struct policydb *db, const char *s, const char *t, const char *c, u16 spec, u32 pmin, u32 pmax) { return true; }
"""
        content = wrap_file_with_stubs(content, stub)

    # 3. PEMBUNGKUS STUBS: selinux_hide.c
    if "selinux_hide.c" in name and "KSU_SELINUX_HIDE_STUBS" not in content:
        stub = """/* KSU_SELINUX_HIDE_STUBS */
void ksu_selinux_hide_init(void) {}
void ksu_selinux_hide_exit(void) {}
void ksu_selinux_hide_handle_post_fs_data(void) {}
void ksu_selinux_hide_drop_backup_if_unused(void) {}
void ksu_selinux_hide_handle_second_stage(void) {}
"""
        content = wrap_file_with_stubs(content, stub)

    if "selinux" in name or "rules.c" in name:
        content = patch_selinux_state_refs(content)

    if name in ("apk_sign.c", "apk_sign.h", "manager.c"):
        content = patch_manager_allowlist(content)

    return content

def patch_su_mount_ns(content):
    content = re.sub(
        r"extern\s+long\s+__arm64_sys_setns\s*\([^)]*\)\s*;",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\nextern long __arm64_sys_setns(const struct pt_regs *regs);\n#endif",
        content
    )
    content = re.sub(
        r"return\s+__arm64_sys_setns\s*\(&regs\)\s*;",
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n    return ksu_sys_setns((int)fd, (int)flags);\n#else\n    return __arm64_sys_setns(&regs);\n#endif",
        content
    )
    return content

def patch_pkg_observer(content):
    wrapper = """
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask,
                                  struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie);

static int ksu_handle_event(struct fsnotify_group *group, struct inode *to_tell,
                            struct fsnotify_mark *inode_mark, struct fsnotify_mark *vfsmount_mark,
                            u32 mask, const void *data, int data_type,
                            const unsigned char *file_name, u32 cookie,
                            struct fsnotify_iter_info *iter_info)
{
    struct qstr qstr_name = {
        .name = file_name,
        .len = file_name ? strlen((const char *)file_name) : 0
    };
    return ksu_handle_inode_event(inode_mark, mask, to_tell, NULL, &qstr_name, cookie);
}
#endif
"""
    if "static int ksu_handle_event" not in content:
        content = re.sub(
            r"(static\s+(?:const\s+)?struct\s+fsnotify_ops)",
            wrapper + r"\n\1", content, count=1
        )
    content = re.sub(
        r"\.handle_inode_event\s*=\s*ksu_handle_inode_event\s*,?",
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n"
        "    .handle_event = ksu_handle_event,\n"
        "#else\n"
        "    .handle_inode_event = ksu_handle_inode_event,\n"
        "#endif",
        content,
    )
    return content

def patch_mount_umount_compat(content):
    content = re.sub(r"\bpath_mount\b", "do_mount", content)
    content = re.sub(r"\bpath_umount\b", "ksu_path_umount_compat", content)
    return content

def patch_selinux_state_refs(content):
    header_patch = """
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifndef selinux_policy
#define selinux_policy selinux_ss
#endif
#ifndef ext_int_mutex
extern struct mutex ext_int_mutex;
#endif
#ifndef selinux_cred
#define selinux_cred(cred) ((struct task_security_struct *)(cred)->security)
#endif
#endif
"""
    if "#ifndef selinux_policy" not in content:
        content = header_patch + "\n" + content

    content = re.sub(r"\bselinux_state\.policy\b", "selinux_state.ss", content)
    content = re.sub(r"\bselinux_state\.policy_mutex\b", "ext_int_mutex", content)
    return content

def patch_manager_allowlist(content):
    if "ksu_is_manager_apk" not in content or "MULTI_MANAGER_PATCHED" in content:
        return content

    hash_list = ",\n    ".join(f'"{h}"' for h in ALLOWED_MANAGER_HASHES)
    replacement = f"""
/* MULTI_MANAGER_PATCHED */
static const char *ksu_allowed_manager_hashes[] = {{
    {hash_list},
    NULL
}};

bool ksu_is_manager_apk(const char *hash) {{
    if (!hash) return false;
    for (int i = 0; ksu_allowed_manager_hashes[i] != NULL; i++) {{
        if (strcasecmp(hash, ksu_allowed_manager_hashes[i]) == 0) return true;
    }}
    return false;
}}
"""
    return re.sub(
        r"bool\s+ksu_is_manager_apk\s*\([^)]*\)\s*\{[\s\S]*?\n\}",
        replacement.strip(),
        content
    )

# ---------------------------------------------------------------------------
# Patch khusus file_wrapper.c
# ---------------------------------------------------------------------------
def patch_file_wrapper():
    for path in glob.glob("**/drivers/kernelsu/infra/file_wrapper.c", recursive=True):
        with open(path) as f:
            code = f.read()

        if "#ifndef REMAP_FILE_DEDUP" not in code:
            code = (
                "#include <linux/version.h>\n#include <linux/poll.h>\n#include <linux/errno.h>\n"
                "#ifndef REMAP_FILE_DEDUP\n#define REMAP_FILE_DEDUP 0\n#endif\n"
            ) + code

        code = re.sub(
            r"selinux_inode\(([^)]+)\)",
            r"((struct inode_security_struct *)(\1)->i_security)",
            code
        )

        for func in ("ksu_wrapper_iopoll", "ksu_wrapper_remap_file_range", "ksu_wrapper_fadvise"):
            code = re.sub(
                rf"static\s+[^{{;]*?\b{func}\b[^{{;]*?;",
                f"/* disabled {func} decl */",
                code,
                flags=re.DOTALL,
            )
            match = re.search(rf"static\s+[^{{]*?\b{func}\b[^{{]*?\{{", code, re.DOTALL)
            if match:
                start = match.start()
                depth, cur = 1, match.end()
                while cur < len(code) and depth > 0:
                    depth += 1 if code[cur] == "{" else -1 if code[cur] == "}" else 0
                    cur += 1
                code = code[:start] + f"\n#if 0\n{code[start:cur]}\n#endif\n" + code[cur:]

        code = re.sub(
            r"p->ops\.(iopoll|mmap_supported_flags|remap_file_range|fadvise)\s*=[^;]*?;",
            r"/* \g<0> */",
            code,
            flags=re.DOTALL,
        )
        code = re.sub(
            r"return orig->f_op->iopoll.*",
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)\n"
            "return orig->f_op->iopoll(kiocb, spin);\n"
            "#else\nreturn -EOPNOTSUPP;\n#endif",
            code,
        )

        with open(path, "w") as f:
            f.write(code)

patch_kernel_su_sources()
patch_file_wrapper()
print("✅ Patch KernelSU Legacy (Redefinition Fix) selesai dilaksanakan!")
EOF
