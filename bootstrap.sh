#!/usr/bin/env bash
set -Eeuo pipefail
set +x
ulimit -c 0 2>/dev/null || true

readonly DEFAULT_REPOSITORY='baispig/ks'
readonly DEFAULT_REF='v0.6.0'
readonly DEFAULT_SOURCE_ROOT='/opt/kxsw-source'

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log_info() {
    printf '%b[信息]%b %s\n' "$yellow" "$plain" "$*"
}

log_success() {
    printf '%b[成功]%b %s\n' "$green" "$plain" "$*"
}

die() {
    printf '%b[错误]%b %s\n' "$red" "$plain" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
KXSW 私有仓库引导安装器

用法：
  sudo bash bootstrap.sh [选项]

选项：
  --ref REF        安装指定版本；支持 main 或 vX.Y.Z，默认 v0.6.0
  --repo 仓库     GitHub 仓库，格式为 所有者/仓库，默认 baispig/ks
  --update         重新拉取所选版本并更新 KXSW
  -h, --help       显示帮助

Token 会在当前终端中明文显示并再次确认，但不会写入 Git URL、
.git/config 或持久凭据文件。请勿在录屏、直播或共享终端中操作。
EOF
}

repository=$DEFAULT_REPOSITORY
requested_ref=$DEFAULT_REF
update_mode=0

parse_args() {
    repository=$DEFAULT_REPOSITORY
    requested_ref=$DEFAULT_REF
    update_mode=0
    while (($# > 0)); do
        case "$1" in
            --repo)
                (($# >= 2)) || die '--repo 缺少仓库参数。'
                repository=$2
                shift 2
                ;;
            --ref)
                (($# >= 2)) || die '--ref 缺少版本参数。'
                requested_ref=$2
                shift 2
                ;;
            --update)
                update_mode=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die "不支持的位置参数：$1"
                ;;
            *)
                die "未知选项：$1"
                ;;
        esac
    done
    [[ $repository =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ && $repository != *..* ]] || \
        die '仓库格式无效，应为：所有者/仓库。'
    [[ $requested_ref == main || $requested_ref =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '版本只允许 main 或 vX.Y.Z。'
}

install_git_dependencies() {
    local ca_bundle
    if command -v git >/dev/null 2>&1; then
        for ca_bundle in \
            /etc/ssl/certs/ca-certificates.crt \
            /etc/pki/tls/certs/ca-bundle.crt \
            /var/lib/ca-certificates/ca-bundle.pem \
            /etc/ssl/cert.pem; do
            [[ -s $ca_bundle ]] && return 0
        done
    fi
    [[ -r /etc/os-release ]] || die '无法识别操作系统，且当前没有安装 Git。'

    local os_id os_like
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id=${ID:-}
    os_like=${ID_LIKE:-}
    log_info '正在安装 Git 和 CA 证书...'
    case " $os_id $os_like " in
        *' ubuntu '* | *' debian '*)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates
            ;;
        *' opensuse '* | *' suse '*)
            zypper --non-interactive install git ca-certificates
            ;;
        *' centos '* | *' rhel '* | *' fedora '*)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y git ca-certificates
            elif command -v yum >/dev/null 2>&1; then
                yum install -y git ca-certificates
            else
                die '当前系统缺少 dnf/yum，无法自动安装 Git。'
            fi
            ;;
        *)
            die "不支持为当前系统自动安装 Git：${PRETTY_NAME:-$os_id}。"
            ;;
    esac
    command -v git >/dev/null 2>&1 || die 'Git 安装失败。'
}

prompt_and_clone() (
    set -Eeuo pipefail
    set +x
    ulimit -c 0 2>/dev/null || true

    local destination=$1
    local input_fd=$2
    local output_fd=$3
    local git_binary=$4
    local clean_url="https://github.com/${repository}.git"
    local exact_ref token answer auth_dir askpass saved_url forbidden_config
    auth_dir=
    askpass=

    cleanup_auth() {
        local status=$?
        trap - EXIT INT TERM HUP
        token=
        answer=
        unset token answer KXSW_GITHUB_TOKEN
        [[ -n $auth_dir ]] && rm -rf -- "$auth_dir"
        exit "$status"
    }
    trap cleanup_auth EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    auth_dir=$(mktemp -d "${TMPDIR:-/tmp}/kxsw-auth.XXXXXX")
    chmod 700 "$auth_dir"
    askpass="$auth_dir/askpass.sh"

    cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    *Username*) printf '%s\n' 'x-access-token' ;;
    *Password*) printf '%s\n' "${KXSW_GITHUB_TOKEN:?}" ;;
    *) exit 1 ;;
esac
EOF
    chmod 700 "$askpass"
    mkdir -m 700 "$auth_dir/home" "$auth_dir/config"

    printf '请输入 GitHub Fine-grained Token（输入内容会显示）：' >&"$output_fd"
    IFS= read -r -u "$input_fd" token || die '读取 Token 失败。'
    printf '你输入的 Token：%s\n' "$token" >&"$output_fd"
    printf '确认使用以上 Token？[y/N]：' >&"$output_fd"
    IFS= read -r -u "$input_fd" answer || die '读取确认失败。'

    [[ -n $token ]] || die 'Token 不能为空。'
    [[ $token == github_pat_* ]] || die '只接受以 github_pat_ 开头的 Fine-grained Token。'
    [[ $answer == y || $answer == Y ]] || die '已取消，未访问私有仓库。'

    local environment_variable
    while IFS= read -r environment_variable; do
        case $environment_variable in
            GIT_* | LD_* | DYLD_* | BASH_ENV | ENV | CDPATH)
                unset "$environment_variable"
                ;;
        esac
    done < <(compgen -A variable)
    export HOME="$auth_dir/home"
    export XDG_CONFIG_HOME="$auth_dir/config"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS="$askpass"
    export KXSW_GITHUB_TOKEN=$token

    secure_git() {
        "$git_binary" -c credential.helper= -c core.hooksPath=/dev/null "$@"
    }

    if [[ $requested_ref == main ]]; then
        exact_ref='refs/heads/main'
    else
        exact_ref="refs/tags/${requested_ref}"
    fi

    log_info "正在从私有仓库读取 ${repository}（${requested_ref}）..."
    secure_git -c init.templateDir= init --quiet "$destination"
    secure_git -C "$destination" remote add origin "$clean_url"
    if ! secure_git -C "$destination" fetch --quiet --depth 1 origin "$exact_ref"; then
        die '私有仓库拉取失败。请检查 Token、仓库权限、版本和网络。'
    fi
    secure_git -C "$destination" checkout --quiet --detach FETCH_HEAD

    saved_url=$(secure_git -C "$destination" remote get-url origin)
    [[ $saved_url == "$clean_url" ]] || die 'Git 远程地址校验失败。'
    forbidden_config=$(secure_git -C "$destination" config --local --get-regexp \
        '^(credential\.|http\..*extraheader)' 2>/dev/null || true)
    [[ -z $forbidden_config ]] || die '安全检查失败：Git 配置中发现持久认证设置。'
    saved_url=
    forbidden_config=
)

run_bootstrap() (
    set -Eeuo pipefail
    local source_root=$1
    local input_fd=$2
    local output_fd=$3
    local source_parent staging_root old_root commit git_binary
    local source_swapped=0
    local install_finished=0

    [[ $source_root == /* ]] || die '源码目录必须是绝对路径。'
    install_git_dependencies
    git_binary=$(command -v git)
    [[ -x $git_binary ]] || die '无法定位 Git 可执行文件。'

    source_parent=$(dirname -- "$source_root")
    mkdir -p "$source_parent"
    chmod go-w "$source_parent"
    staging_root=$(mktemp -d "${source_parent}/.kxsw-source.new.XXXXXX")
    old_root="${source_root}.old.$$"

    cleanup_staging() {
        local status=$?
        trap - EXIT INT TERM HUP
        if ((install_finished == 0)); then
            rm -rf -- "$staging_root"
            if ((source_swapped == 1)); then
                rm -rf -- "$source_root"
                [[ -e $old_root ]] && mv -- "$old_root" "$source_root"
            fi
        fi
        rm -rf -- "$old_root"
        exit "$status"
    }
    trap cleanup_staging EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    prompt_and_clone "$staging_root" "$input_fd" "$output_fd" "$git_binary"
    chmod -R go-rwx "$staging_root"

    for required in install.sh kxsw gcp-firewall.sh VERSION lib modules platforms templates; do
        [[ -e "$staging_root/$required" ]] || die "私有仓库内容不完整，缺少：$required"
    done

    commit=$(env -i PATH="$PATH" HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 \
        "$git_binary" -C "$staging_root" rev-parse --verify HEAD)
    log_info "已拉取提交：$commit"
    log_info '临时 GitHub 认证材料已清理，开始安装 KXSW。'

    rm -rf -- "$old_root"
    if [[ -e $source_root ]]; then
        mv -- "$source_root" "$old_root"
    fi
    source_swapped=1
    mv -- "$staging_root" "$source_root"
    bash "$source_root/install.sh"

    install_finished=1
    rm -rf -- "$old_root"
    if ((update_mode == 1)); then
        log_success "KXSW 已从 ${repository} 更新到 ${requested_ref}。"
    else
        log_success "KXSW 已从 ${repository} 安装，源码保存在 ${source_root}。"
    fi
    printf '运行以下命令打开中文管理菜单：\n  kxsw\n'
)

main() {
    local tty_input tty_output
    parse_args "$@"
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 用户运行，或执行：sudo bash bootstrap.sh'
    [[ -r /dev/tty && -w /dev/tty ]] || die '当前没有可用终端，无法读取 Token。'
    exec {tty_input}</dev/tty
    exec {tty_output}>/dev/tty
    run_bootstrap "$DEFAULT_SOURCE_ROOT" "$tty_input" "$tty_output"
    exec {tty_input}<&-
    exec {tty_output}>&-
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
