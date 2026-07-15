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
LATEST_VERSION="v1.7.1"
CLOR_VERSION_EXPLICIT="false"
CLOR_AUTOUPDATE_EXPLICIT="false"
[[ "${CLOR_VERSION+x}" == "x" ]] && CLOR_VERSION_EXPLICIT="true"
[[ "${CLOR_AUTOUPDATE+x}" == "x" ]] && CLOR_AUTOUPDATE_EXPLICIT="true"
VERSION="${CLOR_VERSION:-${LATEST_VERSION}}"
CLOR_INSTALL_FORCE="${CLOR_INSTALL_FORCE:-false}"
if [[ "${CLOR_AUTOUPDATE_EXPLICIT}" == "true" ]]; then
    AUTOUPDATE="${CLOR_AUTOUPDATE}"
elif [[ "${CLOR_VERSION_EXPLICIT}" == "true" ]]; then
    AUTOUPDATE="false"
else
    AUTOUPDATE="true"
fi
INSTALL_DIR="${HOME}/.local/bin"
EXE="${INSTALL_DIR}/clor"
VERSIONS_DIR="${HOME}/.local/share/clor"
VERSION_DIR="${VERSIONS_DIR}/${VERSION}"
VERSIONED_EXE="${VERSION_DIR}/clor"
BASE_URL="https://github.com/clorhq/cli/releases/download/${VERSION}"
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

install_systemd_autoupdate() {
    local unit_dir systemctl_scope service timer service_tmp timer_tmp
    local escaped_home escaped_path escaped_exe

    if [[ "$(id -u)" == "0" ]]; then
        unit_dir="/etc/systemd/system"
        systemctl_scope=""
    else
        unit_dir="${HOME}/.config/systemd/user"
        systemctl_scope="--user"
    fi
    service="${unit_dir}/clor-autoupdate.service"
    timer="${unit_dir}/clor-autoupdate.timer"
    service_tmp="${service}.tmp.$$"
    timer_tmp="${timer}.tmp.$$"
    escaped_home="$(systemd_escape "${HOME}")"
    escaped_path="$(systemd_escape "${PATH}")"
    escaped_exe="$(systemd_escape "${EXE}")"

    mkdir -p "${unit_dir}"
    {
        printf '%s\n' \
            '[Unit]' \
            'Description=Update clor when a new stable release is available' \
            '' \
            '[Service]' \
            'Type=oneshot' \
            'Environment=CLOR_AUTOUPDATE_RUN=1' \
            'Environment=CLOR_INSTALL_FORCE=false' \
            "Environment=\"HOME=${escaped_home}\"" \
            "Environment=\"PATH=${escaped_path}\"" \
            "ExecStart=\"${escaped_exe}\" install"
    } > "${service_tmp}"
    {
        printf '%s\n' \
            '[Unit]' \
            'Description=Check hourly for clor updates' \
            '' \
            '[Timer]' \
            'OnCalendar=hourly' \
            'Persistent=true' \
            'Unit=clor-autoupdate.service' \
            '' \
            '[Install]' \
            'WantedBy=timers.target'
    } > "${timer_tmp}"
    chmod 644 "${service_tmp}" "${timer_tmp}"
    mv -f "${service_tmp}" "${service}"
    mv -f "${timer_tmp}" "${timer}"

    if ! command -v systemctl >/dev/null 2>&1; then
        log_info "warning: systemd is unavailable; clor automatic updates were not scheduled."
        return 0
    fi
    if ! systemctl ${systemctl_scope} daemon-reload >/dev/null 2>&1 ||
       ! systemctl ${systemctl_scope} enable --now clor-autoupdate.timer >/dev/null 2>&1; then
        log_info "warning: systemd could not schedule clor automatic updates."
        return 0
    fi
    log_debug "Scheduled hourly clor updates with systemd."
}

remove_systemd_autoupdate() {
    local unit_dir systemctl_scope
    if [[ "$(id -u)" == "0" ]]; then
        unit_dir="/etc/systemd/system"
        systemctl_scope=""
    else
        unit_dir="${HOME}/.config/systemd/user"
        systemctl_scope="--user"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl ${systemctl_scope} disable --now clor-autoupdate.timer >/dev/null 2>&1 || true
        if [[ "${CLOR_AUTOUPDATE_RUN:-}" != "1" ]]; then
            systemctl ${systemctl_scope} stop clor-autoupdate.service >/dev/null 2>&1 || true
        fi
    fi
    rm -f "${unit_dir}/clor-autoupdate.service" "${unit_dir}/clor-autoupdate.timer"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl ${systemctl_scope} daemon-reload >/dev/null 2>&1 || true
        systemctl ${systemctl_scope} reset-failed clor-autoupdate.service >/dev/null 2>&1 || true
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
    local plist plist_tmp log_dir log_file domain
    local escaped_home escaped_path escaped_exe escaped_log
    plist="${HOME}/Library/LaunchAgents/com.clor.autoupdate.plist"
    plist_tmp="${plist}.tmp.$$"
    log_dir="${HOME}/Library/Logs"
    log_file="${log_dir}/clor-autoupdate.log"
    domain="gui/$(id -u)"
    escaped_home="$(xml_escape "${HOME}")"
    escaped_path="$(xml_escape "${PATH}")"
    escaped_exe="$(xml_escape "${EXE}")"
    escaped_log="$(xml_escape "${log_file}")"

    mkdir -p "$(dirname "${plist}")" "${log_dir}"
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
        <key>CLOR_AUTOUPDATE_RUN</key>
        <string>1</string>
        <key>CLOR_INSTALL_FORCE</key>
        <string>false</string>
        <key>HOME</key>
        <string>${escaped_home}</string>
        <key>PATH</key>
        <string>${escaped_path}</string>
    </dict>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>${escaped_log}</string>
    <key>StandardErrorPath</key>
    <string>${escaped_log}</string>
</dict>
</plist>
EOF
    } > "${plist_tmp}"
    chmod 644 "${plist_tmp}"
    mv -f "${plist_tmp}" "${plist}"

    if ! command -v launchctl >/dev/null 2>&1; then
        log_info "warning: launchd is unavailable; clor automatic updates were not scheduled."
        return 0
    fi
    # A loaded job may be the parent of this install. Leave it running; the
    # atomically replaced plist will be used after the next login.
    if launchctl print "${domain}/com.clor.autoupdate" >/dev/null 2>&1; then
        log_debug "Hourly clor updates are already scheduled with launchd."
        return 0
    fi
    if ! launchctl bootstrap "${domain}" "${plist}" >/dev/null 2>&1; then
        log_info "warning: launchd could not schedule clor automatic updates."
        return 0
    fi
    log_debug "Scheduled hourly clor updates with launchd."
}

remove_launchd_autoupdate() {
    local plist domain
    plist="${HOME}/Library/LaunchAgents/com.clor.autoupdate.plist"
    domain="gui/$(id -u)"
    if command -v launchctl >/dev/null 2>&1 &&
       launchctl print "${domain}/com.clor.autoupdate" >/dev/null 2>&1; then
        if [[ "${CLOR_AUTOUPDATE_RUN:-}" != "1" ]]; then
            launchctl bootout "${domain}/com.clor.autoupdate" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "${plist}"
}

configure_autoupdate() {
    local os="$1"
    if [[ "${AUTOUPDATE}" == "true" ]]; then
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
    # Remove the helper used by installer versions before hourly updates ran
    # `clor install` directly.
    rm -f "${VERSIONS_DIR}/autoupdate.sh"
}

# Download with retry and backoff: fresh releases sometimes 404 on the CDN
# for a few seconds, and networks drop. Used for both the binary and its
# checksum.

download_with_retry() {
    local url="$1"
    local out="$2"
    local attempt="1"
    local rc delay
    while true; do
        rc="0"
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

# Everything runs inside main() so that a connection drop mid-download
# leaves bash without the final `main "$@"` line and nothing executes.

main() {
    local OS ARCH ASSET URL DOWNLOADER TMP SUMTMP EXPECTED ACTUAL
    local shell_name modified rc current_version skip_binary
    local rcs

    case "${AUTOUPDATE}" in
        true|false) ;;
        *)
            log_error "CLOR_AUTOUPDATE must be 'true' or 'false' (got '${AUTOUPDATE}')."
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

    skip_binary="false"
    if [[ "${CLOR_INSTALL_FORCE}" == "false" && -x "${EXE}" ]]; then
        current_version="$("${EXE}" version 2>/dev/null || true)"
        if [[ "${current_version}" == "${VERSION}" ]]; then
            skip_binary="true"
            log_debug "Clor ${VERSION} is already active; skipping the binary download."
        fi
    fi

    if [[ "${skip_binary}" == "false" ]]; then

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
        download_with_retry "${URL}" "${TMP}" || exit 1

        if [[ ! -s "${TMP}" ]]; then
            log_error "Downloaded file ${URL} is empty; refusing to install."
            log_support_hint
            exit 1
        fi

        # Never install an unverified binary. Bail if the published .sha256 is
        # missing, malformed, or does not match the download.

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

        chmod +x "${TMP}"
        mv -f "${TMP}" "${VERSIONED_EXE}"
        rm -f "${SUMTMP}"
        trap - EXIT

        # Refuse to activate a binary that cannot run --help, and keep the
        # existing install working.

        log_debug "Verifying ${VERSIONED_EXE} --help runs..."
        if ! "${VERSIONED_EXE}" --help >/dev/null 2>&1; then
            log_error "${VERSIONED_EXE} --help did not exit 0; refusing to activate this binary."
            log_error "Leaving ${EXE} unchanged so your existing clor still works."
            log_support_hint
            rm -f "${VERSIONED_EXE}"
            exit 1
        fi

        # Point the symlink at the new version.

        rm -f "${EXE}"
        ln -s "${VERSIONED_EXE}" "${EXE}"
        log_debug "Linked ${EXE} -> ${VERSIONED_EXE}"
    fi

    # Add ~/.local/bin to PATH for the user's shell when missing. fish uses
    # its universal path; bash and zsh get a marked rc line so re-runs do
    # not duplicate it.

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
            "${EXE}" install </dev/tty || true
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
