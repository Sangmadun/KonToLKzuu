#!/bin/bash
set -e

echo "---------------------------------------"
echo "🔧 Running KernelSU Legacy Patch Script (Linker & VFS Fix, simplified)"
echo "---------------------------------------"

python3 << 'EOF'
import os, glob, re

# ---------------------------------------------------------------------------
# Compat headers injected once at the top of every touched file
# ---------------------------------------------------------------------------
COMPAT_HEADERS = """#include <linux/version.h>
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

/* Fallback Symbol Compatibilities Kernel 4.14 */
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
#endif

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
#ifndef seccomp_filter_release
#define seccomp_filter_release(task) do {} while (0)
#endif
#ifndef fsnotify_add_inode_mark
#define fsnotify_add_inode_mark(mark, inode, allow_dups) fsnotify_add_mark(mark, inode, NULL, allow_dups)
#endif
#endif
"""

SIMPLE_REPLACEMENTS = [
    ("<uapi/linux/mount.h>", "<linux/mount.h>"),
    ("<linux/minmax.h>", "<linux/kernel.h>"),
]

MOUNT_COMPAT_FILES = ("ksud.c", "sucompat.c", "allowlist.c", "kernel_compat.c")

ALLOWED_MANAGER_HASHES = [
    "e885c3c1e2d671d18413e15091e9f138864f16a037803e48113c412e69888d3e",  # Official
    "3504179373d5778a486129a25b29b35a72064c0234a742f360e65383f98246cb",  # Next
]


def guarded_stub(guard_lt, before):
    """#if LINUX_VERSION_CODE < guard_lt ... #else <original content follows> #endif"""
    pre = (
        f"#include <linux/version.h>\n#include <linux/types.h>\n\n"
        f"#if LINUX_VERSION_CODE < KERNEL_VERSION({guard_lt})\n{before}\n#else\n"
    )
    return pre, "\n#endif\n"


# ---------------------------------------------------------------------------
# Main pass over drivers/kernelsu/**/*.[ch]
# ---------------------------------------------------------------------------
def patch_kernel_su_sources():
    for path in glob.glob("**/drivers/kernelsu/**/*.[ch]", recursive=True):
        with open(path) as f:
            content = f.read()
        original = content

        if "#ifndef __poll_t" not in content:
            content = COMPAT_HEADERS + "\n" + content

        for old, new in SIMPLE_REPLACEMENTS:
            content = content.replace(old, new)
        if not os.path.exists("include/linux/pgtable.h"):
            content = content.replace("<linux/pgtable.h>", "<asm/pgtable.h>")

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
            "&hook->list.head->first", "&((struct hlist_head *)hook->list.head)->first"
        )

    if "patch_memory" in name:
        content = content.replace("__flush_icache_range", "flush_icache_range")
        content = content.replace("__pte_to_phys", "pte_pfn")

    if "app_profile.c" in name:
        content = re.sub(r"([^\n]*seccomp\.filter_count[^\n]*)", r"// \1", content)

    if "pkg_observer.c" in name:
        content = patch_pkg_observer(content)

    if "selinux" in name:
        content = patch_selinux_state_refs(content)

    if "sepolicy.c" in name and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in content:
        pre, post = guarded_stub(
            "5, 10, 0",
            "bool ksu_sepolicy_init(void) { return true; }\nvoid ksu_sepolicy_exit(void) {}",
        )
        content = pre + content + post

    if "selinux_hide.c" in name and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in content:
        pre, post = guarded_stub(
            "5, 10, 0",
            "void ksu_selinux_hide_init(void) {}\n"
            "void ksu_selinux_hide_exit(void) {}\n"
            "void ksu_selinux_hide_handle_post_fs_data(void) {}\n"
            "void ksu_selinux_hide_drop_backup_if_unused(void) {}\n"
            "void ksu_selinux_hide_handle_second_stage(void) {}",
        )
        content = pre + content + post

    if name in MOUNT_COMPAT_FILES:
        content = patch_mount_umount_compat(content)

    if name in ("apk_sign.c", "apk_sign.h", "manager.c"):
        content = patch_manager_allowlist(content)

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
            r"(static\s+(?:const\s+)?struct\s+fsnotify_ops)", wrapper + r"\n\1", content, count=1
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


def patch_selinux_state_refs(content):
    if "#ifndef selinux_policy" not in content:
        content = (
            "#include <linux/version.h>\n"
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
            "#ifndef selinux_policy\n#define selinux_policy selinux_ss\n#endif\n"
            "#ifndef ext_int_mutex\nextern struct mutex ext_int_mutex;\n#endif\n"
            "#endif\n"
        ) + "\n" + content
    content = re.sub(r"\bselinux_state\.policy\b", "selinux_state.ss", content)
    content = re.sub(r"selinux_state\.policy_mutex", "ext_int_mutex", content)
    return content


def patch_mount_umount_compat(content):
    """path_mount/path_umount -> do_mount/compat wrapper for kernels < 5.10."""
    content = re.sub(r"\bpath_mount\b", "do_mount", content)
    content = re.sub(r"\bpath_umount\b", "ksu_path_umount_compat", content)
    if "ksu_path_umount_compat" not in content:
        content = (
            "\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n"
            "static inline int ksu_path_umount_compat(struct path *path, int flags) {\n"
            "    return sys_umount((char __user *)path->dentry->d_name.name, flags);\n"
            "}\n#endif\n"
        ) + content
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
    return re.sub(r"bool\s+ksu_is_manager_apk\s*\([^)]*\)\s*\{[^}]*\}", replacement, content)


# ---------------------------------------------------------------------------
# file_wrapper.c: disable unsupported VFS ops (iopoll/remap/fadvise) + selinux_inode
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

        code = re.sub(r"\bselinux_inode\b", "/* selinux_inode */", code)

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
print("✅ Patch KernelSU Legacy, Linker Fix, & Multi-Manager selesai dilaksanakan!")
EOF
