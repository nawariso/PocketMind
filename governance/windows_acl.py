"""Replace Windows state DACLs with operator/SYSTEM/Administrators only."""
import ctypes
from ctypes import wintypes

from .contracts import require


def protect(path):
    adv = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    ptr = ctypes.c_void_p
    adv.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    adv.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ptr, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    adv.ConvertSidToStringSidW.argtypes = [ptr, ctypes.POINTER(ptr)]
    adv.GetNamedSecurityInfoW.argtypes = [wintypes.LPWSTR, ctypes.c_int, wintypes.DWORD, ctypes.POINTER(ptr), ptr, ptr, ptr, ctypes.POINTER(ptr)]
    adv.GetNamedSecurityInfoW.restype = wintypes.DWORD
    adv.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(ptr), ptr]
    adv.SetFileSecurityW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ptr]
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.LocalFree.argtypes = [ptr]; kernel.LocalFree.restype = ptr

    def sid_string(sid):
        out = ptr()
        require(adv.ConvertSidToStringSidW(sid, ctypes.byref(out)), "state_acl_failed")
        try: return ctypes.wstring_at(out)
        finally: kernel.LocalFree(out)

    token = wintypes.HANDLE()
    require(adv.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)), "state_acl_failed")
    try:
        size = wintypes.DWORD()
        adv.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
        buf = ctypes.create_string_buffer(size.value)
        require(adv.GetTokenInformation(token, 1, buf, size.value, ctypes.byref(size)), "state_acl_failed")
        current = sid_string(ctypes.cast(buf, ctypes.POINTER(ptr))[0])
    finally: kernel.CloseHandle(token)
    owner, descriptor = ptr(), ptr()
    result = adv.GetNamedSecurityInfoW(str(path), 1, 1, ctypes.byref(owner), None, None, None, ctypes.byref(descriptor))
    require(result == 0, "state_acl_failed")
    try: require(sid_string(owner) == current, "unsafe_state_owner")
    finally: kernel.LocalFree(descriptor)
    # D:P removes all inherited AND explicit untrusted ACEs rather than merely replacing named grants.
    sddl = f"D:P(A;OICI;FA;;;{current})(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    protected = ptr()
    require(adv.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, ctypes.byref(protected), None), "state_acl_failed")
    try:
        require(adv.SetFileSecurityW(str(path), 0x80000004, protected), "state_acl_failed")
    finally: kernel.LocalFree(protected)
