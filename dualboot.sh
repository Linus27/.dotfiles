#!/usr/bin/env bash
set -Eeuo pipefail

# Arch Recovery Bootstrap (systemd-boot + Windows on second SSD)
# Version 0.3

SCRIPT_NAME="$(basename "$0")"
WORKDIR="${WORKDIR:-/tmp/arch-recovery}"
LOG_FILE="$WORKDIR/recovery.log"
WINDOWS_EFI_MOUNT="$WORKDIR/win-efi"
BACKUP_DIR="$WORKDIR/backup"

BOOT_MOUNT="/boot"
ENTRIES_DIR="$BOOT_MOUNT/loader/entries"
LOADER_CONF="$BOOT_MOUNT/loader/loader.conf"

ARCH_ENTRY="$ENTRIES_DIR/arch.conf"
ARCH_FALLBACK_ENTRY="$ENTRIES_DIR/arch-fallback.conf"
WINDOWS_ENTRY="$ENTRIES_DIR/windows.conf"

DEFAULT_TIMEOUT="60"
DEFAULT_ENTRY="arch.conf"
EDITOR_SETTING="no"

KERNEL_PRESET="linux"
KERNEL_IMAGE=""
INITRAMFS_IMAGE=""
FALLBACK_INITRAMFS_IMAGE=""

DRY_RUN=0

mkdir -p "$WORKDIR" "$WINDOWS_EFI_MOUNT" "$BACKUP_DIR"
touch "$LOG_FILE"

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" | tee -a "$LOG_FILE" >&2
}

info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; }

die() {
  error "$*"
  exit 1
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRYRUN] ' >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

cleanup() {
  if mountpoint -q "$WINDOWS_EFI_MOUNT"; then
    umount "$WINDOWS_EFI_MOUNT" || true
  fi
}
trap cleanup EXIT

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Bitte als root ausführen."
}

require_uefi() {
  [[ -d /sys/firmware/efi ]] || die "Kein UEFI-System erkannt. systemd-boot braucht UEFI."
}

require_cmds() {
  local missing=()
  local cmds=(lsblk blkid findmnt mount umount cp bootctl awk sed grep find basename head)

  for cmd in "${cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if (( ${#missing[@]} > 0 )); then
    die "Fehlende Befehle: ${missing[*]}"
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    warn "rsync nicht gefunden – EFI-Import fällt auf cp zurück."
  fi
}

confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N]: " reply || true
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

backup_file() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  local target="$BACKUP_DIR$(dirname "$file")"
  mkdir -p "$target"
  cp -a "$file" "$target/"
  info "Backup erstellt: $file -> $target/"
}

get_boot_mount_source() {
  findmnt -no SOURCE "$BOOT_MOUNT" 2>/dev/null || true
}

get_boot_mount() {
  local source
  source="$(get_boot_mount_source)"
  [[ -n "$source" ]] || die "$BOOT_MOUNT ist nicht gemountet. Bitte zuerst die aktive Arch-EFI auf $BOOT_MOUNT mounten."
  info "Aktive Boot/EFI-Mountquelle: $source -> $BOOT_MOUNT"
}

ensure_systemd_boot_present() {
  [[ -d "$BOOT_MOUNT/loader" ]] || warn "Kein loader-Verzeichnis auf $BOOT_MOUNT gefunden."

  if bootctl --path="$BOOT_MOUNT" status >/dev/null 2>&1; then
    info "systemd-boot Status erfolgreich gelesen."
  else
    warn "bootctl status liefert keinen sauberen Status. Wir schreiben die Konfiguration trotzdem vorbereitend."
  fi
}

set_kernel_paths() {
  case "$KERNEL_PRESET" in
    linux)
      KERNEL_IMAGE="/vmlinuz-linux"
      INITRAMFS_IMAGE="/initramfs-linux.img"
      FALLBACK_INITRAMFS_IMAGE="/initramfs-linux-fallback.img"
      ;;
    linux-zen)
      KERNEL_IMAGE="/vmlinuz-linux-zen"
      INITRAMFS_IMAGE="/initramfs-linux-zen.img"
      FALLBACK_INITRAMFS_IMAGE="/initramfs-linux-zen-fallback.img"
      ;;
    linux-lts)
      KERNEL_IMAGE="/vmlinuz-linux-lts"
      INITRAMFS_IMAGE="/initramfs-linux-lts.img"
      FALLBACK_INITRAMFS_IMAGE="/initramfs-linux-lts-fallback.img"
      ;;
    *)
      die "Unbekanntes Kernel-Preset: $KERNEL_PRESET"
      ;;
  esac
}

detect_cpu_microcode() {
  if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
    echo "/amd-ucode.img"
    return
  fi

  if grep -qi 'GenuineIntel' /proc/cpuinfo; then
    echo "/intel-ucode.img"
    return
  fi

  echo ""
}

get_root_source() {
  findmnt -no SOURCE /
}

get_root_fstype() {
  findmnt -no FSTYPE /
}

get_root_device() {
  local root_source
  root_source="$(get_root_source)"
  [[ -n "$root_source" ]] || die "Konnte Root-Quelle nicht ermitteln."
  printf '%s' "${root_source%%\[*}"
}

get_root_uuid() {
  local root_source root_dev root_uuid
  root_source="$(get_root_source)"
  [[ -n "$root_source" ]] || die "Konnte Root-Quelle nicht ermitteln."

  root_dev="$(get_root_device)"
  [[ -b "$root_dev" ]] || die "Root-Blockdevice ungültig: $root_dev (aus $root_source)"

  root_uuid="$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)"
  [[ -n "$root_uuid" ]] || die "Konnte Root-UUID nicht ermitteln für $root_dev (Quelle: $root_source)"
  printf '%s' "$root_uuid"
}

get_btrfs_subvol() {
  local root_source subvol
  root_source="$(get_root_source)"

  if [[ "$root_source" =~ \[(.*)\]$ ]]; then
    subvol="${BASH_REMATCH[1]}"
    subvol="${subvol#/}"
    printf '%s' "$subvol"
    return
  fi

  printf ''
}

build_root_options() {
  local root_uuid="$1"
  local root_fstype subvol
  root_fstype="$(get_root_fstype)"
  subvol="$(get_btrfs_subvol)"

  if [[ "$root_fstype" == "btrfs" && -n "$subvol" ]]; then
    printf 'root=UUID=%s rw rootflags=subvol=%s' "$root_uuid" "$subvol"
  else
    printf 'root=UUID=%s rw' "$root_uuid"
  fi
}

detect_uki() {
  compgen -G "$BOOT_MOUNT/EFI/Linux/*.efi" >/dev/null 2>&1
}

get_uki_basename() {
  local uki
  uki="$(find "$BOOT_MOUNT/EFI/Linux" -maxdepth 1 -type f -name '*.efi' 2>/dev/null | head -n1)"
  [[ -n "$uki" ]] || return 1
  basename "$uki"
}

find_windows_efi_candidates() {
  local dev fstype boot_source
  boot_source="$(get_boot_mount_source)"

  while read -r dev fstype; do
    [[ -n "$dev" ]] || continue
    [[ "$fstype" == "vfat" ]] || continue

    if [[ "$dev" == "$boot_source" ]]; then
      continue
    fi

    if mountpoint -q "$WINDOWS_EFI_MOUNT"; then
      umount "$WINDOWS_EFI_MOUNT" || true
    fi

    if mount "$dev" "$WINDOWS_EFI_MOUNT" 2>/dev/null; then
      if [[ -f "$WINDOWS_EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        echo "$dev"
      fi
      umount "$WINDOWS_EFI_MOUNT" || true
    fi
  done < <(lsblk -rpo NAME,FSTYPE)
}

choose_windows_efi() {
  mapfile -t candidates < <(find_windows_efi_candidates)

  if (( ${#candidates[@]} == 0 )); then
    die "Keine Windows-EFI mit EFI/Microsoft/Boot/bootmgfw.efi gefunden."
  fi

  if (( ${#candidates[@]} == 1 )); then
    printf '%s' "${candidates[0]}"
    return
  fi

  info "Mehrere Windows-EFI-Kandidaten gefunden:"
  local i=1
  for dev in "${candidates[@]}"; do
    echo "  [$i] $dev"
    ((i++))
  done

  local selection
  read -r -p "Bitte Nummer der Windows-EFI wählen: " selection
  [[ "$selection" =~ ^[0-9]+$ ]] || die "Ungültige Auswahl."
  (( selection >= 1 && selection <= ${#candidates[@]} )) || die "Auswahl außerhalb des Bereichs."

  printf '%s' "${candidates[$((selection-1))]}"
}

mount_windows_efi() {
  local dev="$1"
  mkdir -p "$WINDOWS_EFI_MOUNT"

  run mount "$dev" "$WINDOWS_EFI_MOUNT"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[DRYRUN] würde prüfen: $WINDOWS_EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi"
    return 0
  fi

  [[ -f "$WINDOWS_EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] || \
    die "Windows-Bootdatei auf $dev nicht gefunden."

  info "Windows-EFI gemountet: $dev -> $WINDOWS_EFI_MOUNT"
}

import_windows_efi() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[DRYRUN] würde importieren: $WINDOWS_EFI_MOUNT/EFI/Microsoft -> $BOOT_MOUNT/EFI/Microsoft"
    if [[ -d "$BOOT_MOUNT/EFI/Microsoft" ]]; then
      warn "[DRYRUN] Microsoft EFI existiert bereits auf Haupt-EFI: $BOOT_MOUNT/EFI/Microsoft"
    fi

    if command -v rsync >/dev/null 2>&1; then
      info "[DRYRUN] würde rsync nutzen"
      run rsync -a "$WINDOWS_EFI_MOUNT/EFI/Microsoft/" "$BOOT_MOUNT/EFI/Microsoft/"
    else
      warn "[DRYRUN] rsync nicht gefunden – würde cp fallback nutzen"
      run cp -r "$WINDOWS_EFI_MOUNT/EFI/Microsoft" "$BOOT_MOUNT/EFI/"
    fi
    return 0
  fi

  [[ -d "$WINDOWS_EFI_MOUNT/EFI/Microsoft" ]] || die "Microsoft EFI-Verzeichnis fehlt auf gemounteter Windows-EFI."
  mkdir -p "$BOOT_MOUNT/EFI"

  if [[ -d "$BOOT_MOUNT/EFI/Microsoft" ]]; then
    warn "Microsoft EFI existiert bereits auf Haupt-EFI: $BOOT_MOUNT/EFI/Microsoft"
    if ! confirm "Vorhandene Microsoft EFI mit Windows-EFI zusammenführen?"; then
      warn "Import der Windows-EFI übersprungen."
      return 0
    fi
  fi

  if command -v rsync >/dev/null 2>&1; then
    info "Nutze rsync für EFI-Import"
    run rsync -a "$WINDOWS_EFI_MOUNT/EFI/Microsoft/" "$BOOT_MOUNT/EFI/Microsoft/"
  else
    warn "rsync nicht gefunden – fallback auf cp (weniger robust)"
    run cp -r "$WINDOWS_EFI_MOUNT/EFI/Microsoft" "$BOOT_MOUNT/EFI/"
  fi

  [[ -f "$BOOT_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] || die "Windows EFI konnte nicht auf Haupt-EFI gespiegelt werden."
  info "Windows EFI-Dateien nach $BOOT_MOUNT/EFI/Microsoft gespiegelt."
}

write_loader_conf() {
  local default_entry="auto"

  mkdir -p "$BOOT_MOUNT/loader"
  backup_file "$LOADER_CONF"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF >&2
[DRYRUN] würde schreiben: $LOADER_CONF
# Generated by $SCRIPT_NAME
default $default_entry
timeout $DEFAULT_TIMEOUT
editor $EDITOR_SETTING
auto-entries no
auto-firmware yes
console-mode max
EOF
    return 0
  fi

  cat > "$LOADER_CONF" <<EOF
# Generated by $SCRIPT_NAME
default $default_entry
timeout $DEFAULT_TIMEOUT
editor $EDITOR_SETTING
auto-entries no
auto-firmware yes
console-mode max
EOF

  info "loader.conf geschrieben: $LOADER_CONF"
}

write_arch_entry() {
  local root_options="$1"
  local microcode="$2"

  mkdir -p "$ENTRIES_DIR"
  backup_file "$ARCH_ENTRY"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    {
      echo "[DRYRUN] würde schreiben: $ARCH_ENTRY"
      echo "# Generated by $SCRIPT_NAME"
      echo "title   Arch Linux"
      echo "linux   $KERNEL_IMAGE"
      [[ -n "$microcode" ]] && echo "initrd  $microcode"
      echo "initrd  $INITRAMFS_IMAGE"
      echo "options $root_options"
    } >&2
    return 0
  fi

  {
    echo "# Generated by $SCRIPT_NAME"
    echo "title   Arch Linux"
    echo "linux   $KERNEL_IMAGE"
    [[ -n "$microcode" ]] && echo "initrd  $microcode"
    echo "initrd  $INITRAMFS_IMAGE"
    echo "options $root_options"
  } > "$ARCH_ENTRY"

  info "arch.conf geschrieben: $ARCH_ENTRY"
}

write_arch_fallback_entry() {
  local root_options="$1"
  local microcode="$2"

  mkdir -p "$ENTRIES_DIR"
  backup_file "$ARCH_FALLBACK_ENTRY"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    {
      echo "[DRYRUN] würde schreiben: $ARCH_FALLBACK_ENTRY"
      echo "# Generated by $SCRIPT_NAME"
      echo "title   Arch Linux (Fallback)"
      echo "linux   $KERNEL_IMAGE"
      [[ -n "$microcode" ]] && echo "initrd  $microcode"
      echo "initrd  $FALLBACK_INITRAMFS_IMAGE"
      echo "options $root_options"
    } >&2
    return 0
  fi

  {
    echo "# Generated by $SCRIPT_NAME"
    echo "title   Arch Linux (Fallback)"
    echo "linux   $KERNEL_IMAGE"
    [[ -n "$microcode" ]] && echo "initrd  $microcode"
    echo "initrd  $FALLBACK_INITRAMFS_IMAGE"
    echo "options $root_options"
  } > "$ARCH_FALLBACK_ENTRY"

  info "arch-fallback.conf geschrieben: $ARCH_FALLBACK_ENTRY"
}

write_windows_entry() {
  mkdir -p "$ENTRIES_DIR"
  backup_file "$WINDOWS_ENTRY"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF >&2
[DRYRUN] würde schreiben: $WINDOWS_ENTRY
# Generated by $SCRIPT_NAME
title   Windows
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF
    return 0
  fi

  cat > "$WINDOWS_ENTRY" <<EOF
# Generated by $SCRIPT_NAME
title   Windows
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF

  info "windows.conf geschrieben: $WINDOWS_ENTRY"
}

validate_boot_files() {
  [[ -f "$LOADER_CONF" ]] || die "loader.conf fehlt."
  [[ -f "$WINDOWS_ENTRY" ]] || die "windows.conf fehlt."
  [[ -f "$BOOT_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] || die "Windows bootmgfw.efi fehlt auf Haupt-EFI."

  if detect_uki; then
    local uki
    uki="$(get_uki_basename || true)"
    [[ -n "$uki" ]] || die "UKI-Modus erkannt, aber keine .efi unter $BOOT_MOUNT/EFI/Linux gefunden."
    info "UKI erkannt: $uki"
  else
    [[ -f "$ARCH_ENTRY" ]] || die "arch.conf fehlt."
    [[ -f "$ARCH_FALLBACK_ENTRY" ]] || warn "arch-fallback.conf fehlt."
    [[ -f "$BOOT_MOUNT$KERNEL_IMAGE" ]] || warn "Kerneldatei nicht gefunden: $BOOT_MOUNT$KERNEL_IMAGE"
    [[ -f "$BOOT_MOUNT$INITRAMFS_IMAGE" ]] || warn "Initramfs nicht gefunden: $BOOT_MOUNT$INITRAMFS_IMAGE"
    [[ -f "$BOOT_MOUNT$FALLBACK_INITRAMFS_IMAGE" ]] || warn "Fallback-Initramfs nicht gefunden: $BOOT_MOUNT$FALLBACK_INITRAMFS_IMAGE"
  fi

  info "Basisvalidierung abgeschlossen."
}

show_summary() {
  local root_source root_fstype root_dev root_uuid root_subvol root_options
  root_source="$(get_root_source)"
  root_fstype="$(get_root_fstype)"
  root_dev="$(get_root_device)"
  root_uuid="$(get_root_uuid)"
  root_subvol="$(get_btrfs_subvol)"
  root_options="$(build_root_options "$root_uuid")"

  echo
  echo "===== Zusammenfassung ====="
  echo "Boot-Mount:        $BOOT_MOUNT"
  echo "Boot-Quelle:       $(get_boot_mount_source)"
  echo "Entries-Verz.:     $ENTRIES_DIR"
  echo "Loader-Konfig:     $LOADER_CONF"
  echo "Arch-Entry:        $ARCH_ENTRY"
  echo "Arch-Fallback:     $ARCH_FALLBACK_ENTRY"
  echo "Windows-Entry:     $WINDOWS_ENTRY"
  echo "Windows-EFI-Mount: $WINDOWS_EFI_MOUNT"
  echo "Kernel-Preset:     $KERNEL_PRESET"
  echo "Root-Quelle:       $root_source"
  echo "Root-Device:       $root_dev"
  echo "Root-FS:           $root_fstype"
  echo "Root-UUID:         $root_uuid"
  echo "Btrfs Subvol:      ${root_subvol:-<keins>}"
  echo "Root-Optionen:     $root_options"
  if detect_uki; then
    echo "Boot-Modus Arch:   UKI"
    echo "UKI-Datei:         $(get_uki_basename)"
  else
    echo "Boot-Modus Arch:   klassisch"
  fi
  echo "Log:               $LOG_FILE"
  echo "==========================="
  echo
}

usage() {
  cat <<EOF
$SCRIPT_NAME [optionen]

Optionen:
  --dry-run            Befehle nur anzeigen
  --timeout SEC        Timeout in Sekunden (Default: 60)
  --default ENTRY      Default Entry (nur ohne UKI relevant; Default: arch.conf)
  --kernel PRESET      linux | linux-zen | linux-lts (Default: linux)
  -h, --help           Hilfe anzeigen

Erwartung:
  - laufendes Arch-System
  - systemd-boot als Bootloader
  - aktive Haupt-EFI ist bereits auf /boot gemountet
  - Windows liegt auf anderer SSD mit eigener EFI
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --timeout)
        shift
        [[ $# -gt 0 ]] || die "Fehlender Wert für --timeout"
        DEFAULT_TIMEOUT="$1"
        ;;
      --default)
        shift
        [[ $# -gt 0 ]] || die "Fehlender Wert für --default"
        DEFAULT_ENTRY="$1"
        ;;
      --kernel)
        shift
        [[ $# -gt 0 ]] || die "Fehlender Wert für --kernel"
        KERNEL_PRESET="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unbekannte Option: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  require_root
  require_uefi
  require_cmds
  set_kernel_paths
  get_boot_mount
  ensure_systemd_boot_present

  local root_uuid microcode windows_efi_dev root_options
  root_uuid="$(get_root_uuid)"
  microcode="$(detect_cpu_microcode)"
  root_options="$(build_root_options "$root_uuid")"

  info "Root UUID: $root_uuid"
  info "Root Optionen: $root_options"

  if [[ -n "$microcode" ]]; then
    info "Erkannter Microcode: $microcode"
  else
    warn "Kein Intel- oder AMD-Microcode erkannt."
  fi

  info "Suche Windows-EFI..."
  windows_efi_dev="$(choose_windows_efi)"
  info "Gewählte Windows-EFI: $windows_efi_dev"

  show_summary
  if ! confirm "Boot-Konfiguration jetzt schreiben und Windows-EFI importieren?"; then
    die "Abgebrochen durch Benutzer."
  fi

  mount_windows_efi "$windows_efi_dev"
  import_windows_efi
  write_loader_conf

  if detect_uki; then
    info "UKI erkannt unter $BOOT_MOUNT/EFI/Linux – klassische Arch-Entries werden übersprungen."
  else
    write_arch_entry "$root_options" "$microcode"
    write_arch_fallback_entry "$root_options" "$microcode"
  fi

  write_windows_entry

  if [[ "$DRY_RUN" -eq 0 ]]; then
    validate_boot_files
    echo
    bootctl --path="$BOOT_MOUNT" status || true
    echo
  fi

  info "Fertig. Bitte Dateien prüfen und danach testweise neu booten."
}

main "$@"