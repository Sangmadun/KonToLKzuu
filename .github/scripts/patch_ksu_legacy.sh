#!/bin/bash
set -e

echo "---------------------------------------"
echo "🔧 Running KernelSU Legacy & Multi-Manager Patch Script"
echo "---------------------------------------"

python3 << 'EOF'
import os, glob, re

# 1. Global Header Injections & Replaces
headers = """#include <linux/version.h>
#include <linux/types.h>
#include <linux/poll.h>
#include <linux/seccomp.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/init_task.h>
#include <asm/unistd.h>
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
"""

ksu_files = glob.glob("**/drivers/kernelsu/**/*.[ch]", recursive=True)

for path in ksu_files:
    with open(path, "r") as f:
        content = f.read()
    
    orig_content = content

    # Global Injections
    if "#ifndef __poll_t" not in content:
        content = headers + "\n" + content

    # Replacements untuk Header Legacy Kernel 4.14 / < 5.12
    content = content.replace("<uapi/linux/mount.h>", "<linux/mount.h>")
    content = content.replace("<linux/minmax.h>", "<linux/kernel.h>")
    
    if not os.path.exists("include/linux/pgtable.h"):
        content = content.replace("<linux/pgtable.h>", "<asm/pgtable.h>")

    # Patch File-Spesifik Legacy Kernel
    if "syscall_hook.h" in path and "syscall_fn_t)" not in content:
        patch = "#include <linux/syscalls.h>\n#include <asm/syscall.h>\n#ifndef syscall_fn_t\nstruct pt_regs;\ntypedef long (*syscall_fn_t)(const struct pt_regs *);\n#endif\n"
        content = patch + content

    if "lsm_hook.c" in path:
        content = content.replace("hook->list.head = head;", "hook->list.head = (void *)head;")
        content = content.replace("hook->list.list.pprev = &head->first;", "((struct hlist_node *)&hook->list.list)->pprev = &head->first;")
        content = content.replace("&hook->list.head->first", "&((struct hlist_head *)hook->list.head)->first")

    if "patch_memory" in path:
        content = content.replace("__flush_icache_range", "flush_icache_range")

    if "app_profile.c" in path:
        content = re.sub(r"([^\n]*seccomp\.filter_count[^\n]*)", r"// \1", content)

    if "pkg_observer.c" in path:
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
            content = re.sub(r"(static\s+(?:const\s+)?struct\s+fsnotify_ops)", wrapper + r"\n\1", content, count=1)
        content = re.sub(
            r"\.handle_inode_event\s*=\s*ksu_handle_inode_event\s*,?",
            """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n    .handle_event = ksu_handle_event,\n#else\n    .handle_inode_event = ksu_handle_inode_event,\n#endif""",
            content
        )

    if "selinux" in path:
        header_patch = """#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifndef selinux_policy
#define selinux_policy selinux_ss
#endif
#ifndef ext_int_mutex
extern struct mutex ext_int_mutex;
#endif
#endif
"""
        if "#ifndef selinux_policy" not in content:
            content = header_patch + "\n" + content
        content = re.sub(r"\bselinux_state\.policy\b", "selinux_state.ss", content)
        content = re.sub(r"selinux_state\.policy_mutex", "ext_int_mutex", content)

    if "sepolicy.c" in path and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in content:
        patch_code = """#include <linux/version.h>
#include <linux/types.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
bool ksu_sepolicy_init(void) { return true; }
void ksu_sepolicy_exit(void) {}
#else
"""
        content = patch_code + content + "\n#endif\n"

    # Patch selinux_hide.c untuk Kernel Legacy < 5.10
    if "selinux_hide.c" in path and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in content:
        patch_hide = """#include <linux/version.h>
#include <linux/types.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
// Dummy stub for legacy kernels
void ksu_selinux_hide_init(void) {}
void ksu_selinux_hide_exit(void) {}
#else
"""
        content = patch_hide + content + "\n#endif\n"

    # =========================================================================
    # MULTI-MANAGER PATCH (Support Official, Next, SukiSU, ResuKSU, MKSU, dll)
    # =========================================================================
    if ("apk_sign.c" in path or "apk_sign.h" in path or "manager.c" in path):
        if "ksu_is_manager_apk" in content and "MULTI_MANAGER_PATCHED" not in content:
            multi_hash_check = """
/* MULTI_MANAGER_PATCHED */
static const char *ksu_allowed_manager_hashes[] = {
    "e885c3c1e2d671d18413e15091e9f138864f16a037803e48113c412e69888d3e", // Official
    "3504179373d5778a486129a25b29b35a72064c0234a742f360e65383f98246cb", // Next
    NULL
};

bool ksu_is_manager_apk(const char *hash) {
    if (!hash) return false;
    for (int i = 0; ksu_allowed_manager_hashes[i] != NULL; i++) {
        if (strcasecmp(hash, ksu_allowed_manager_hashes[i]) == 0) return true;
    }
    return false;
}
"""
            content = re.sub(
                r"bool\s+ksu_is_manager_apk\s*\([^)]*\)\s*\{[^}]*\}",
                multi_hash_check,
                content
            )

    # Tulis kembali file jika ada perubahan
    if content != orig_content:
        with open(path, "w") as f:
            f.write(content)

# 2. Patch Khusus file_wrapper.c (VFS iopoll/remap)
for path in glob.glob("**/drivers/kernelsu/infra/file_wrapper.c", recursive=True):
    with open(path, "r") as f:
        code = f.read()

    header_patch = "#include <linux/version.h>\n#include <linux/poll.h>\n#include <linux/errno.h>\n#ifndef REMAP_FILE_DEDUP\n#define REMAP_FILE_DEDUP 0\n#endif\n"
    if "#ifndef REMAP_FILE_DEDUP" not in code:
        code = header_patch + code

    for func in ["ksu_wrapper_iopoll", "ksu_wrapper_remap_file_range", "ksu_wrapper_fadvise"]:
        code = re.sub(r"static\s+[^{;]*?\b" + func + r"\b[^{;]*?;", f"/* disabled {func} decl */", code, flags=re.DOTALL)
        match = re.search(r"static\s+[^{]*?\b" + func + r"\b[^{]*?\{", code, re.DOTALL)
        if match:
            start_pos = match.start()
            brace_pos = match.end() - 1
            depth, cur = 1, brace_pos + 1
            while cur < len(code) and depth > 0:
                if code[cur] == "{": depth += 1
                elif code[cur] == "}": depth -= 1
                cur += 1
            func_code = code[start_pos:cur]
            code = code[:start_pos] + f"\n#if 0\n{func_code}\n#endif\n" + code[cur:]

    code = re.sub(r"p->ops\.(iopoll|mmap_supported_flags|remap_file_range|fadvise)\s*=[^;]*?;", r"/* \g<0> */", code, flags=re.DOTALL)
    code = re.sub(r"return orig->f_op->iopoll.*", "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)\nreturn orig->f_op->iopoll(kiocb, spin);\n#else\nreturn -EOPNOTSUPP;\n#endif", code)

    with open(path, "w") as f:
        f.write(code)

print("✅ Patch KernelSU Legacy & Multi-Manager selesai dilaksanakan!")
EOF
