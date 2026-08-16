#!/usr/bin/env python3
from pathlib import Path

# The composite apply-susfs action runs after `cd kernel-source`, while
# standalone/local checks may run from the repository root. Resolve both
# layouts explicitly so the hook is applied to the source that will compile.
_candidates = [Path("fs/exec.c"), Path("kernel-source/fs/exec.c")]
p = next((candidate for candidate in _candidates if candidate.is_file()), None)
if p is None:
    raise SystemExit("fs/exec.c not found (checked fs/exec.c and kernel-source/fs/exec.c)")
s = p.read_text()

decl = """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                               void *argv, void *envp, int *flags);
#endif
"""
if "extern int ksu_handle_execveat(" not in s:
    anchor = "static int do_execveat_common("
    pos = s.find(anchor)
    if pos < 0:
        raise SystemExit("do_execveat_common anchor not found")
    s = s[:pos] + decl + "\n" + s[pos:]

native_call = """\tint hook_flags = 0;
#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &hook_flags);
#endif
\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, hook_flags);
"""
native_needle = """\tstruct user_arg_ptr envp = { .ptr.native = __envp };
\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
"""
if "ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &hook_flags);" not in s:
    if native_needle not in s:
        raise SystemExit("native do_execve hook anchor not found")
    s = s.replace(native_needle, "\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n" + native_call, 1)

compat_call = """\tint hook_flags = 0;
#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &hook_flags);
#endif
\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, hook_flags);
"""
compat_needle = """\tstruct user_arg_ptr envp = {
\t\t.is_compat = true,
\t\t.ptr.compat = __envp,
\t};
\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
"""
if s.count("ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &hook_flags);") < 2:
    if compat_needle not in s:
        raise SystemExit("compat do_execve hook anchor not found")
    s = s.replace(compat_needle, """\tstruct user_arg_ptr envp = {
\t\t.is_compat = true,
\t\t.ptr.compat = __envp,
\t};
""" + compat_call, 1)

if s.count("ksu_handle_execveat(") < 3:
    raise SystemExit("execve hook insertion incomplete")
p.write_text(s)
print("ReSukiSU exec hook verified:")
for i, line in enumerate(s.splitlines(), 1):
    if "ksu_handle_execveat" in line:
        print(f"{i}: {line}")
