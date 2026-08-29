#!/bin/sh

acquire_macos_build_lock() {
    macos_build_lock_dir="$1/macos-build.lock"
    if ! mkdir -p "$1"; then
        printf 'MACOS_BUILD_BLOCKED build_root_unavailable path=%s\n' "$1" >&2
        return 2
    fi
    if ! mkdir "$macos_build_lock_dir" 2>/dev/null; then
        printf 'MACOS_BUILD_BLOCKED concurrent_build lock=%s\n' \
            "$macos_build_lock_dir" >&2
        return 2
    fi
    printf '%s\n' "$$" >"$macos_build_lock_dir/owner-pid"
    trap release_macos_build_lock EXIT INT TERM
}

release_macos_build_lock() {
    if [ -n "${macos_build_lock_dir:-}" ]; then
        unlink "$macos_build_lock_dir/owner-pid" 2>/dev/null || true
        rmdir "$macos_build_lock_dir" 2>/dev/null || true
        macos_build_lock_dir=
    fi
}
