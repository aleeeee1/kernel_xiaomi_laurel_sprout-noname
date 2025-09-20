#!/usr/bin/env bash
#
# apply_noname_patches.sh -- updated with branch fallback logic
#
set -euo pipefail

# ---------------------------
# Configurable settings
# ---------------------------
: "${WORKSPACE_DIR:=$(pwd)/.patch_workspace}"
: "${PATCHES_URL:=https://github.com/TheSillyOk/kernel_ls_patches}"
: "${PATCHES_BRANCH:=main}"        # preferred branch
: "${PATCHES_FALLBACK_BRANCH:=master}"  # fallback if preferred not found
: "${PATCHES_FOLDER:=noname}"
: "${DEFCONFIG:=vendor/laurel_sprout-perf_defconfig}"
: "${APPLY_PYTHON3_PATCH:=true}"
# (other vars same as before)
: "${KSU_ENABLE:=true}"
: "${KSU_REPO:=KernelSU-Next/KernelSU-Next}"
: "${KSU_BRANCH:=next}"
: "${KSU_KERNEL_PATCHES:=}"
: "${KSU_KSU_PATCHES:=}"
: "${SUSFS_ENABLE:=true}"
: "${SUSFS_BRANCH:=kernel-4.14}"
: "${SUSFS_REPO:=https://gitlab.com/simonpunk/susfs4ksu.git}"
# ---------------------------

KERNEL_ROOT="$(pwd)"
echo "Kernel root: $KERNEL_ROOT"
echo "Workspace: $WORKSPACE_DIR"

mkdir -p "$WORKSPACE_DIR"
PATCHES_DIR="$WORKSPACE_DIR/kernel_patches"

# Clone patches repo with branch fallback logic
if [ -d "$PATCHES_DIR/.git" ]; then
    echo "Patches repo already exists: $PATCHES_DIR"
    cd "$PATCHES_DIR"
    # try to fetch preferred branch, else fallback
    if git ls-remote --heads origin "$PATCHES_BRANCH" | grep -q refs/heads/"$PATCHES_BRANCH"; then
        echo "Updating to branch $PATCHES_BRANCH"
        git fetch --depth=1 origin "$PATCHES_BRANCH"
        git checkout "$PATCHES_BRANCH"
        git reset --hard "origin/$PATCHES_BRANCH"
    elif git ls-remote --heads origin "$PATCHES_FALLBACK_BRANCH" | grep -q refs/heads/"$PATCHES_FALLBACK_BRANCH"; then
        echo "Branch $PATCHES_BRANCH not found; falling back to $PATCHES_FALLBACK_BRANCH"
        git fetch --depth=1 origin "$PATCHES_FALLBACK_BRANCH"
        git checkout "$PATCHES_FALLBACK_BRANCH"
        git reset --hard "origin/$PATCHES_FALLBACK_BRANCH"
    else
        echo "Error: neither branch '$PATCHES_BRANCH' nor '$PATCHES_FALLBACK_BRANCH' found in repo $PATCHES_URL"
        exit 1
    fi
    cd "$KERNEL_ROOT"
else
    echo "Cloning patches repo ($PATCHES_URL)"
    # try preferred branch first
    if git ls-remote --heads "$PATCHES_URL" "$PATCHES_BRANCH" | grep -q refs/heads/"$PATCHES_BRANCH"; then
        git clone --depth=1 --branch "$PATCHES_BRANCH" "$PATCHES_URL" "$PATCHES_DIR"
    elif git ls-remote --heads "$PATCHES_URL" "$PATCHES_FALLBACK_BRANCH" | grep -q refs/heads/"$PATCHES_FALLBACK_BRANCH"; then
        echo "Preferred branch '$PATCHES_BRANCH' not found; cloning fallback branch '$PATCHES_FALLBACK_BRANCH'"
        git clone --depth=1 --branch "$PATCHES_FALLBACK_BRANCH" "$PATCHES_URL" "$PATCHES_DIR"
    else
        echo "Error: neither branch '$PATCHES_BRANCH' nor '$PATCHES_FALLBACK_BRANCH' found in repo $PATCHES_URL"
        exit 1
    fi
fi

# Helper to apply patch if exists
apply_patch_if_exists() {
    local p="$1"
    if [ -f "$PATCHES_DIR/$p" ]; then
        echo "Applying patch: $p"
        patch -p1 -N < "$PATCHES_DIR/$p" || true
    else
        echo "Patch not found (skipping): $p"
    fi
}

# Now rest of patching as before:

if [ "$APPLY_PYTHON3_PATCH" = "true" ] || [ "$APPLY_PYTHON3_PATCH" = "True" ]; then
    apply_patch_if_exists "python3.patch"
fi

for p in fix_lto.patch ptrace_fix.patch; do
    apply_patch_if_exists "$p"
done

if [ -f scripts/setlocalversion ]; then
    echo "Patching scripts/setlocalversion (remove -dirty)"
    sed -i 's/-dirty//' scripts/setlocalversion || true
else
    echo "Warning: scripts/setlocalversion not found; skipping that edit."
fi

DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"
if [ -f "$DEFCONFIG_PATH" ]; then
    echo "Patching defconfig: $DEFCONFIG_PATH"

    # append "-Ok" to localversion
    if grep -q '^CONFIG_LOCALVERSION=' "$DEFCONFIG_PATH"; then
        sed -i -E 's/^(CONFIG_LOCALVERSION="?.*"?)/\1-Ok/gi' "$DEFCONFIG_PATH" || true
    else
        echo 'CONFIG_LOCALVERSION="-Ok"' >> "$DEFCONFIG_PATH"
    fi

    sed -i -E 's/^CONFIG_(LTO[^=]*|HAVE_LTO[^=]*|CC_OPTIMIZE_FOR[^=]*|MODVERSIONS)=(y|n)/# CONFIG_\1=\2/g' "$DEFCONFIG_PATH" || true

    cat >> "$DEFCONFIG_PATH" <<'EOF'

# Workflow added configs #
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
CONFIG_HAVE_LTO_CLANG=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_MODVERSIONS=n
EOF

else
    echo "Warning: defconfig file not found at $DEFCONFIG_PATH — skipping defconfig edits."
fi

# The rest (KernelSU, SUSFS) unchanged ...

echo "Done. Source modifications applied."
