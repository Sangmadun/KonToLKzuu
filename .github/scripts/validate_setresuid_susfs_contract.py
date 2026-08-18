#!/usr/bin/env python3
"""Fail-closed semantic gate for legacy 4.14 ReSukiSU setresuid integration."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
sys_c = (root / 'kernel/sys.c').read_text()
handler = (root / 'drivers/kernelsu/hook/setuid_hook.c').read_text()
umount = (root / 'drivers/kernelsu/feature/kernel_umount.c').read_text()
allowlist = (root / 'drivers/kernelsu/policy/allowlist.c').read_text()
susfs_def = (root / 'include/linux/susfs_def.h').read_text()

def body_after_anchor(text: str, anchor: str) -> str:
    start = text.find(anchor)
    if start < 0:
        raise SystemExit(f'missing anchor: {anchor}')
    brace = text.find('{', start)
    if brace < 0:
        raise SystemExit(f'missing body: {anchor}')
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: return text[brace + 1:i]
    raise SystemExit(f'unbalanced body: {anchor}')

body = body_after_anchor(sys_c, 'SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)')
norm = re.sub(r'\s+', '', body)
call = 'ksu_handle_setuid(new->uid.val,old->uid.val);'
if norm.count(call) != 1:
    raise SystemExit('setresuid must call validated ksu_handle_setuid(new->uid, old->uid) exactly once')
if 'ksu_handle_setresuid(' in body:
    raise SystemExit('raw syscall-entry ksu_handle_setresuid wrapper is forbidden')
lsm_pos = norm.find('retval=security_task_fix_setuid(new,old,LSM_SETID_RES);')
positions = {
    'old': norm.find('old=current_cred();'),
    'lsm': lsm_pos,
    'reject': norm.find('if(retval<0)gotoerror;', lsm_pos),
    'hook': norm.find(call),
    'commit': norm.find('returncommit_creds(new);'),
    'error': norm.find('error:'),
}
if any(v < 0 for v in positions.values()):
    raise SystemExit(f'missing setresuid contract token: {positions}')
if not (positions['old'] < positions['lsm'] < positions['reject'] < positions['hook'] < positions['commit'] < positions['error']):
    raise SystemExit(f'wrong setresuid hook ordering: {positions}')
# Local guard must surround only the direct hook seam.
guarded = re.search(r'#ifdef\s+CONFIG_KSU_SUSFS\s+extern\s+int\s+ksu_handle_setuid\s*\(uid_t\s+new_uid,\s*uid_t\s+old_uid\s*\);\s+#endif', sys_c, re.S)
if not guarded:
    raise SystemExit('guarded ksu_handle_setuid prototype missing')
if '#ifdef CONFIG_KSU_SUSFS' not in body[:body.find('ksu_handle_setuid')].rsplit('\n', 3)[0:3]:
    # Robust normalized local check below; list condition only supplies readable failure.
    local = re.search(r'#ifdef\s+CONFIG_KSU_SUSFS\s+/\*.*?\*/\s*\(void\)ksu_handle_setuid\s*\(\s*new->uid\.val\s*,\s*old->uid\.val\s*\)\s*;\s*#endif', body, re.S)
    if not local:
        raise SystemExit('direct setuid hook is not locally CONFIG_KSU_SUSFS guarded')
# Preserve upstream policy invariants.
required_handler = [
    'int ksu_handle_setuid(uid_t new_uid, uid_t old_uid)',
    'if (!is_zygote(current_cred()))',
    'if (ksu_is_allow_uid_for_current(new_uid))',
    'ksu_handle_umount(old_uid, new_uid);',
]
for token in required_handler:
    if token not in handler: raise SystemExit(f'handler invariant missing: {token}')
for token in ['if (!is_appuid(new_uid) && !is_isolated_process(new_uid))',
              'if (!ksu_uid_should_umount(new_uid) && !is_isolated_process(new_uid))',
              'susfs_set_current_proc_umounted();']:
    if token not in umount: raise SystemExit(f'umount invariant missing: {token}')
# The policy fallback must retain every exclusion/override that makes it safe:
# Manager false, WebView zygote false, root-allowed false, explicit/default
# non-root policy respected under RCU, and profile references released.
for token in ['if (unlikely(ksu_is_manager_uid(uid)))',
              'if (unlikely(uid == WEBVIEW_ZYGOTE_UID))',
              'res = default_non_root_profile.umount_modules;',
              'else if (profile->allow_su)',
              'res = false;',
              'if (profile->nrp_config.use_default)',
              'res = profile->nrp_config.profile.umount_modules;',
              'rcu_read_lock();', 'rcu_read_unlock();',
              'ksu_put_app_profile(profile);']:
    if token not in allowlist: raise SystemExit(f'policy fallback invariant missing: {token}')
for token in ['bool ksu_uid_should_hide_sus_map(uid_t uid)',
              'if (!is_appuid(uid) && !is_isolated_process(uid))',
              'if (is_isolated_process(uid))',
              'return ksu_uid_should_umount(uid);']:
    if token not in allowlist: raise SystemExit(f'SUS_MAP policy helper invariant missing: {token}')
for token in ['static inline bool susfs_is_current_proc_umounted_app_for_sus_map(void)',
              'return ksu_uid_should_hide_sus_map(current_uid().val);',
              'susfs_is_current_proc_umounted_app_for_sus_map()']:
    if token not in susfs_def: raise SystemExit(f'SUSFS predicate invariant missing: {token}')
# Scope guard: one definition plus one SUS_MAP macro call, nowhere else.
if susfs_def.count('susfs_is_current_proc_umounted_app_for_sus_map') != 2:
    raise SystemExit('SUS_MAP policy fallback escaped its single macro call-site')
print('SETRESUID_SUSFS_CONTRACT_OK')
