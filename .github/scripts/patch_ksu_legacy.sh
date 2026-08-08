#!/bin/bash
set -e

echo "---------------------------------------"
echo "🔧 Running KernelSU Legacy Patch Script"
echo "---------------------------------------"

# 1. Patch syscall_hook.h untuk KernelSU-Next
HOOK_FILE=$(find . -name "syscall_hook.h" | grep "drivers/kernelsu" | head -n 1)

if [ -n "$HOOK_FILE" ]; then
  echo "🔍 File ditemukan: $HOOK_FILE"
  python3 -c '
import os
path = "'"$HOOK_FILE"'"
if os.path.exists(path):
    with open(path, "r") as f:
        content = f.read()
    if "syscall_fn_t" in content and "syscall_fn_t)" not in content:
        print("🔧 Menerapkan patch syscall_fn_t ke " + path)
        patch = "#include <linux/syscalls.h>\n#include <asm/syscall.h>\n#ifndef syscall_fn_t\nstruct pt_regs;\ntypedef long (*syscall_fn_t)(struct pt_regs *);\n#endif\n"
        with open(path, "w") as f:
            f.write(patch + content)
'
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
python3 -c '
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
'
