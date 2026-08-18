#!/usr/bin/env python3
"""Port SUSFS SUS_MAP into the exact Flyme Linux 4.14 procfs layout.

Fail closed: every insertion targets one exact pristine-vendor block. The port
preserves seq iterator state and pagemap positional semantics; it never imports
a foreign task_mmu.c implementation.
"""
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "kernel-source")
p = root / "fs/proc/task_mmu.c"
if not p.is_file():
    raise SystemExit(f"missing Flyme task_mmu.c: {p}")
s = p.read_text()

# Exact output produced from Flyme source commit
# 56fa4c938c73d721341bba905790a46259192c60. This closes the idempotent
# path against partial ports that happen to retain a few marker tokens.
EXPECTED_APPLIED_SHA256 = "40651c75e81f9ba5ebc8c4bbcadb83ec5cdc19bf9094324508f14110d9ebe558"

EXPECTED = {
    "header": "#include <linux/susfs_def.h> /* SUSMAP_414_PORT_V2 */",
    "maps": "if (SUSFS_IS_INODE_SUS_MAP(inode))\n\t\t\treturn;",
    "smaps": "m_cache_vma(m, vma);\n\t\treturn 0; /* hidden but iterator cache stays coherent */",
    "rollup": "unsigned long first_visible_start = 0, last_visible_end = 0;",
    "pagemap": "pm.buffer[susmap_idx].pme = 0;",
}

if "SUSMAP_414_PORT_V2" in s:
    digest = hashlib.sha256(s.encode()).hexdigest()
    if digest != EXPECTED_APPLIED_SHA256:
        raise SystemExit(f"partial/corrupt SUS_MAP V2 port: sha256={digest}")
    print("complete SUS_MAP 4.14 V2 port already applied")
    raise SystemExit(0)
if "SUSMAP_414_PORT_V1" in s:
    raise SystemExit("obsolete/partial SUS_MAP V1 port present; refusing mixed port")

def once(old: str, new: str, label: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{label}: expected exactly one Flyme pattern, found {n}")
    s = s.replace(old, new, 1)
    print(f"SUS_MAP integrated: {label}")

once(
    "#include <linux/mm_inline.h>\n\n#include <asm/elf.h>",
    "#include <linux/mm_inline.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h> /* SUSMAP_414_PORT_V2 */\n#endif\n\n#include <asm/elf.h>",
    "susfs header",
)

# maps: suppress the line inside show_map_vma(), but let show_map() run
# m_cache_vma() so seq_file restart bookkeeping remains intact.
once(
    "\tif (file) {\n\t\tstruct inode *inode = file_inode(vma->vm_file);\n\t\tdev = inode->i_sb->s_dev;",
    "\tif (file) {\n\t\tstruct inode *inode = file_inode(vma->vm_file);\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tif (SUSFS_IS_INODE_SUS_MAP(inode))\n\t\t\treturn;\n#endif\n\t\tdev = inode->i_sb->s_dev;",
    "maps",
)

# smaps: no stats/output for a hidden VMA, but preserve iterator cache.
once(
    "static int show_smap(struct seq_file *m, void *v)\n{\n\tstruct vm_area_struct *vma = v;\n\tstruct mem_size_stats mss;\n\n\tmemset(&mss, 0, sizeof(mss));",
    "static int show_smap(struct seq_file *m, void *v)\n{\n\tstruct vm_area_struct *vma = v;\n\tstruct mem_size_stats mss;\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file &&\n\t    SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))) {\n\t\tm_cache_vma(m, vma);\n\t\treturn 0; /* hidden but iterator cache stays coherent */\n\t}\n#endif\n\tmemset(&mss, 0, sizeof(mss));",
    "smaps",
)

# smaps_rollup: retain last_vma_end for lock-drop iteration recovery, while
# exposing only first/last visible boundaries and visible statistics.
once(
    "\tunsigned long last_vma_end = 0;\n\tint ret = 0;",
    "\tunsigned long last_vma_end = 0;\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tunsigned long first_visible_start = 0, last_visible_end = 0;\n\tbool have_visible_vma = false;\n#endif\n\tint ret = 0;",
    "smaps_rollup declaration",
)
once(
    "\tfor (vma = priv->mm->mmap; vma;) {\n\t\tsmap_gather_stats(vma, &mss);\n\t\tlast_vma_end = vma->vm_end;",
    "\tfor (vma = priv->mm->mmap; vma;) {\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tif (!(vma->vm_file &&\n\t\t      SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))) {\n\t\t\tif (!have_visible_vma)\n\t\t\t\tfirst_visible_start = vma->vm_start;\n\t\t\thave_visible_vma = true;\n\t\t\tlast_visible_end = vma->vm_end;\n\t\t\tsmap_gather_stats(vma, &mss);\n\t\t}\n#else\n\t\tsmap_gather_stats(vma, &mss);\n#endif\n\t\tlast_vma_end = vma->vm_end;",
    "smaps_rollup gather",
)
once(
    "\tshow_vma_header_prefix(m, priv->mm->mmap->vm_start,\n\t\t\t       last_vma_end, 0, 0, 0, 0);",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tshow_vma_header_prefix(m, have_visible_vma ? first_visible_start : 0,\n\t\t\t       have_visible_vma ? last_visible_end : 0, 0, 0, 0, 0);\n#else\n\tshow_vma_header_prefix(m, priv->mm->mmap->vm_start,\n\t\t\t       last_vma_end, 0, 0, 0, 0);\n#endif",
    "smaps_rollup header",
)

# pagemap: walk normally to preserve one entry per virtual page and correct
# ppos semantics, then zero entries whose individual page belongs to SUS_MAP.
once(
    "\tint ret = 0, copied = 0;\n\n\tif (!mm || !mmget_not_zero(mm))",
    "\tint ret = 0, copied = 0;\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *susmap_vma;\n\tunsigned long susmap_addr;\n\tint susmap_idx;\n#endif\n\n\tif (!mm || !mmget_not_zero(mm))",
    "pagemap declaration",
)
once(
    "\t\tdown_read(&mm->mmap_sem);\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n\t\tup_read(&mm->mmap_sem);",
    "\t\tdown_read(&mm->mmap_sem);\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tfor (susmap_idx = 0; susmap_idx < pm.pos; susmap_idx++) {\n\t\t\tsusmap_addr = start_vaddr +\n\t\t\t\t((unsigned long)susmap_idx << PAGE_SHIFT);\n\t\t\tsusmap_vma = find_vma(mm, susmap_addr);\n\t\t\tif (susmap_vma && susmap_addr >= susmap_vma->vm_start &&\n\t\t\t    susmap_vma->vm_file &&\n\t\t\t    SUSFS_IS_INODE_SUS_MAP(file_inode(susmap_vma->vm_file)))\n\t\t\t\tpm.buffer[susmap_idx].pme = 0;\n\t\t}\n#endif\n\t\tup_read(&mm->mmap_sem);",
    "pagemap",
)

missing = [name for name, block in EXPECTED.items() if block not in s]
count = s.count("SUSFS_IS_INODE_SUS_MAP")
if missing or count != 4:
    raise SystemExit(f"generated port failed self-check: missing={missing}, hook_count={count}")
digest = hashlib.sha256(s.encode()).hexdigest()
if digest != EXPECTED_APPLIED_SHA256:
    raise SystemExit(f"generated port digest mismatch: sha256={digest}")
p.write_text(s)
print("all required Flyme 4.14 SUS_MAP V2 procfs hooks integrated")
