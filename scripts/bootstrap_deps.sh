#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_DIR="${ROOT_DIR}/.deps"

mkdir -p "${DEPS_DIR}"

clone_or_update() {
  local repo_url="$1"
  local target_dir="$2"
  local ref="$3"

  if [ ! -d "${target_dir}/.git" ]; then
    git clone --filter=blob:none "${repo_url}" "${target_dir}"
  fi

  git -C "${target_dir}" fetch --depth=1 origin "${ref}"
  git -C "${target_dir}" checkout --detach FETCH_HEAD
}

clone_or_update "https://github.com/hrsh7th/nvim-cmp.git" "${DEPS_DIR}/nvim-cmp" "b5311ab3ed9c846b585c0c15b7559be131ec4be9"
clone_or_update "https://github.com/nvim-mini/mini.nvim.git" "${DEPS_DIR}/mini.nvim" "cad365c212fb1e332cb93fa8f72697125799d00a"
