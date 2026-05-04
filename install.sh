#!/bin/bash
# Install or upgrade the clor CLI under ~/.local/bin.
#
# Safe to re-run. Each run downloads the pinned version, verifies its
# SHA256 against the published checksum, drops it into a versioned
# directory under ~/.local/share/clor/<version>/, and then flips the
# ~/.local/bin/clor symlink to point at it. So "upgrade" and "install"
# are the same code path, and rollback is one ln command.
#
# Quiet by default. Set DEBUG=true if you want to see what's happening.

set -o errexit
set -o nounset
set -o pipefail

# ----------------------------------------------------------------------
# Config.
#
# DEBUG is read from the env so you can do `DEBUG=true bash install.sh`
# without editing the file. Same idea for CLOR_VERSION if you want to
# pin or test a specific release.
# ----------------------------------------------------------------------

DEBUG="${DEBUG:-false}"
SUPPORT_EMAIL="support@clor.com"
DEFAULT_VERSION="v0.1.0"
VERSION="${CLOR_VERSION:-${DEFAULT_VERSION}}"
INSTALL_DIR="${HOME}/.local/bin"
EXE="${INSTALL_DIR}/clor"
VERSIONS_DIR="${HOME}/.local/share/clor"
VERSION_DIR="${VERSIONS_DIR}/${VERSION}"
VERSIONED_EXE="${VERSION_DIR}/clor"
BASE_URL="https://github.com/clorhq/cli/releases/download/${VERSION}"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
RC_MARKER="# Added by clor install.sh"
MAX_ATTEMPTS=5

# ----------------------------------------------------------------------
# Logging.
#
# Three levels: chatty progress (debug, off by default), things the
# user has to see even on a successful install (info, e.g. PATH
# instructions), and failures (error). Everything goes to stderr so
# stdout stays clean for anything that might pipe this script.
# ----------------------------------------------------------------------

log_debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        printf '%s\n' "$*" >&2
    fi
}

log_info() {
    printf '%s\n' "$*" >&2
}

log_error() {
    printf 'error: %s\n' "$*" >&2
}

# Printed after errors the user can't fix locally (corrupt release
# asset, repeated CDN failures, checksum mismatch). Local-environment
# problems like "you don't have curl" get a different suggestion in
# the error itself.
log_support_hint() {
    printf 'If this keeps happening, contact %s for help.\n' "${SUPPORT_EMAIL}" >&2
}

# ----------------------------------------------------------------------
# Downloads.
#
# Retry with backoff. A new release sometimes 404s on the CDN for a
# few seconds after publish, and networks drop packets occasionally.
# Same helper is used for the binary and its .sha256 checksum file.
# ----------------------------------------------------------------------

download_with_retry() {
    local url="$1"
    local out="$2"
    local attempt=1
    local rc delay
    while true; do
        rc=0
        case "${DOWNLOADER}" in
            curl)
                curl --fail --silent --show-error --location --output "${out}" "${url}" >/dev/null 2>&1 || rc=$?
                ;;
            wget)
                wget --quiet --output-document="${out}" "${url}" >/dev/null 2>&1 || rc=$?
                ;;
        esac
        if [[ ${rc} -eq 0 ]]; then
            return 0
        fi
        if [[ ${attempt} -ge ${MAX_ATTEMPTS} ]]; then
            log_error "Download of ${url} failed after ${attempt} attempts."
            log_support_hint
            return 1
        fi
        delay=$(( attempt * 2 ))
        log_debug "Download attempt ${attempt} for ${url} failed (exit ${rc}); retrying in ${delay}s..."
        sleep "${delay}"
        attempt=$(( attempt + 1 ))
    done
}

# ----------------------------------------------------------------------
# main
#
# Everything below runs inside a function so the script only executes
# once the whole file has been parsed. That matters for the
# curl-to-bash flow: if the connection drops mid-download, bash never
# sees `main "$@"` at the bottom and bails out instead of running half
# a script.
# ----------------------------------------------------------------------

main() {
    local OS ARCH ASSET URL DOWNLOADER TMP SUMTMP EXPECTED ACTUAL
    local shell_name modified rc
    local rcs

    # ------------------------------------------------------------------
    # Which binary do we want?
    #
    # uname tells us, plus a special case below for Rosetta. We name
    # release assets clor-<os>-<arch> so this maps directly to a URL.
    # ------------------------------------------------------------------

    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "${OS}" in
        Darwin) OS="darwin" ;;
        Linux)  OS="linux" ;;
        *)
            log_error "Unsupported OS: ${OS}."
            log_error "Supported: Darwin (macOS), Linux. For Windows, see SETUP.md."
            exit 1
            ;;
    esac

    case "${ARCH}" in
        x86_64|amd64)  ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: ${ARCH}."
            log_error "Supported: x86_64, amd64, arm64, aarch64."
            exit 1
            ;;
    esac

    # On Apple Silicon, bash itself may be the x86_64 build running
    # under Rosetta. If so, uname reports amd64 even though the native
    # binary would be faster. proc_translated == 1 means "yes, you're
    # in Rosetta", so flip to arm64.
    if [[ "${OS}" == "darwin" && "${ARCH}" == "amd64" ]]; then
        if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
            ARCH="arm64"
        fi
    fi

    ASSET="clor-${OS}-${ARCH}"
    URL="${BASE_URL}/${ASSET}"

    # ------------------------------------------------------------------
    # Pick a downloader. Either curl or wget works.
    # ------------------------------------------------------------------

    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        log_error "Neither curl nor wget is installed; cannot download ${ASSET}."
        log_error "Install curl or wget and re-run this script."
        exit 1
    fi

    # ------------------------------------------------------------------
    # Lay out the install tree.
    #
    #   ~/.local/share/clor/<version>/clor   the real binary
    #   ~/.local/bin/clor                    symlink to the active one
    #
    # Keeping versioned binaries on disk means rollback is just
    # repointing the symlink. ~/.local/bin stays tidy.
    # ------------------------------------------------------------------

    mkdir -p "${INSTALL_DIR}" "${VERSION_DIR}"

    # Download to a temp file in the versioned dir, then rename(2)
    # into place once we've verified it. Same filesystem so the
    # rename is atomic, and any clor process that's already running
    # keeps its old inode and won't see a torn write.
    TMP="${VERSIONED_EXE}.tmp.$$"
    SUMTMP="${TMP}.sha256"
    trap 'rm -f "${TMP}" "${SUMTMP}"' EXIT

    if [[ -e "${EXE}" || -L "${EXE}" ]]; then
        log_debug "Upgrading existing clor at ${EXE}..."
    else
        log_debug "Installing clor to ${EXE}..."
    fi

    # ------------------------------------------------------------------
    # Download the binary.
    # ------------------------------------------------------------------

    log_debug "Downloading ${URL}..."
    download_with_retry "${URL}" "${TMP}" || exit 1

    if [[ ! -s "${TMP}" ]]; then
        log_error "Downloaded file ${URL} is empty; refusing to install."
        log_support_hint
        exit 1
    fi

    # ------------------------------------------------------------------
    # Verify the download.
    #
    # We never install a binary we can't verify. The .sha256 sidecar
    # is published next to the binary on every release; if it's
    # missing, malformed, or the digest doesn't match what's on disk,
    # we bail out and leave the existing install untouched.
    # ------------------------------------------------------------------

    log_debug "Verifying checksum..."
    if ! download_with_retry "${URL}.sha256" "${SUMTMP}"; then
        log_error "Failed to download checksum file ${URL}.sha256."
        log_error "Refusing to install without verification."
        log_support_hint
        exit 1
    fi

    # GNU sha256sum format is "<digest>  <filename>\n". Take field 1.
    EXPECTED="$(awk '{print $1; exit}' "${SUMTMP}" | tr 'A-Z' 'a-z')"
    if [[ ! "${EXPECTED}" =~ ^[a-f0-9]{64}$ ]]; then
        log_error "Checksum file ${URL}.sha256 did not contain a valid SHA256 digest."
        log_support_hint
        exit 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL="$(sha256sum "${TMP}" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL="$(shasum -a 256 "${TMP}" | awk '{print $1}')"
    else
        log_error "Neither sha256sum nor shasum is installed; cannot verify download."
        log_error "Install one of them and re-run this script."
        exit 1
    fi
    ACTUAL="$(echo "${ACTUAL}" | tr 'A-Z' 'a-z')"

    if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
        log_error "Checksum mismatch for ${ASSET}:"
        log_error "  expected: ${EXPECTED}"
        log_error "  actual:   ${ACTUAL}"
        log_error "Refusing to install a binary that doesn't match its published checksum."
        log_support_hint
        exit 1
    fi

    # ------------------------------------------------------------------
    # Park the verified binary in the versioned directory.
    # ------------------------------------------------------------------

    chmod +x "${TMP}"
    mv -f "${TMP}" "${VERSIONED_EXE}"
    rm -f "${SUMTMP}"
    trap - EXIT

    # macOS marks downloaded files with com.apple.quarantine, which
    # causes Gatekeeper to refuse the first execution. Strip it now,
    # before the --help check below, so we don't reject a good binary.
    if [[ "${OS}" == "darwin" ]] && command -v xattr >/dev/null 2>&1; then
        xattr -d com.apple.quarantine "${VERSIONED_EXE}" >/dev/null 2>&1 || true
    fi

    # ------------------------------------------------------------------
    # Make sure it actually runs.
    #
    # `--help` is cheap and exercises arg parsing, so it's a reasonable
    # "does the binary load and execute" check. If it fails, we leave
    # the existing symlink alone so the user still has a working clor,
    # and we clean up the broken versioned copy.
    # ------------------------------------------------------------------

    log_debug "Verifying ${VERSIONED_EXE} --help runs..."
    if ! "${VERSIONED_EXE}" --help >/dev/null 2>&1; then
        log_error "${VERSIONED_EXE} --help did not exit 0; refusing to activate this binary."
        log_error "Leaving ${EXE} unchanged so your existing clor still works."
        log_support_hint
        rm -f "${VERSIONED_EXE}"
        exit 1
    fi

    # ------------------------------------------------------------------
    # Activate the new version.
    #
    # Remove whatever was at ${EXE} (real binary from a pre-symlink
    # install, stale symlink, or nothing) and point a fresh symlink at
    # the versioned binary.
    # ------------------------------------------------------------------

    rm -f "${EXE}"
    ln -s "${VERSIONED_EXE}" "${EXE}"
    log_debug "Linked ${EXE} -> ${VERSIONED_EXE}"

    # ------------------------------------------------------------------
    # PATH.
    #
    # If ~/.local/bin isn't on PATH yet, try to add it for the user's
    # shell. fish has its own universal-path mechanism; bash and zsh
    # get a line appended to the right rc file, marked so re-runs
    # don't duplicate it. We tell the user what we did so they know
    # to open a new shell.
    # ------------------------------------------------------------------

    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*)
            ;;
        *)
            shell_name="$(basename "${SHELL:-}")"
            modified=""
            case "${shell_name}" in
                fish)
                    if command -v fish >/dev/null 2>&1; then
                        fish -c "fish_add_path -U ${INSTALL_DIR}" >/dev/null 2>&1 || true
                        modified="(fish universal path)"
                    fi
                    ;;
                bash|zsh|*)
                    if [[ "${shell_name}" == "zsh" ]]; then
                        rcs=("${HOME}/.zshrc")
                    elif [[ "${shell_name}" == "bash" ]]; then
                        rcs=("${HOME}/.bashrc" "${HOME}/.bash_profile")
                    else
                        rcs=("${HOME}/.bashrc" "${HOME}/.zshrc")
                    fi
                    for rc in "${rcs[@]}"; do
                        [[ -f "${rc}" ]] || continue
                        if grep --fixed-strings --quiet "${PATH_LINE}" "${rc}"; then
                            continue
                        fi
                        printf '\n%s\n%s\n' "${RC_MARKER}" "${PATH_LINE}" >> "${rc}"
                        modified="${rc}"
                    done
                    ;;
            esac
            if [[ -n "${modified}" ]]; then
                log_info "Added ${INSTALL_DIR} to PATH in ${modified}."
                log_info "Open a new shell (or 'source' the file) to pick it up."
            else
                log_info "warning: ${INSTALL_DIR} is not on PATH and no rc file was found to update."
                log_info "Append this line to your shell config manually:"
                log_info "  ${PATH_LINE}"
            fi
            ;;
    esac

    # ------------------------------------------------------------------
    # Hand off to clor itself.
    #
    # The CLI runs its own first-run flow (auth, etc.) on first
    # invocation. If the user Ctrl-Cs out of it, the install still
    # succeeded, so we swallow any non-zero exit here.
    # ------------------------------------------------------------------

    "${EXE}" || true
}

main "$@"
