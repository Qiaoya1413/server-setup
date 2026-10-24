#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { echo "错误：$*" >&2; exit 1; }

parse_selection() {
    local input="${1//,/ }" item
    selected=()
    aria2_dependency=0
    read -r -a selected <<< "$input"
    [[ ${#selected[@]} -gt 0 ]] || return 1
    if [[ ${#selected[@]} == 1 && ${selected[0]} == a ]]; then
        selected=(1 2 3 4 5)
    fi
    for item in "${selected[@]}"; do
        [[ $item =~ ^[1-5]$ ]] || return 1
    done
    if [[ " ${selected[*]} " == *' 2 '* && " ${selected[*]} " != *' 4 '* ]]; then
        selected+=(4)
        aria2_dependency=1
    fi
}

repair_apt_sources() (
    local apt_dir="${1:-/etc/apt}" work file backup
    [[ ${ID:-} == debian && ${VERSION_CODENAME:-} == bullseye ]] || return 0
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    for file in "$apt_dir/sources.list" "$apt_dir/sources.list.d/"*.list; do
        [[ -f $file ]] || continue
        # Bullseye 安全更新已归档；索引仍可能命中，但原站的软件包已被移走。
        awk '
            /^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?https?:\/\/(deb|ftp)\.debian\.org\/debian\/?[[:space:]]+bullseye-backports([[:space:]]|$)/ {
                print "# server-setup: disabled retired backports: " $0
                next
            }
            /^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?https?:\/\/(security\.debian\.org\/debian-security|deb\.debian\.org\/debian-security|mirror\.hetzner\.com\/debian\/security)\/?[[:space:]]+bullseye-security([[:space:]]|$)/ {
                sub(/https?:\/\/[^[:space:]]+/, "https://archive.debian.org/debian-security")
            }
            { print }
        ' "$file" > "$work/sources"
        cmp -s "$file" "$work/sources" && continue
        backup="$(mktemp --suffix=.save "${file}.server-setup-backup.XXXXXX")"
        cp -p -- "$file" "$backup"
        cat "$work/sources" > "$file"
        echo "已修复退役的 Bullseye APT 条目；原文件备份：$backup"
    done
)

install_packages() {
    local package missing=()
    repair_apt_sources
    for package in "$@"; do
        if [[ $(dpkg-query -W -f='${Status}' -- "$package" 2>/dev/null) != 'install ok installed' ]]; then
            missing+=("$package")
        fi
    done
    if [[ ${#missing[@]} == 0 ]]; then
        echo '所需系统依赖已安装，跳过重复安装。'
        return 0
    fi
    apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update || fail 'APT 更新失败，已停止安装；请检查上方报错中的软件源，脚本不会绕过签名校验。'
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" || fail '系统依赖安装失败，已停止当前步骤。'
}

# 每次使用独立目录；下载失败不会执行旧文件或不完整的脚本。
run_remote() (
    local url="$1" name="$2" fallback="${3:-}" work
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    cd "$work"
    if ! curl -fLsS --connect-timeout 20 --max-time 180 "$url" -o "$name"; then
        [[ -n $fallback ]] || fail "下载失败：$url"
        curl -fLsS --connect-timeout 20 --max-time 180 "$fallback" -o "$name"
    fi
    [[ -s $name ]] || fail "下载内容为空"
    bash -n "$name"
    chmod +x "$name"
    bash "./$name"
)

install_aria2() {
    if [[ ${1:-} == --if-missing ]] && command -v aria2c >/dev/null 2>&1; then
        echo 'Aria2 已安装，复用现有配置，跳过安装及管理菜单。'
        return 0
    fi
    run_remote https://git.io/aria2.sh aria2.sh https://raw.githubusercontent.com/P3TERX/aria2.sh/master/aria2.sh
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo 'Docker 和 Compose 已就绪，跳过安装及服务变更。'
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        run_remote https://get.docker.com get-docker.sh
    fi
    if ! docker compose version >/dev/null 2>&1; then
        install_packages docker-compose-plugin
    fi
    systemctl enable --now docker
    docker info >/dev/null
    docker compose version
}

install_fonts() {
    local destination="$1" answer source name
    read -r -p '是否导入微软雅黑字体？[y/N] ' answer
    [[ $answer == y || $answer == Y ]] || return 0
    read -r -p '已上传的授权字体所在目录（包含 msyh.ttc、msyhbd.ttc、msyhl.ttc）：' source
    [[ -n $source && -d $source ]] || fail '字体目录不存在'
    for name in msyh.ttc msyhbd.ttc msyhl.ttc; do
        [[ -s $source/$name ]] || fail "缺少字体：$name"
        if [[ -e $destination/$name ]]; then
            cmp -s "$source/$name" "$destination/$name" || fail "已有不同字体，不覆盖：$destination/$name"
        fi
    done
    mkdir -p "$destination"
    for name in msyh.ttc msyhbd.ttc msyhl.ttc; do
        if [[ ! -e $destination/$name ]]; then
            install -m 644 "$source/$name" "$destination/$name"
        fi
    done
}

prepare_config() {
    python3 - "$1" "$2" <<'PY'
import getpass
import json
import os
from pathlib import Path
import posixpath
import secrets
import sys

project = Path(sys.argv[1])
target = project / "config.json"
if target.exists():
    print("保留已有 config.json；部署脚本会校验配置。")
    raise SystemExit(0)
config = json.loads((project / "config.example.json").read_text(encoding="utf-8"))
# 按 Aria2 配置格式逐行读取，不把配置当作 Shell 执行。
options = {}
for line in Path(sys.argv[2]).read_text(encoding="utf-8-sig").splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        options[key.strip()] = value.strip()
download_dir = posixpath.normpath(options.get("dir", ""))
if not download_dir.startswith("/") or download_dir in ("/", "/root", "/etc", "/usr", "/var", "/bin", "/sbin", "/lib") or download_dir == "/app" or download_dir.startswith("/app/"):
    raise SystemExit("Aria2 dir 必须为独立的绝对下载目录，不能挂载系统或应用目录。")
secret = options.get("rpc-secret", "")
if not secret:
    raise SystemExit("Aria2 缺少 rpc-secret，请先设置 RPC 密钥。")
port = options.get("rpc-listen-port", "6800")
if not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535:
    raise SystemExit("Aria2 RPC 端口无效。")
if options.get("enable-rpc", "false") != "true" or options.get("rpc-listen-all", "false") != "true":
    raise SystemExit("请先在 Aria2 中启用 enable-rpc=true 和 rpc-listen-all=true，并重启服务，以供容器访问。")
if options.get("rpc-secure", "false") != "false":
    raise SystemExit("当前自动配置仅支持本机 HTTP RPC；HTTPS RPC 请手动配置。")
config.update(host_download_dir=download_dir, aria2_secret=secret,
              aria2_rpc_url=f"http://host.docker.internal:{int(port)}/jsonrpc")
print("已读取 Aria2 下载目录与 RPC 配置（密钥不显示）。")
with open("/dev/tty", "r+") as tty:
    sys.stdin = tty
    for key, label, default, hidden in (
        ("app_password", "应用登录密码", "", True),
        ("openlist_url", "OpenList 地址（容器访问宿主机）", "http://host.docker.internal:5244", False),
        ("openlist_username", "OpenList 用户名", "admin", False),
        ("openlist_password", "OpenList 密码", "", True),
    ):
        while True:
            prompt = label + (f" [{default}]" if default else "") + ": "
            value = getpass.getpass(prompt, stream=tty) if hidden else input(prompt)
            value = value or default
            if value.strip():
                config[key] = value
                break
            print("此项不能为空。")
config["secret_key"] = secrets.token_hex(32)
# x 模式保证即使检查后文件才出现，也不会覆盖已有配置。
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    json.dump(config, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY
}

github_repo_name() {
    local address="${1%.git}"
    case "$address" in
        https://github.com/*) address="${address#https://github.com/}" ;;
        git@github.com:*) address="${address#git@github.com:}" ;;
        *) return 1 ;;
    esac
    [[ $address =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s\n' "${address,,}"
}

install_private_app() (
    local repo repo_name existing_repo project answer manifest override aria_config download_dir running
    aria_config=/root/.aria2c/aria2.conf
    if [[ ! -s $aria_config ]]; then
        read -r -p '未找到默认 Aria2 配置，请输入实际 aria2.conf 的绝对路径：' aria_config
    fi
    [[ $aria_config == /* && -s $aria_config ]] || fail '缺少 Aria2 配置，请先完成 Aria2 安装'
    install_docker
    install_packages git python3
    read -r -p '私有仓库地址（HTTPS 或 git@github.com:用户名/仓库.git；不要包含 Token）：' repo
    repo_name="$(github_repo_name "$repo")" || fail '请输入不含凭据的 GitHub HTTPS 或 SSH 仓库地址'
    if [[ $repo == git@github.com:* ]]; then
        install_packages openssh-client
    fi
    read -r -p '安装目录 [/hash/private-app]：' project
    project="${project:-/hash/private-app}"
    [[ $project == /* && $project != / && $project != *:* ]] || fail '安装目录必须为绝对路径，不能为根目录或包含冒号'
    if [[ -e $project ]]; then
        [[ -d $project/.git ]] || fail '目录已存在且不是 Git 仓库，拒绝覆盖'
        existing_repo="$(git -C "$project" remote get-url origin)"
        [[ $(github_repo_name "$existing_repo") == "$repo_name" ]] || fail '已有目录的仓库地址不一致，拒绝覆盖'
        echo '保留已有代码和数据，不自动拉取或重置。'
    else
        if [[ $repo == git@github.com:* ]]; then
            echo '使用服务器现有 SSH 密钥；请先将公钥添加为该仓库的只读 Deploy key。'
        else
            echo 'Git 用户名输入 GitHub 用户名；Password 必须输入 Token，GitHub 不接受账号登录密码。'
        fi
        if ! git -c credential.helper= clone --depth 1 -- "$repo" "$project"; then
            if [[ $repo == git@github.com:* ]]; then
                fail 'SSH 克隆失败，请检查服务器公钥是否已授权给该仓库，以及 SSH 连接是否可用。'
            fi
            fail 'HTTPS 克隆失败；若为认证错误，请使用有该私库只读权限的 Token，或改用 SSH 地址。'
        fi
    fi
    cd "$project"
    [[ -f deploy.sh && -f docker-compose.yml && -f config.example.json ]] || fail '该安装项需要 deploy.sh、docker-compose.yml 和 config.example.json'
    running="$(docker compose -f docker-compose.yml ps --status running --quiet)"
    if [[ -n $running ]]; then
        echo '私有应用已在运行，跳过重复部署，保留现有配置及数据。'
        return 0
    fi
    echo '继续会执行该私库的 deploy.sh；请仅使用你信任的仓库。'
    read -r -p '继续部署？[y/N] ' answer
    [[ $answer == y || $answer == Y ]] || { echo '已取消部署。'; return 0; }
    prepare_config "$project" "$aria_config"
    install_fonts "$project/fonts"
    manifest="$(mktemp)"
    trap 'rm -f -- "$manifest"' EXIT
    docker compose -f docker-compose.yml config --format json > "$manifest"
    override="$project/compose.install.json"
    # 从私库配置读取服务名、端口和外部网络，不在公开脚本中记录私库信息。
    python3 - "$manifest" "$override" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

config = json.loads(Path(sys.argv[1]).read_text())
services = config["services"]
if len(services) != 1:
    raise SystemExit("此安装项仅支持单服务 Compose 项目。")
name, service = next(iter(services.items()))
target = Path(sys.argv[2])
app_config = json.loads((target.parent / "config.json").read_text(encoding="utf-8"))
download_dir = app_config["host_download_dir"]
local_service = {}
volumes = service.get("volumes", [])
download_targets = {"/downloads", "/hash/download"}
local_service["volumes"] = [
    {"type": "bind", "source": download_dir, "target": volume["target"], "read_only": False}
    for volume in volumes if volume.get("type") == "bind" and volume["target"] in download_targets
]
# 保留容器内原有目录，同时提供同路径挂载，供 Aria2 返回的绝对文件路径使用。
if download_dir not in download_targets:
    for volume in volumes:
        mounted = volume["target"].rstrip("/")
        if download_dir == mounted or download_dir.startswith(mounted + "/") or mounted.startswith(download_dir.rstrip("/") + "/"):
            raise SystemExit("下载目录与现有容器挂载冲突，拒绝自动部署。")
    local_service["volumes"].append({"type": "bind", "source": download_dir, "target": download_dir, "read_only": False})
if not service.get("ports"):
    exposed = service.get("expose", [])
    if len(exposed) != 1 or not str(exposed[0]).isdigit():
        raise SystemExit("需要在 Compose 中声明唯一 expose 端口，或自行配置 ports。")
    port = int(exposed[0])
    local_service["ports"] = [f"127.0.0.1:{port}:{port}"]
if not target.exists():
    with target.open("x", encoding="utf-8") as stream:
        json.dump({"services": {name: local_service}}, stream)
else:
    print("保留已有 Compose 覆盖配置，请确认其中的下载目录挂载与应用配置一致。")
for network in config.get("networks", {}).values():
    if network.get("external"):
        network_name = network["name"]
        result = subprocess.run(["docker", "network", "inspect", network_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            subprocess.run(["docker", "network", "create", network_name], check=True)
PY
    export COMPOSE_FILE="$project/docker-compose.yml"
    if [[ -f $override ]]; then
        COMPOSE_FILE+=":$override"
    fi
    APP_PASSWORD="$(python3 -c 'import json; print(json.load(open("config.json"))["app_password"])')"
    FLASK_SECRET_KEY="$(python3 -c 'import json; print(json.load(open("config.json"))["secret_key"])')"
    export APP_PASSWORD FLASK_SECRET_KEY
    download_dir="$(python3 -c 'import json; print(json.load(open("config.json"))["host_download_dir"])')"
    mkdir -p -- "$download_dir/Sub/ASS-to-SUP"
    bash ./deploy.sh
    echo '私有应用已部署；新增的访问端口仅绑定 127.0.0.1，可使用 SSH 隧道或自行配置反向代理。'
)

run_action() {
    case "$1" in
        1) install_docker ;;
        2) install_private_app ;;
        3) run_remote https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh tcpx.sh ;;
        4)
            if [[ ${aria2_dependency:-0} == 1 ]]; then
                install_aria2 --if-missing
            else
                install_aria2
            fi
            ;;
        5) run_remote https://res.oplist.org/script/v4.sh install-openlist-v4.sh ;;
        *) fail '未知安装项' ;;
    esac
}

run_selected() {
    local id status failures=0 aria2_failed=0
    # 基础服务在前，私有应用随后，可能重启的网络/内核工具最后。
    for id in 1 4 5 2 3; do
        [[ " ${selected[*]} " == *" $id "* ]] || continue
        if [[ $id == 2 && $aria2_failed == 1 ]]; then
            echo 'Aria2 安装失败，跳过依赖它的私有应用。' >&2
            failures=$((failures + 1))
            continue
        fi
        echo "========== 开始第 $id 项 =========="
        # 不把函数放进 if/||，否则 Bash 会禁用函数内部的 errexit。
        set +e
        (set -e; run_action "$id")
        status=$?
        set -e
        if (( status == 0 )); then
            echo "第 $id 项执行结束。"
        else
            if [[ $id == 4 ]]; then aria2_failed=1; fi
            echo "第 $id 项失败（退出码 $status），继续其他选中项。" >&2
            failures=$((failures + 1))
        fi
    done
    (( failures == 0 ))
}

main() {
    local input
    [[ $EUID == 0 ]] || fail '请使用 root 或 sudo bash 运行'
    [[ -r /etc/os-release ]] || fail '无法识别操作系统'
    . /etc/os-release
    case "$ID" in
        debian|ubuntu) ;;
        *) fail '当前仅支持 Debian / Ubuntu，未执行安装' ;;
    esac
    [[ -d /run/systemd/system ]] || fail '需要使用 systemd 的完整服务器系统'
    [[ -t 0 ]] || exec </dev/tty
    cat <<'MENU'
1. Docker + Docker Compose 插件
2. 私有应用（复用已安装依赖，缺失时先装 Aria2；可选导入微软雅黑）
3. TCP/BBR/内核调优（可能重启，最后执行）
4. Aria2
5. OpenList v4
a. 全选
0. 退出
单选输入 1，多选输入 1 2 4 或 1,2,4。
Aria2/OpenList/调优工具会进入各自的交互菜单，退出后继续下一项。
私有应用自动读取 Aria2 下载目录；OpenList 本地存储请选择同一目录。
MENU
    while true; do
        read -r -p '请选择：' input || return 0
        [[ $input != 0 ]] || return 0
        if parse_selection "$input"; then break; fi
        echo '输入无效，请使用 1–5 的编号（空格或逗号分隔），或 a / 0。'
    done
    echo "已选择：${selected[*]}；执行顺序：1 → 4 → 5 → 2 → 3（仅执行选中项）。"
    read -r -p '开始安装？[y/N] ' input
    [[ $input == y || $input == Y ]] || return 0
    install_packages ca-certificates curl wget
    run_selected
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
