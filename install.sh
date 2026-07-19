#!/bin/bash
# Install or upgrade the clor CLI under ~/.local/bin.
#
# Safe to re-run. Downloads the pinned version, verifies its SHA256,
# stores it under ~/.local/share/clor/<version>/, and points the
# ~/.local/bin/clor symlink at it.
#
# Quiet by default. Set DEBUG=true for progress output.

set -o errexit
set -o nounset
set -o pipefail

# DEBUG, CLOR_VERSION, CLOR_INSTALL_FORCE, and CLOR_AUTOUPDATE are read from
# the environment.
# An explicit version pin disables automatic updates unless
# CLOR_AUTOUPDATE=true is also explicitly supplied.

DEBUG="${DEBUG:-false}"
SUPPORT_EMAIL="support@clor.com"
LATEST_VERSION="v1.8.1"
VERSION="${CLOR_VERSION:-${LATEST_VERSION}}"
CLOR_INSTALL_FORCE="${CLOR_INSTALL_FORCE:-false}"
if [[ "${CLOR_AUTOUPDATE:-}" == "" ]]; then
    if [[ "${CLOR_VERSION:-}" != "" ]]; then
        CLOR_AUTOUPDATE="false"
    else
        CLOR_AUTOUPDATE="true"
    fi
fi
INSTALL_DIR="${HOME}/.local/bin"
EXE="${INSTALL_DIR}/clor"
VERSIONS_DIR="${HOME}/.local/share/clor"
VERSION_DIR="${VERSIONS_DIR}/${VERSION}"
VERSIONED_EXE="${VERSION_DIR}/clor"
BASE_URL="https://github.com/clorhq/cli/releases/download/${VERSION}"
# Keep these variables literal for the shell rc file written later.
# shellcheck disable=SC2016
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
RC_MARKER="# Added by clor install.sh"
MAX_ATTEMPTS="5"

# debug is off by default; info is for messages the user must see even on
# success; error is for failures. Everything goes to stderr so stdout stays
# clean when piped.

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

# Printed after errors the user cannot fix locally.
log_support_hint() {
    printf 'If this keeps happening, contact %s for help.\n' "${SUPPORT_EMAIL}" >&2
}

systemd_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '%s' "${value}"
}

clor_systemctl() {
    if [[ "$(id -u)" == "0" ]]; then
        systemctl "$@"
    else
        systemctl --user "$@"
    fi
}

install_systemd_autoupdate() {
    local unit_dir service timer service_tmp timer_tmp
    local escaped_home escaped_path escaped_exe

    if ! command -v systemctl >/dev/null 2>&1; then
        log_info "warning: systemd is unavailable; clor automatic updates were not scheduled."
        return 0
    fi
    if [[ "$(id -u)" == "0" ]]; then
        unit_dir="/etc/systemd/system"
    else
        unit_dir="${HOME}/.config/systemd/user"
    fi
    service="${unit_dir}/clor-autoupdate.service"
    timer="${unit_dir}/clor-autoupdate.timer"
    service_tmp="${service}.tmp.$$"
    timer_tmp="${timer}.tmp.$$"
    escaped_home="$(systemd_escape "${HOME}")"
    escaped_path="$(systemd_escape "${INSTALL_DIR}:${PATH}")"
    escaped_exe="$(systemd_escape "${EXE}")"

    mkdir -p "${unit_dir}"
    {
        printf '%s\n' \
            '[Unit]' \
            'Description=Update clor when a new stable release is available' \
            '' \
            '[Service]' \
            'Type=oneshot' \
            'Environment=CLOR_AUTOUPDATE=true' \
            'Environment=CLOR_INSTALL_FORCE=false' \
            "Environment=\"HOME=${escaped_home}\"" \
            "Environment=\"PATH=${escaped_path}\"" \
            "ExecStart=\"${escaped_exe}\" install"
    } > "${service_tmp}"
    {
        printf '%s\n' \
            '[Unit]' \
            'Description=Check every six hours for clor updates' \
            '' \
            '[Timer]' \
            'OnCalendar=*-*-* 00:00:00' \
            'OnCalendar=*-*-* 06:00:00' \
            'OnCalendar=*-*-* 12:00:00' \
            'OnCalendar=*-*-* 18:00:00' \
            'Persistent=true' \
            'Unit=clor-autoupdate.service' \
            '' \
            '[Install]' \
            'WantedBy=timers.target'
    } > "${timer_tmp}"
    chmod 644 "${service_tmp}" "${timer_tmp}"
    mv -f "${service_tmp}" "${service}"
    mv -f "${timer_tmp}" "${timer}"

    if ! clor_systemctl daemon-reload >/dev/null 2>&1 ||
       ! clor_systemctl enable --now clor-autoupdate.timer >/dev/null 2>&1; then
        log_info "warning: systemd could not schedule clor automatic updates."
        return 0
    fi
    log_debug "Scheduled clor updates every six hours with systemd."
}

remove_systemd_autoupdate() {
    local unit_dir
    if [[ "$(id -u)" == "0" ]]; then
        unit_dir="/etc/systemd/system"
    else
        unit_dir="${HOME}/.config/systemd/user"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        clor_systemctl disable --now clor-autoupdate.timer >/dev/null 2>&1 || true
        clor_systemctl stop clor-autoupdate.service >/dev/null 2>&1 || true
    fi
    rm -f "${unit_dir}/clor-autoupdate.service" "${unit_dir}/clor-autoupdate.timer"
    if command -v systemctl >/dev/null 2>&1; then
        clor_systemctl daemon-reload >/dev/null 2>&1 || true
        clor_systemctl reset-failed clor-autoupdate.service >/dev/null 2>&1 || true
    fi
}

xml_escape() {
    local value="$1"
    value="${value//&/\&amp;}"
    value="${value//</\&lt;}"
    value="${value//>/\&gt;}"
    value="${value//\"/\&quot;}"
    value="${value//\'/\&apos;}"
    printf '%s' "${value}"
}

install_launchd_autoupdate() {
    local plist plist_tmp domain
    local escaped_home escaped_path escaped_exe
    if ! command -v launchctl >/dev/null 2>&1; then
        log_info "warning: launchd is unavailable; clor automatic updates were not scheduled."
        return 0
    fi
    plist="${HOME}/Library/LaunchAgents/com.clor.autoupdate.plist"
    plist_tmp="${plist}.tmp.$$"
    domain="gui/$(id -u)"
    escaped_home="$(xml_escape "${HOME}")"
    escaped_path="$(xml_escape "${INSTALL_DIR}:${PATH}")"
    escaped_exe="$(xml_escape "${EXE}")"

    mkdir -p "$(dirname "${plist}")"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        cat <<EOF
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clor.autoupdate</string>
    <key>ProgramArguments</key>
    <array>
        <string>${escaped_exe}</string>
        <string>install</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CLOR_AUTOUPDATE</key>
        <string>true</string>
        <key>CLOR_INSTALL_FORCE</key>
        <string>false</string>
        <key>HOME</key>
        <string>${escaped_home}</string>
        <key>PATH</key>
        <string>${escaped_path}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
    } > "${plist_tmp}"
    chmod 644 "${plist_tmp}"
    mv -f "${plist_tmp}" "${plist}"

    # A loaded job may be the parent of this install. Leave it running; the
    # atomically replaced plist will be used after the next login.
    if launchctl print "${domain}/com.clor.autoupdate" >/dev/null 2>&1; then
        log_debug "Clor updates are already scheduled with launchd."
        return 0
    fi
    if ! launchctl bootstrap "${domain}" "${plist}" >/dev/null 2>&1; then
        log_info "warning: launchd could not schedule clor automatic updates."
        return 0
    fi
    log_debug "Scheduled clor updates every six hours with launchd."
}

remove_launchd_autoupdate() {
    local plist domain
    plist="${HOME}/Library/LaunchAgents/com.clor.autoupdate.plist"
    domain="gui/$(id -u)"
    if command -v launchctl >/dev/null 2>&1 &&
       launchctl print "${domain}/com.clor.autoupdate" >/dev/null 2>&1; then
        launchctl bootout "${domain}/com.clor.autoupdate" >/dev/null 2>&1 || true
    fi
    rm -f "${plist}"
}

configure_autoupdate() {
    local os="$1"
    if [[ "${CLOR_AUTOUPDATE}" == "true" ]]; then
        case "${os}" in
            linux)  install_systemd_autoupdate ;;
            darwin) install_launchd_autoupdate ;;
        esac
    else
        case "${os}" in
            linux)  remove_systemd_autoupdate ;;
            darwin) remove_launchd_autoupdate ;;
        esac
        log_debug "Disabled clor automatic updates."
    fi
}

# Download with retry and backoff: fresh releases sometimes 404 on the CDN
# for a few seconds, and networks drop. Used for both the binary and its
# checksum.

download_with_retry() {
    local downloader="$1"
    local url="$2"
    local out="$3"
    local attempt="1"
    local rc delay
    while true; do
        rc="0"
        case "${downloader}" in
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

# Extract the first standalone v?X.Y.Z token printed by `clor version` and
# normalize it to vX.Y.Z. An empty result means the output was not trustworthy,
# so the caller conservatively downloads and verifies the requested release.
normalize_clor_version() {
    local output="$1"
    local version_re='(^|[^[:alnum:].])v?([0-9]+\.[0-9]+\.[0-9]+)($|[^[:alnum:].])'

    if [[ "${output}" =~ ${version_re} ]]; then
        printf 'v%s\n' "${BASH_REMATCH[2]}"
    fi
}

# Everything runs inside main() so that a connection drop mid-download
# leaves bash without the final `main "$@"` line and nothing executes.

main() {
    local OS ARCH ASSET URL DOWNLOADER TMP SUMTMP EXPECTED ACTUAL
    local shell_name modified rc path_configured version_output current_version
    local rcs

    case "${CLOR_AUTOUPDATE}" in
        true|false) ;;
        *)
            log_error "CLOR_AUTOUPDATE must be 'true' or 'false' (got '${CLOR_AUTOUPDATE}')."
            exit 1
            ;;
    esac
    case "${CLOR_INSTALL_FORCE}" in
        true|false) ;;
        *)
            log_error "CLOR_INSTALL_FORCE must be 'true' or 'false' (got '${CLOR_INSTALL_FORCE}')."
            exit 1
            ;;
    esac
    if [[ ! "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "CLOR_VERSION must look like 'v1.2.3' (got '${VERSION}')."
        exit 1
    fi

    # Map uname to a release asset name, clor-<os>-<arch>.

    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "${OS}" in
        Darwin) OS="darwin" ;;
        Linux)  OS="linux" ;;
        *)
            log_error "Unsupported OS: ${OS}."
            log_error "Supported: Darwin (macOS), Linux."
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

    # Under Rosetta uname reports amd64 on Apple Silicon; install the
    # native arm64 build instead.
    if [[ "${OS}" == "darwin" && "${ARCH}" == "amd64" ]]; then
        if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
            ARCH="arm64"
        fi
    fi

    ASSET="clor-${OS}-${ARCH}"
    URL="${BASE_URL}/${ASSET}"

    # A normal install is a no-op for the binary when the requested version
    # is already active. The caller may still continue with daemon and plugin
    # setup after this script returns. CLOR_INSTALL_FORCE=true reinstalls and
    # verifies the binary even when the versions match.

    current_version=""
    if [[ -x "${EXE}" ]]; then
        version_output="$("${EXE}" version 2>/dev/null || true)"
        current_version="$(normalize_clor_version "${version_output}")"
    fi
    if [[ "${CLOR_INSTALL_FORCE}" == "true" ||
          "${current_version}" != "${VERSION}" ]]; then

        # curl or wget, whichever exists.

        if command -v curl >/dev/null 2>&1; then
            DOWNLOADER="curl"
        elif command -v wget >/dev/null 2>&1; then
            DOWNLOADER="wget"
        else
            log_error "Neither curl nor wget is installed; cannot download ${ASSET}."
            log_error "Install curl or wget and re-run this script."
            exit 1
        fi

        # ~/.local/share/clor/<version>/clor is the real binary;
        # ~/.local/bin/clor is a symlink to the active one, so rollback is one
        # ln command.

        mkdir -p "${INSTALL_DIR}" "${VERSION_DIR}"

        # Download to a temp file in the versioned directory, verify, then
        # rename(2) into place atomically; a running clor keeps its old inode.
        TMP="${VERSIONED_EXE}.tmp.$$"
        SUMTMP="${TMP}.sha256"
        trap 'rm -f "${TMP}" "${SUMTMP}"' EXIT

        if [[ -e "${EXE}" || -L "${EXE}" ]]; then
            log_debug "Upgrading existing clor at ${EXE}..."
        else
            log_debug "Installing clor to ${EXE}..."
        fi

        log_debug "Downloading ${URL}..."
        download_with_retry "${DOWNLOADER}" "${URL}" "${TMP}" || exit 1

        if [[ ! -s "${TMP}" ]]; then
            log_error "Downloaded file ${URL} is empty; refusing to install."
            log_support_hint
            exit 1
        fi

        # Never install an unverified binary. Bail if the published .sha256 is
        # missing, malformed, or does not match the download.

        log_debug "Verifying checksum..."
        if ! download_with_retry "${DOWNLOADER}" "${URL}.sha256" "${SUMTMP}"; then
            log_error "Failed to download checksum file ${URL}.sha256."
            log_error "Refusing to install without verification."
            log_support_hint
            exit 1
        fi

        # GNU sha256sum format is "<digest>  <filename>\n". Take field 1.
        EXPECTED="$(awk '{print tolower($1); exit}' "${SUMTMP}")"
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
        if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
            log_error "Checksum mismatch for ${ASSET}:"
            log_error "  expected: ${EXPECTED}"
            log_error "  actual:   ${ACTUAL}"
            log_error "Refusing to install a binary that doesn't match its published checksum."
            log_support_hint
            exit 1
        fi

        chmod +x "${TMP}"
        log_debug "Verifying the downloaded binary runs..."
        if ! "${TMP}" --help >/dev/null 2>&1; then
            log_error "The downloaded binary failed to run; refusing to activate it."
            log_error "Leaving ${EXE} unchanged so your existing clor still works."
            log_support_hint
            exit 1
        fi
        mv -f "${TMP}" "${VERSIONED_EXE}"
        rm -f "${SUMTMP}"

        # Create the new link beside the active one, then rename(2) it over the
        # active path. If link creation or the rename fails, the old link stays
        # in place and the EXIT trap removes the temporary link.

        TMP="${EXE}.tmp.$$"
        ln -s "${VERSIONED_EXE}" "${TMP}"
        mv -f "${TMP}" "${EXE}"
        trap - EXIT
        log_debug "Linked ${EXE} -> ${VERSIONED_EXE}"
    else
        log_debug "Clor ${VERSION} is already active; skipping the binary download."
    fi

    # Add ~/.local/bin to PATH for the user's shell when missing. fish uses
    # its universal path; bash and zsh get a marked rc line so re-runs do
    # not duplicate it.

    path_configured="false"
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*)
            ;;
        *)
            shell_name="$(basename "${SHELL:-}")"
            modified=""
            case "${shell_name}" in
                fish)
                    if command -v fish >/dev/null 2>&1; then
                        # fish, not bash, expands $argv in this command.
                        # shellcheck disable=SC2016
                        if fish -c 'fish_add_path -U $argv[1]' "${INSTALL_DIR}" >/dev/null 2>&1; then
                            modified="(fish universal path)"
                        fi
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
                            path_configured="true"
                            continue
                        fi
                        printf '\n%s\n%s\n' "${RC_MARKER}" "${PATH_LINE}" >> "${rc}"
                        modified="${rc}"
                        path_configured="true"
                    done
                    ;;
            esac
            if [[ -n "${modified}" ]]; then
                log_info "Added ${INSTALL_DIR} to PATH in ${modified}."
                log_info "Open a new shell (or 'source' the file) to pick it up."
            elif [[ "${path_configured}" == "false" ]]; then
                log_info "warning: ${INSTALL_DIR} is not on PATH and no rc file was found to update."
                log_info "Append this line to your shell config manually:"
                log_info "  ${PATH_LINE}"
            fi
            ;;
    esac

    # Configure automatic updates after the binary install decision. Scheduler
    # failures never make CLI setup fail.
    configure_autoupdate "${OS}"

    # With a terminal available, continue setup: sign in, then register the
    # daemon service and plugin via `clor install`. CLOR_INSTALL_FROM_CLI=1
    # means `clor install` invoked this script and runs those steps itself.
    # Without a terminal (CI, Dockerfiles), stop after installing the
    # binary and print the next command.

    if [[ "${CLOR_INSTALL_FROM_CLI:-}" != "1" ]]; then
        if [[ -t 1 && -r /dev/tty ]]; then
            "${EXE}" account login --wait </dev/tty || true
            CLOR_INSTALL_FORCE="false" "${EXE}" install </dev/tty
        else
            log_info ""
            log_info "Installed clor to ${EXE}."
            log_info "To finish setup, run:"
            log_info ""
            log_info "    clor install"
            log_info ""
        fi
    fi
}

main "$@"
