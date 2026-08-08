#!/bin/bash
set -e

echo "---------------------------------------"
echo "🔧 Running KernelSU Legacy Patch Script"
echo "---------------------------------------"

# 0. Global Fix: Injeksi header, typedef __poll_t, & fallback SECCOMP
echo "🔧 Menerapkan injeksi global __poll_t & SECCOMP_ARCH_NATIVE_NR..."
find . -path "*/drivers/kernelsu/*" -type f \( -name "*.h" -o -name "*.c" \) -exec sed -i '1s|^|#include <linux/version.h>\n#include <linux/types.h>\n#include <linux/poll.h>\n#include <linux/seccomp.h>\n#include <asm/unistd.h>\n#ifndef __poll_t\ntypedef unsigned int __poll_t;\n#define __poll_t __poll_t\n#endif\n#ifndef SECCOMP_ARCH_NATIVE_NR\n#ifdef NR_syscalls\n#define SECCOMP_ARCH_NATIVE_NR NR_syscalls\n#elif defined(__NR_syscalls)\n#define SECCOMP_ARCH_NATIVE_NR __NR_syscalls\n#else\n#define SECCOMP_ARCH_NATIVE_NR 500\n#endif\n#endif\n|' {} +

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

# 7. Patch pkg_observer.c (fsnotify_ops -> handle_event untuk Kernel < 5.9)
python3 << 'EOF'
import glob

po_files = glob.glob("**/drivers/kernelsu/manager/pkg_observer.c", recursive=True)
for path in po_files:
    with open(path, "r") as f:
        content = f.read()

    if ".handle_inode_event" in content:
        print("🔧 Menerapkan patch fsnotify_ops pkg_observer 4.14 pada: " + path)
        wrapper = """
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
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
        content = content.replace("static struct fsnotify_ops", wrapper + "\nstatic struct fsnotify_ops")
        content = content.replace(
            ".handle_inode_event = ksu_handle_inode_event,",
            """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n    .handle_event = ksu_handle_event,\n#else\n    .handle_inode_event = ksu_handle_inode_event,\n#endif"""
        )
        with open(path, "w") as f:
            f.write(content)
EOF
