#!/bin/bash
set -e

echo "---------------------------------------"
echo "🔧 Running KernelSU Legacy Patch Script"
echo "---------------------------------------"

# 0. Global Fix: Injeksi header, typedef __poll_t, SECCOMP, TWA_RESUME, & fallthrough
echo "🔧 Menerapkan injeksi global __poll_t, SECCOMP, TWA_RESUME & fallthrough..."
python3 << 'EOF'
import glob

headers = """#include <linux/version.h>
#include <linux/types.h>
#include <linux/poll.h>
#include <linux/seccomp.h>
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
"""

files = glob.glob("**/drivers/kernelsu/**/*.c", recursive=True) + glob.glob("**/drivers/kernelsu/**/*.h", recursive=True)
for path in files:
    with open(path, "r") as f:
        content = f.read()
    if "#ifndef __poll_t" not in content:
        with open(path, "w") as f:
            f.write(headers + "\n" + content)
EOF

# 0.1 Replace <uapi/linux/mount.h> dengan <linux/mount.h> untuk Kernel Legacy
echo "🔧 Mengganti <uapi/linux/mount.h> -> <linux/mount.h>..."
find . -path "*/drivers/kernelsu/*" -type f \( -name "*.h" -o -name "*.c" \) -exec sed -i 's|<uapi/linux/mount.h>|<linux/mount.h>|g' {} +

# 1. Patch syscall_hook.h untuk KernelSU-Next (dengan const pt_regs)
HOOK_FILE=$(find . -name "syscall_hook.h" | grep "drivers/kernelsu" | head -n 1)

if [ -n "$HOOK_FILE" ]; then
  echo "🔍 File ditemukan: $HOOK_FILE"
  HOOK_FILE="$HOOK_FILE" python3 << 'EOF'
import os
path = os.environ.get("HOOK_FILE", "")
if path and os.path.exists(path):
    with open(path, "r") as f:
        content = f.read()
    if "syscall_fn_t" in content and "syscall_fn_t)" not in content:
        print("🔧 Menerapkan patch syscall_fn_t ke " + path)
        patch = "#include <linux/syscalls.h>\n#include <asm/syscall.h>\n#ifndef syscall_fn_t\nstruct pt_regs;\ntypedef long (*syscall_fn_t)(const struct pt_regs *);\n#endif\n"
        with open(path, "w") as f:
            f.write(patch + content)
EOF
else
  echo "⚠️ File syscall_hook.h tidak ditemukan!"
fi

# 2. Patch linux/pgtable.h -> asm/pgtable.h untuk Kernel Legacy (4.14)
PGTABLE_HEADER=$(find . -maxdepth 4 -path "*/include/linux/pgtable.h" | head -n 1)
if [ -z "$PGTABLE_HEADER" ]; then
  echo "🔧 Kernel legacy (4.14) terdeteksi, mengganti linux/pgtable.h ke asm/pgtable.h..."
  find . -path "*/drivers/kernelsu/*" -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's|<linux/pgtable.h>|<asm/pgtable.h>|g' {} +
fi

# 3. Patch LSM Hook (lsm_hook.c) untuk Kernel Legacy (4.14)
python3 << 'EOF'
import glob

lsm_files = glob.glob("**/drivers/kernelsu/hook/lsm_hook.c", recursive=True)
for path in lsm_files:
    with open(path, "r") as f:
        content = f.read()
    
    modified = False
    if "hook->list.head = head;" in content:
        content = content.replace("hook->list.head = head;", "hook->list.head = (void *)head;")
        modified = True
    if "hook->list.list.pprev = &head->first;" in content:
        content = content.replace(
            "hook->list.list.pprev = &head->first;",
            "((struct hlist_node *)&hook->list.list)->pprev = &head->first;"
        )
        modified = True
    if "&hook->list.head->first" in content:
        content = content.replace(
            "&hook->list.head->first",
            "&((struct hlist_head *)hook->list.head)->first"
        )
        modified = True
        
    if modified:
        print("🔧 Menerapkan patch LSM hook 4.14 pada: " + path)
        with open(path, "w") as f:
            f.write(content)
EOF

# 4. Patch patch_memory.c (__flush_icache_range -> flush_icache_range)
python3 << 'EOF'
import glob

pm_files = glob.glob("**/drivers/kernelsu/hook/arm64/patch_memory.*", recursive=True)
for path in pm_files:
    with open(path, "r") as f:
        content = f.read()
    
    modified = False
    if "__flush_icache_range" in content:
        content = content.replace("__flush_icache_range", "flush_icache_range")
        modified = True
        
    if modified:
        print("🔧 Menerapkan patch flush_icache_range pada: " + path)
        with open(path, "w") as f:
            f.write(content)
EOF

# 5. Patch file_wrapper.c secara presisi untuk Kernel Legacy (4.14 VFS)
python3 << 'EOF'
import glob, re

def wrap_function(code, func_name):
    code = re.sub(r"static\s+[^{;]*?\b" + func_name + r"\b[^{;]*?;", f"/* disabled {func_name} decl */", code, flags=re.DOTALL)
    pattern = r"static\s+[^{]*?\b" + func_name + r"\b[^{]*?\{"
    match = re.search(pattern, code, re.DOTALL)
    if not match:
        return code
    start_pos = match.start()
    brace_pos = match.end() - 1
    depth = 1
    cur = brace_pos + 1
    while cur < len(code) and depth > 0:
        if code[cur] == "{":
            depth += 1
        elif code[cur] == "}":
            depth -= 1
        cur += 1
    end_pos = cur
    func_code = code[start_pos:end_pos]
    wrapped = f"\n#if 0 /* Disabled {func_name} for kernel 4.14 */\n{func_code}\n#endif\n"
    return code[:start_pos] + wrapped + code[end_pos:]

fw_files = glob.glob("**/drivers/kernelsu/infra/file_wrapper.c", recursive=True)
for path in fw_files:
    with open(path, "r") as f:
        content = f.read()

    header_patch = """#include <linux/version.h>
#include <linux/poll.h>
#include <linux/errno.h>
#ifndef REMAP_FILE_DEDUP
#define REMAP_FILE_DEDUP 0
#endif
"""
    content = header_patch + "\n" + content

    for func in ["ksu_wrapper_iopoll", "ksu_wrapper_remap_file_range", "ksu_wrapper_fadvise"]:
        content = wrap_function(content, func)

    content = re.sub(
        r"p->ops\.(iopoll|mmap_supported_flags|remap_file_range|fadvise)\s*=[^;]*?;",
        r"/* \g<0> */",
        content,
        flags=re.DOTALL
    )

    print("🔧 Menerapkan patch VFS file_wrapper 4.14 pada: " + path)
    with open(path, "w") as f:
        f.write(content)
EOF

# 6. Fallback patch iopoll presisi
echo "🔧 Memastikan patch iopoll terpasang dengan rapi..."
find . -path "*/drivers/kernelsu/infra/file_wrapper.c" -exec sed -i 's/return orig->f_op->iopoll.*/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)\nreturn orig->f_op->iopoll(kiocb, spin);\n#else\nreturn -EOPNOTSUPP;\n#endif/g' {} +

# 7. Patch pkg_observer.c secara langsung dan pasti
python3 << 'EOF'
import glob, re

po_files = glob.glob("**/drivers/kernelsu/manager/pkg_observer.c", recursive=True)
for path in po_files:
    with open(path, "r") as f:
        content = f.read()

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

    print("🔧 Menerapkan patch fsnotify_ops pkg_observer 4.14 pada: " + path)
    with open(path, "w") as f:
        f.write(content)
EOF

# 8. Patch app_profile.c (nonaktifkan pengaksesan filter_count di struct seccomp)
python3 << 'EOF'
import glob, re

ap_files = glob.glob("**/drivers/kernelsu/policy/app_profile.c", recursive=True)
for path in ap_files:
    with open(path, "r") as f:
        content = f.read()

    if "seccomp.filter_count" in content:
        print("🔧 Menerapkan patch filter_count app_profile pada: " + path)
        content = re.sub(
            r"([^\n]*seccomp\.filter_count[^\n]*)",
            r"// \1",
            content
        )
        with open(path, "w") as f:
            f.write(content)
EOF

# 9. Patch SELinux rules.c & sepolicy presisi untuk Kernel < 5.10 (4.14)
python3 << 'EOF'
import glob, re

selinux_files = glob.glob("**/drivers/kernelsu/selinux/*.[ch]", recursive=True)
for path in selinux_files:
    with open(path, "r") as f:
        content = f.read()

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

    content = re.sub(
        r"\bselinux_state\.policy\b",
        "selinux_state.ss",
        content
    )

    content = re.sub(
        r"selinux_state\.policy_mutex",
        "ext_int_mutex",
        content
    )

    print("🔧 Menerapkan patch SELinux 4.14 pada: " + path)
    with open(path, "w") as f:
        f.write(content)
EOF

# 10. Patch sepolicy.c (Bungkus fungsi inkompatibel policydb 4.14 dengan #if 0)
python3 << 'EOF'
import glob

sep_files = glob.glob("**/drivers/kernelsu/selinux/sepolicy.c", recursive=True)
for path in sep_files:
    with open(path, "r") as f:
        content = f.read()

    if "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" not in content:
        print("🔧 Menerapkan patch kompatibilitas sepolicy 4.14 pada: " + path)
        
        patch_code = """
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
// Dummy wrappers for legacy 4.14 kernels where 5.10+ policydb layout is not supported directly in-kernel
bool ksu_sepolicy_init(void) { return true; }
void ksu_sepolicy_exit(void) {}
#else
"""
        content = patch_code + content + "\n#endif\n"
        with open(path, "w") as f:
            f.write(content)
EOF
