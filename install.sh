#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACMAN_FILE="$REPO_DIR/packages/packages-pacman.txt"
AUR_FILE="$REPO_DIR/packages/packages-aur.txt"
TEMP_DIR="/tmp/yay-install.$$"

# Passe diese Liste an deine tatsächlichen Stow-Ordner an
STOW_DIRS=(
  btop
  hypr
  kitty
  waybar
  walker
)

info() {
  printf "\n[INFO] %s\n" "$1"
}

warn() {
  printf "\n[WARN] %s\n" "$1"
}

error() {
  printf "\n[ERROR] %s\n" "$1" >&2
}

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    error "Datei nicht gefunden: $file"
    exit 1
  fi
}

read_package_file() {
  local file="$1"
  grep -vE '^\s*#|^\s*$' "$file" || true
}

install_pacman_packages() {
  require_file "$PACMAN_FILE"

  mapfile -t pacman_packages < <(read_package_file "$PACMAN_FILE")

  if [[ ${#pacman_packages[@]} -eq 0 ]]; then
    warn "Keine Pacman-Pakete gefunden."
    return
  fi

  info "Pacman-Datenbank wird synchronisiert ..."
  sudo pacman -Sy

  info "Pacman-Pakete werden installiert ..."
  sudo pacman -S --needed --noconfirm "${pacman_packages[@]}"
}

install_yay() {
  if command -v yay >/dev/null 2>&1; then
    info "yay ist bereits installiert."
    return
  fi

  info "yay nicht gefunden. Installiere benötigte Build-Tools ..."
  sudo pacman -S --needed --noconfirm base-devel

  info "Klonen von yay ..."
  git clone https://aur.archlinux.org/yay.git "$TEMP_DIR/yay"

  info "Baue und installiere yay ..."
  (
    cd "$TEMP_DIR/yay"
    makepkg -si --noconfirm
  )
}

install_aur_packages() {
  require_file "$AUR_FILE"

  mapfile -t aur_packages < <(read_package_file "$AUR_FILE")

  if [[ ${#aur_packages[@]} -eq 0 ]]; then
    warn "Keine AUR-Pakete gefunden."
    return
  fi

  info "AUR-Pakete werden mit yay installiert ..."
  yay -S --needed --noconfirm "${aur_packages[@]}"
}

stow_dotfiles() {
  if ! command -v stow >/dev/null 2>&1; then
    error "stow wurde nicht gefunden. Stelle sicher, dass es in packages-pacman.txt enthalten ist."
    exit 1
  fi

  info "Dotfiles werden mit stow verlinkt ..."

  for dir in "${STOW_DIRS[@]}"; do
    if [[ -d "$REPO_DIR/$dir" ]]; then
      info "Stowe $dir -> \$HOME"
      stow --dir="$REPO_DIR" --target="$HOME" --restow "$dir"
    else
      warn "Stow-Ordner nicht gefunden, überspringe: $dir"
    fi
  done
}

main() {
  info "Starte Installation aus: $REPO_DIR"

  install_pacman_packages
  install_yay
  install_aur_packages
  stow_dotfiles

  info "Fertig."
}

main "$@"