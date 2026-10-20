#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { echo "错误：$*" >&2; exit 1; }

parse_selection() {
    local input="${1//,/ }" item
    selected=()
    read -r -a selected <<< "$input"
    [[ ${#selected[@]} -gt 0 ]] || return 1
    if [[ ${#selected[@]} == 1 && ${selected[0]} == a ]]; then
        selected=(1 2 3 4 5)
    fi
    for item in "${selected[@]}"; do
        [[ $item =~ ^[1-5]$ ]] || return 1
    done
}

install_packages() {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
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

install_docker() {
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
    python3 - "$1" <<'PY'
import getpass
import json
import os
from pathlib import Path
import secrets
import sys

project = Path(sys.argv[1])
target = project / "config.json"
if target.exists():
    print("保留已有 config.json；部署脚本会校验配置。")
    raise SystemExit(0)
config = json.loads((project / "config.example.json").read_text(encoding="utf-8"))
with open("/dev/tty", "r+") as tty:
    sys.stdin = tty
    for key, label, default, hidden in (
        ("app_password", "应用登录密码", "", True),
        ("openlist_url", "OpenList 地址（容器访问宿主机）", "http://host.docker.internal:5244", False),
        ("openlist_username", "OpenList 用户名", "admin", False),
        ("openlist_password", "OpenList 密码", "", True),
        ("aria2_rpc_url", "Aria2 RPC 地址", "http://host.docker.internal:6800/jsonrpc", False),
        ("aria2_secret", "Aria2 RPC 密钥", "", True),
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

install_private_app() (
    local repo project answer manifest override
    install_docker
    install_packages git python3
    read -r -p '私有仓库地址（https://github.com/用户名/仓库.git，不要包含 Token）：' repo
    [[ $repo =~ ^https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] || fail '请输入不含凭据的 GitHub HTTPS 仓库地址'
    read -r -p '安装目录 [/hash/private-app]：' project
    project="${project:-/hash/private-app}"
    [[ $project == /* && $project != / && $project != *:* ]] || fail '安装目录必须为绝对路径，不能为根目录或包含冒号'
    if [[ -e $project ]]; then
        [[ -d $project/.git ]] || fail '目录已存在且不是 Git 仓库，拒绝覆盖'
        [[ $(git -C "$project" remote get-url origin) == "$repo" ]] || fail '已有目录的仓库地址不一致，拒绝覆盖'
        echo '保留已有代码和数据，不自动拉取或重置。'
    else
        echo 'Git 用户名输入 GitHub 用户名，Password 输入有该私库只读权限的 Token。'
        git -c credential.helper= clone --depth 1 -- "$repo" "$project"
    fi
    cd "$project"
    [[ -f deploy.sh && -f docker-compose.yml && -f config.example.json ]] || fail '该安装项需要 deploy.sh、docker-compose.yml 和 config.example.json'
    echo '继续会执行该私库的 deploy.sh；请仅使用你信任的仓库。'
    read -r -p '继续部署？[y/N] ' answer
    [[ $answer == y || $answer == Y ]] || { echo '已取消部署。'; return 0; }
    prepare_config "$project"
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
if not service.get("ports"):
    exposed = service.get("expose", [])
    if len(exposed) != 1 or not str(exposed[0]).isdigit():
        raise SystemExit("需要在 Compose 中声明唯一 expose 端口，或自行配置 ports。")
    port = int(exposed[0])
    target = Path(sys.argv[2])
    if not target.exists():
        with target.open("x", encoding="utf-8") as stream:
            json.dump({"services": {name: {"ports": [f"127.0.0.1:{port}:{port}"]}}}, stream)
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
    bash ./deploy.sh
    echo '私有应用已部署；新增的访问端口仅绑定 127.0.0.1，可使用 SSH 隧道或自行配置反向代理。'
)

run_action() {
    case "$1" in
        1) install_docker ;;
        2) install_private_app ;;
        3) run_remote https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh tcpx.sh ;;
        4) run_remote https://git.io/aria2.sh aria2.sh https://raw.githubusercontent.com/P3TERX/aria2.sh/master/aria2.sh ;;
        5) run_remote https://res.oplist.org/script/v4.sh install-openlist-v4.sh ;;
        *) fail '未知安装项' ;;
    esac
}

run_selected() {
    local id status failures=0
    # 基础服务在前，私有应用随后，可能重启的网络/内核工具最后。
    for id in 1 4 5 2 3; do
        [[ " ${selected[*]} " == *" $id "* ]] || continue
        echo "========== 开始第 $id 项 =========="
        # 不把函数放进 if/||，否则 Bash 会禁用函数内部的 errexit。
        set +e
        (set -e; run_action "$id")
        status=$?
        set -e
        if (( status == 0 )); then
            echo "第 $id 项执行结束。"
        else
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
2. 私有应用（自动检查 Docker；可选导入微软雅黑）
3. TCP/BBR/内核调优（可能重启，最后执行）
4. Aria2
5. OpenList v4
a. 全选
0. 退出
单选输入 1，多选输入 1 2 4 或 1,2,4。
Aria2/OpenList/调优工具会进入各自的交互菜单，退出后继续下一项。
若要配合私有应用使用，Aria2 下载目录请设为 /hash/download，
并在 OpenList 中添加指向 /hash/download 的本地存储。
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
