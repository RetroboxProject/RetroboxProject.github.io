#!/usr/bin/env bash
#
# Retrobox installer.
#
# Usage:
#   curl -fsSL https://retroboxproject.github.io/install.sh | bash
#   curl -fsSL https://retroboxproject.github.io/install.sh | bash -s -- --source
#
# Debian, Ubuntu and Fedora families install the latest release packages of
# every Retrobox component; apt/dnf pull in all the dependencies. Any other
# system (Arch, immutable distros, Bazzite...) builds from source by running
# the install.sh of retrobox-core.
#
# Environment variables:
#   GITHUB_TOKEN   Optional token to avoid GitHub API rate limits.
#   RETROBOX_REF   Optional branch or tag of retrobox-core for source installs.

set -euo pipefail

readonly GITHUB_API="https://api.github.com"
readonly CORE_REPO="RetroboxProject/retrobox-core"

# Components, in install order, and the GitHub repository publishing the
# release packages of each one.
readonly -a COMPONENTS=(
  retrobox-core
  retrobox-mangohud
  retrobox-emulationstation
  gamepadly
)
declare -rA REPO_OF=(
  [retrobox-core]="RetroboxProject/retrobox-core"
  [retrobox-mangohud]="RetroboxProject/retrobox-mangohud"
  [retrobox-emulationstation]="RetroboxProject/retrobox-emulationstation"
  [gamepadly]="RetroboxProject/gamepadly"
)

# Release assets that must never be installed.
readonly EXCLUDE_RE='dbgsym|debuginfo|debugsource|\.src\.rpm$'
# Any distro marker in an asset name. Assets carrying one are only used when
# it matches the running system; assets without any are considered generic.
readonly ANY_TAG_RE='(debian|ubuntu|fedora)[-_.]?[0-9]|[._-]fc[0-9]+|[._-]el[0-9]+|trixie|bookworm|bullseye|forky|focal|jammy|noble|resolute|oracular|plucky|questing'
# A regular expression that never matches.
readonly NEVER_RE='a^'

FORCE_SOURCE=0
FAMILY=""
ARCH=""
UBUNTU_TARGET=""
TMP_DIR=""
SUDO=()
DOWNLOAD_URLS=()

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}

usage() {
  cat <<'EOF'
Retrobox installer

Options:
  --source    Build from source instead of installing packages.
  -h, --help  Show this help.
EOF
}

setup_privileges() {
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
    return
  fi
  command -v sudo >/dev/null 2>&1 ||
    die "root privileges are required: run as root or install sudo"
  SUDO=(sudo)
}

has_word() {
  [[ " $1 " == *" $2 "* ]]
}

is_rhel_clone() {
  case "$1" in
    rhel | centos | almalinux | rocky | ol | amzn) return 0 ;;
    *) return 1 ;;
  esac
}

load_os_release() {
  local file
  for file in /etc/os-release /usr/lib/os-release; do
    if [[ -r "${file}" ]]; then
      # shellcheck disable=SC1090
      . "${file}"
      return
    fi
  done
  warn "cannot read /etc/os-release"
}

# Print the distribution family: ubuntu, debian, fedora or other.
detect_family() {
  local id="${ID:-}" like="${ID_LIKE:-}"
  # Image-based systems (Silverblue, Bazzite...) cannot take plain packages.
  if [[ -e /run/ostree-booted ]]; then
    printf 'other\n'
  elif [[ "${id}" == "ubuntu" ]] || has_word "${like}" ubuntu; then
    printf 'ubuntu\n'
  elif [[ "${id}" == "debian" ]] || has_word "${like}" debian; then
    printf 'debian\n'
  elif [[ "${id}" == "fedora" ]] ||
    { has_word "${like}" fedora && ! is_rhel_clone "${id}"; }; then
    printf 'fedora\n'
  else
    printf 'other\n'
  fi
}

# Print the CPU family supported by the packages, or nothing.
detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    *) printf '\n' ;;
  esac
}

cpu_supports_x86_64_v3() {
  local flags flag
  flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)" || return 1
  flags="${flags//$'\t'/ }"
  for flag in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
    [[ " ${flags} " == *" ${flag} "* ]] || return 1
  done
}

# Print the Ubuntu release a system is based on (e.g. 24.04).
resolve_ubuntu_base() {
  if [[ "${ID:-}" == "ubuntu" ]]; then
    printf '%s\n' "${VERSION_ID:-}"
    return
  fi
  case "${UBUNTU_CODENAME:-}" in
    focal) printf '20.04\n' ;;
    jammy) printf '22.04\n' ;;
    noble) printf '24.04\n' ;;
    oracular) printf '24.10\n' ;;
    plucky) printf '25.04\n' ;;
    questing) printf '25.10\n' ;;
    resolute) printf '26.04\n' ;;
    *) printf '\n' ;;
  esac
}

# Print the newest LTS release that is not newer than the given version.
ubuntu_lts_for() {
  local year=$((10#${1%%.*})) month=$((10#${1#*.}))
  if ((year % 2 == 0)); then
    if ((month >= 4)); then
      printf '%02d.04\n' "${year}"
    else
      printf '%02d.04\n' $((year - 2))
    fi
  else
    printf '%02d.04\n' $((year - 1))
  fi
}

ubuntu_codename_for() {
  case "$1" in
    20.04) printf 'focal\n' ;;
    22.04) printf 'jammy\n' ;;
    24.04) printf 'noble\n' ;;
    26.04) printf 'resolute\n' ;;
    *) printf '\n' ;;
  esac
}

# Print a regular expression matching the asset names built for this system.
distro_tag_regex() {
  local -a parts=()
  local version codename
  case "${FAMILY}" in
    ubuntu)
      parts+=("ubuntu[-_.]?${UBUNTU_TARGET//./\\.}")
      parts+=("ubuntu[-_.]?${UBUNTU_TARGET//./}")
      codename="$(ubuntu_codename_for "${UBUNTU_TARGET}")"
      [[ -z "${codename}" ]] || parts+=("${codename}")
      ;;
    debian)
      version=""
      [[ "${ID:-}" != "debian" ]] || version="${VERSION_ID:-}"
      codename="${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
      [[ -z "${version}" ]] || parts+=("debian[-_.]?${version}")
      [[ -z "${codename}" ]] || parts+=("${codename}")
      ;;
    fedora)
      version="${VERSION_ID:-}"
      if [[ "${version}" =~ ^[0-9]+$ ]]; then
        parts+=("fc${version}" "fedora[-_.]?${version}")
      fi
      ;;
  esac
  if ((${#parts[@]} == 0)); then
    printf '%s' "${NEVER_RE}"
    return
  fi
  local IFS='|'
  printf '(%s)' "${parts[*]}"
}

# Print the asset-name regexes for a package type and CPU, best match first.
arch_regexes() {
  local ext="$1" arch="$2"
  case "${ext}:${arch}" in
    deb:x86_64)
      if cpu_supports_x86_64_v3; then
        printf '%s\n' '[_.-](amd64[_-]?v3|x86[_-]64[_-]v3)\.deb$'
      fi
      printf '%s\n' '[_.-]amd64\.deb$'
      ;;
    deb:aarch64)
      printf '%s\n' '[_.-]arm64\.deb$'
      ;;
    rpm:x86_64)
      if cpu_supports_x86_64_v3; then
        printf '%s\n' '\.x86[_-]64[_-]?v3\.rpm$'
      fi
      printf '%s\n' '\.x86_64\.rpm$'
      ;;
    rpm:aarch64)
      printf '%s\n' '\.aarch64\.rpm$'
      ;;
  esac
}

api_get() {
  local -a headers=(-H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --proto '=https' --tlsv1.2 "${headers[@]}" "$1"
}

# Print the JSON of the latest release; fall back to pre-releases.
fetch_latest_release() {
  local repo="$1"
  api_get "${GITHUB_API}/repos/${repo}/releases/latest" ||
    api_get "${GITHUB_API}/repos/${repo}/releases?per_page=1"
}

# Read asset URLs on stdin and print those to install.
# Args: package type (deb|rpm), CPU family, distro tag regex.
select_assets() {
  local ext="$1" arch="$2" tag_re="$3"
  local url name arch_re
  local -a all=() matched=() tagged=() generic=()
  mapfile -t all
  while IFS= read -r arch_re; do
    matched=()
    for url in "${all[@]}"; do
      name="${url##*/}"
      name="${name,,}"
      if [[ "${name}" =~ ${arch_re} && ! "${name}" =~ ${EXCLUDE_RE} ]]; then
        matched+=("${url}")
      fi
    done
    tagged=()
    generic=()
    for url in "${matched[@]}"; do
      name="${url##*/}"
      name="${name,,}"
      if [[ "${name}" =~ ${tag_re} ]]; then
        tagged+=("${url}")
      elif [[ ! "${name}" =~ ${ANY_TAG_RE} ]]; then
        generic+=("${url}")
      fi
    done
    if ((${#tagged[@]} > 0)); then
      printf '%s\n' "${tagged[@]}"
      return 0
    fi
    if ((${#generic[@]} > 0)); then
      printf '%s\n' "${generic[@]}"
      return 0
    fi
  done < <(arch_regexes "${ext}" "${arch}")
  return 1
}

# Find the packages to install in the latest release of every component.
collect_packages() {
  local ext="$1" tag_re component repo json tag
  local -a urls=() chosen=()
  tag_re="$(distro_tag_regex)"
  for component in "${COMPONENTS[@]}"; do
    repo="${REPO_OF[${component}]}"
    json="$(fetch_latest_release "${repo}")" ||
      die "cannot fetch the latest release of ${repo} (rate limited? set GITHUB_TOKEN)"
    tag="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/{p;q}' <<<"${json}")"
    mapfile -t urls < <(
      sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' <<<"${json}"
    )
    mapfile -t chosen < <(
      printf '%s\n' "${urls[@]}" | select_assets "${ext}" "${ARCH}" "${tag_re}"
    )
    ((${#chosen[@]} > 0)) ||
      die "no .${ext} package for ${ARCH} in the latest ${component} release (${tag:-unknown})"
    log "Found ${component} ${tag:-unknown}"
    DOWNLOAD_URLS+=("${chosen[@]}")
  done
}

download_packages() {
  local url
  TMP_DIR="$(mktemp -d)"
  # Let the unprivileged apt sandbox user read the files.
  chmod 755 "${TMP_DIR}"
  for url in "${DOWNLOAD_URLS[@]}"; do
    log "Downloading ${url##*/}"
    curl -fsSL --proto '=https' --tlsv1.2 -o "${TMP_DIR}/${url##*/}" "${url}"
  done
  chmod 644 "${TMP_DIR}"/*
}

install_packages() {
  local ext="$1"
  local -a files=("${TMP_DIR}"/*."${ext}")
  case "${ext}" in
    deb)
      log "Updating package lists"
      "${SUDO[@]}" apt-get update
      log "Installing packages and their dependencies"
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${files[@]}"
      ;;
    rpm)
      log "Installing packages and their dependencies"
      "${SUDO[@]}" dnf install -y "${files[@]}"
      ;;
  esac
}

install_from_packages() {
  local ext="$1" manager="$2"
  command -v "${manager}" >/dev/null 2>&1 || die "${manager} not found"
  setup_privileges
  collect_packages "${ext}"
  download_packages
  install_packages "${ext}"
  log "Retrobox installed. Start it with: retrobox"
}

install_from_source() {
  command -v git >/dev/null 2>&1 || die "git is required for a source install"
  setup_privileges
  TMP_DIR="$(mktemp -d)"
  local -a clone=(git clone --depth 1)
  if [[ -n "${RETROBOX_REF:-}" ]]; then
    clone+=(--branch "${RETROBOX_REF}")
  fi
  log "Cloning ${CORE_REPO}"
  "${clone[@]}" "https://github.com/${CORE_REPO}.git" "${TMP_DIR}/retrobox-core"
  [[ -f "${TMP_DIR}/retrobox-core/install.sh" ]] ||
    die "install.sh not found in ${CORE_REPO}"
  log "Running install.sh from retrobox-core"
  (cd "${TMP_DIR}/retrobox-core" && "${SUDO[@]}" bash ./install.sh)
}

main() {
  trap cleanup EXIT

  while (($# > 0)); do
    case "$1" in
      --source) FORCE_SOURCE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  if ((FORCE_SOURCE)); then
    install_from_source
    return
  fi

  load_os_release
  FAMILY="$(detect_family)"
  ARCH="$(detect_arch)"
  if [[ "${FAMILY}" == "other" || -z "${ARCH}" ]]; then
    log "No packages for this system (${ID:-unknown}, $(uname -m)); building from source"
    install_from_source
    return
  fi

  case "${FAMILY}" in
    ubuntu)
      local base
      base="$(resolve_ubuntu_base)"
      [[ -n "${base}" ]] || die "cannot tell which Ubuntu release this is; try --source"
      UBUNTU_TARGET="$(ubuntu_lts_for "${base}")"
      if [[ "${UBUNTU_TARGET}" != "${base}" ]]; then
        log "Ubuntu ${base} is not an LTS release; using Ubuntu ${UBUNTU_TARGET} packages"
      fi
      install_from_packages deb apt-get
      ;;
    debian) install_from_packages deb apt-get ;;
    fedora) install_from_packages rpm dnf ;;
  esac
}

main "$@"
