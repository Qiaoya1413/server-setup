#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./install.sh
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# 修复退役的 backports 和安全源，保留其他源与校验选项，并能回滚。
mkdir -p "$work/apt/sources.list.d"
cat > "$work/apt/sources.list" <<'LIST'
deb http://deb.debian.org/debian bullseye main
deb http://deb.debian.org/debian bullseye-backports main
deb-src [signed-by=/usr/share/keyrings/debian.gpg] https://deb.debian.org/debian/ bullseye-backports main
# deb http://deb.debian.org/debian bullseye-backports main
deb http://mirror.hetzner.com/debian/packages bullseye-backports main
deb http://security.debian.org/debian-security bullseye-security main
deb http://mirror.hetzner.com/debian/security bullseye-security main
deb-src [signed-by=/usr/share/keyrings/debian.gpg] https://deb.debian.org/debian-security/ bullseye-security main contrib
# deb http://security.debian.org/debian-security bullseye-security main
deb https://security.debian.org/debian-security bookworm-security main
deb https://download.docker.com/linux/debian bullseye stable
LIST
cp "$work/apt/sources.list" "$work/original.list"
(
    ID=debian VERSION_CODENAME=bullseye
    repair_apt_sources "$work/apt"
    [[ $(awk '/^# server-setup:/{n++} END{print n+0}' "$work/apt/sources.list") == 2 ]]
    [[ $(cat "$work/apt/sources.list") == *'deb http://mirror.hetzner.com/debian/packages bullseye-backports main'* ]]
    [[ $(cat "$work/apt/sources.list") == *'deb https://download.docker.com/linux/debian bullseye stable'* ]]
    [[ $(awk '/^[^#].*archive.debian.org\/debian-security/{n++} END{print n+0}' "$work/apt/sources.list") == 3 ]]
    [[ $(cat "$work/apt/sources.list") == *'deb-src [signed-by=/usr/share/keyrings/debian.gpg] https://archive.debian.org/debian-security bullseye-security main contrib'* ]]
    [[ $(cat "$work/apt/sources.list") == *'# deb http://security.debian.org/debian-security bullseye-security main'* ]]
    [[ $(cat "$work/apt/sources.list") == *'deb https://security.debian.org/debian-security bookworm-security main'* ]]
    backups=("$work/apt/sources.list".server-setup-backup.*)
    [[ ${#backups[@]} == 1 ]]
    cmp "$work/original.list" "${backups[0]}"
    cp "$work/apt/sources.list" "$work/repaired.list"
    repair_apt_sources "$work/apt"
    cmp "$work/repaired.list" "$work/apt/sources.list"
    backups=("$work/apt/sources.list".server-setup-backup.*)
    [[ ${#backups[@]} == 1 ]]
    cp "$work/original.list" "$work/apt/sources.list.d/untouched.list"
    ID=ubuntu VERSION_CODENAME=noble
    repair_apt_sources "$work/apt"
    cmp "$work/original.list" "$work/apt/sources.list.d/untouched.list"
)

# 模拟依赖安装，不访问真实 APT；未知源失败仍停止，绝不放宽签名检查。
(
    repair_apt_sources() { echo repair >> "$work/apt-order"; }
    dpkg-query() {
        [[ ${*: -1} == curl ]] || return 1
        echo 'install ok installed'
    }
    apt-get() { echo "$*" >> "$work/apt-order"; }
    install_packages curl wget
    [[ $(cat "$work/apt-order") == $'repair\n-o Acquire::Retries=3 -o APT::Update::Error-Mode=any update\ninstall -y --no-install-recommends wget' ]]
    rm "$work/apt-order"
    install_packages curl
    [[ $(cat "$work/apt-order") == repair ]]
    apt-get() { echo "$*" >> "$work/apt-order"; return 100; }
    set +e
    (set -e; install_packages wget) > "$work/apt-error" 2>&1
    status=$?
    set -e
    [[ $status != 0 ]]
    [[ $(cat "$work/apt-order") == $'repair\nrepair\n-o Acquire::Retries=3 -o APT::Update::Error-Mode=any update' ]]
)

parse_selection '2'
[[ ${selected[*]} == '2 4' ]]
[[ $aria2_dependency == 1 ]]
parse_selection '1,2 4,4'
[[ ${selected[*]} == '1 2 4 4' ]]
[[ $aria2_dependency == 0 ]]
parse_selection a
[[ ${selected[*]} == '1 2 3 4 5' ]]
for invalid in '' 0 6 12 '1 two' '1;id' 'a 1'; do
    if parse_selection "$invalid"; then
        fail "错误接受了输入：$invalid"
    fi
done

# 自动依赖复用已有 Aria2；显式选择管理项仍打开菜单，缺失时才安装。
(
    aria2_present=1
    command() {
        if [[ $* == '-v aria2c' ]]; then
            [[ $aria2_present == 1 ]]
        else
            builtin command "$@"
        fi
    }
    run_remote() { echo remote >> "$work/aria2-install"; }
    parse_selection 2
    run_action 4
    [[ ! -e $work/aria2-install ]]
    parse_selection '2 4'
    run_action 4
    [[ $(wc -l < "$work/aria2-install") == 1 ]]
    aria2_present=0
    parse_selection 2
    run_action 4
    [[ $(wc -l < "$work/aria2-install") == 2 ]]
)

# Docker/Compose 已就绪时不调用安装器或更改服务；仅服务未启动时补启动。
(
    docker_ready=1
    command() { [[ $* == '-v docker' ]] || builtin command "$@"; }
    docker() {
        if [[ $* == info ]]; then [[ $docker_ready == 1 ]]; fi
    }
    run_remote() { fail '不应重复安装 Docker'; }
    install_packages() { fail '不应重复安装 Compose'; }
    systemctl() { echo "$*" >> "$work/docker-service"; docker_ready=1; }
    install_docker
    [[ ! -e $work/docker-service ]]
    docker_ready=0
    install_docker
    [[ $(cat "$work/docker-service") == 'enable --now docker' ]]
)

# HTTPS 和 SSH 对应同一仓库；拒绝带密码、Token 或非 GitHub 地址。
[[ $(github_repo_name https://github.com/Example/private.git) == example/private ]]
[[ $(github_repo_name git@github.com:example/Private.git) == example/private ]]
for invalid in 'https://user:secret@github.com/example/private.git' 'git@other.example:example/private.git' 'git@github.com:example/private;id.git' '-bad'; do
    if github_repo_name "$invalid"; then fail '错误接受了仓库地址'; fi
done

# 已运行的私有应用直接跳过，且 HTTPS/SSH 切换不会误判为其他仓库。
(
    mkdir -p "$work/private-app/.git"
    touch "$work/private-app/deploy.sh" "$work/private-app/docker-compose.yml" "$work/private-app/config.example.json"
    echo test > "$work/aria2.conf"
    install_docker() { :; }
    install_packages() { :; }
    git() { echo https://github.com/example/private.git; }
    docker() {
        [[ $* == 'compose -f docker-compose.yml ps --status running --quiet' ]] || fail '不应变更已有应用'
        echo example-running-id
    }
    prepare_config() { fail '不应改写已有应用配置'; }
    install_fonts() { fail '不应改写已有字体'; }
    {
        if [[ ! -s /root/.aria2c/aria2.conf ]]; then echo "$work/aria2.conf"; fi
        echo git@github.com:example/private.git
        echo "$work/private-app"
        echo 0
    } > "$work/private-input"
    settings="$work/local-settings/private-app.conf"
    install_private_app "$settings" < "$work/private-input" > "$work/private-result"
    [[ $(cat "$work/private-result") == *'私有应用已在运行，跳过重复部署'* ]]
    [[ $(cat "$settings") == $'git@github.com:example/private.git\n'"$work/private-app" ]]
    if [[ $OSTYPE != msys* ]]; then
        [[ $(stat -c %a "$settings") == 600 && $(stat -c %a "${settings%/*}") == 700 ]]
    fi
    {
        if [[ ! -s /root/.aria2c/aria2.conf ]]; then echo "$work/aria2.conf"; fi
        printf '\n\n\n'
    } > "$work/reuse-input"
    install_private_app "$settings" < "$work/reuse-input" > "$work/private-result"
    [[ $(cat "$work/private-result") == *'私有应用已在运行，跳过重复部署'* ]]
    # 目录中的空格和 Shell 字符按字面值保存；显式输入可替换旧默认值。
    project="$work/private app \$(touch unexpected)"
    mkdir -p "$project/.git"
    touch "$project/deploy.sh" "$project/docker-compose.yml" "$project/config.example.json"
    {
        if [[ ! -s /root/.aria2c/aria2.conf ]]; then echo "$work/aria2.conf"; fi
        printf '%s\n' https://github.com/example/private.git "$project"
        echo 0
    } > "$work/changed-input"
    install_private_app "$settings" < "$work/changed-input" > /dev/null
    [[ $(cat "$settings") == $'https://github.com/example/private.git\n'"$project" ]]
    install_private_app "$settings" < "$work/reuse-input" > /dev/null
    [[ $(cat "$settings") == $'https://github.com/example/private.git\n'"$project" ]]
    cp "$settings" "$work/settings-before"
    {
        if [[ ! -s /root/.aria2c/aria2.conf ]]; then echo "$work/aria2.conf"; fi
        printf '%s\n' https://github.com/example/private.git relative/path
    } > "$work/invalid-input"
    set +e
    (set -e; install_private_app "$settings" < "$work/invalid-input") > /dev/null 2>&1
    status=$?
    set -e
    [[ $status != 0 ]]
    cmp "$settings" "$work/settings-before"
    printf '%s\n' "\$(touch '$work/unexpected')" /tmp > "$settings"
    install_private_app "$settings" < "$work/private-input" > /dev/null
    [[ ! -e $work/unexpected ]]
    [[ $(cat "$settings") == $'git@github.com:example/private.git\n'"$work/private-app" ]]
    # 已运行时选择直接访问，只应用 Compose，不执行部署脚本或重建镜像。
    docker() {
        case "$*" in
            'compose -f docker-compose.yml ps --status running --quiet') echo example-running-id ;;
            'compose -f docker-compose.yml config --format json') echo '{}' ;;
            'compose up -d --no-build')
                [[ $COMPOSE_FILE == "$work/private-app/docker-compose.yml:$work/private-app/compose.install.json" ]]
                echo "$*" > "$work/access-up" ;;
            'compose ps') ;;
            *) fail '不应构建镜像或执行其他 Docker 操作' ;;
        esac
    }
    python3() {
        if [[ $1 == - ]]; then
            [[ $4 == 2 ]]
            cat >/dev/null
            echo '{}' > "$3"
        else
            [[ $1 == -c ]]
            echo test-only-value
        fi
    }
    bash() { fail '不应重复执行部署脚本'; }
    {
        if [[ ! -s /root/.aria2c/aria2.conf ]]; then echo "$work/aria2.conf"; fi
        printf '%s\n' '' '' 2
    } > "$work/access-input"
    install_private_app "$settings" < "$work/access-input" > "$work/access-result"
    [[ $(cat "$work/access-up") == 'compose up -d --no-build' ]]
    [[ $(cat "$work/access-result") == *'私有应用访问方式已更新，未重新构建镜像。'* ]]
)

# SSH 克隆使用原生 Git/SSH，不关闭服务器身份校验，也不在 URL 中保存凭据。
(
    install_docker() { :; }
    install_packages() { echo "$*" >> "$work/ssh-packages"; }
    git() {
        [[ $* == '-c credential.helper= clone --depth 1 -- git@github.com:example/private.git '* ]] || fail 'SSH 克隆参数错误'
        echo clone >> "$work/ssh-clone"
        mkdir -p "$work/private-ssh-app/.git"
        touch "$work/private-ssh-app/deploy.sh" "$work/private-ssh-app/docker-compose.yml" "$work/private-ssh-app/config.example.json"
    }
    docker() { echo example-running-id; }
    {
        if [[ ! -s /root/.aria2c/aria2.conf ]]; then echo "$work/aria2.conf"; fi
        echo git@github.com:example/private.git
        echo "$work/private-ssh-app"
        echo 0
    } > "$work/ssh-input"
    install_private_app "$work/ssh-settings/private-app.conf" < "$work/ssh-input" > "$work/ssh-result"
    [[ $(cat "$work/ssh-packages") == $'git python3\nopenssh-client' ]]
    [[ $(cat "$work/ssh-clone") == clone ]]
)

# 用假的安装动作检查顺序、去重与失败隔离，不下载、不安装。
fail_aria2=1
run_action() {
    echo "$1" >> "$work/order"
    if [[ $1 == 4 && $fail_aria2 == 1 ]]; then
        false
        echo '不应在失败后继续执行' >> "$work/unexpected"
    fi
}
parse_selection '3,2,1,4,5,4'
set +e
(run_selected) > "$work/result" 2>&1
status=$?
set -e
[[ $status != 0 ]]
[[ $(cat "$work/order") == $'1\n4\n5\n3' ]]
[[ ! -e $work/unexpected ]]
[[ $(cat "$work/result") == *'第 4 项失败'* ]]
[[ $(cat "$work/result") == *'跳过依赖它的私有应用'* ]]
fail_aria2=0
rm -- "$work/order"
parse_selection 2
run_selected > "$work/result" 2>&1
[[ $(cat "$work/order") == $'4\n2' ]]

# 下载失败时，即使留下内容也绝不执行；重定向仍由 curl -L 处理。
curl() {
    local arg previous=''
    for arg in "$@"; do
        if [[ $previous == -o ]]; then
            echo "touch '$work/unexpected'" > "$arg"
        fi
        previous="$arg"
    done
    return 22
}
set +e
(set -e; run_remote https://example.invalid script.sh) > /dev/null 2>&1
status=$?
set -e
[[ $status != 0 && ! -e $work/unexpected ]]

# 完整字体校验先于写入，缺少字重时不留下半套字体。
mkdir -p "$work/source"
echo regular > "$work/source/msyh.ttc"
set +e
(set -e; install_fonts "$work/fonts" <<< $'y\n'"$work/source") > /dev/null 2>&1
status=$?
set -e
[[ $status != 0 && ! -d $work/fonts ]]
echo bold > "$work/source/msyhbd.ttc"
echo light > "$work/source/msyhl.ttc"
install_fonts "$work/fonts" <<< $'y\n'"$work/source"
cmp "$work/source/msyh.ttc" "$work/fonts/msyh.ttc"
echo existing > "$work/fonts/msyh.ttc"
set +e
(set -e; install_fonts "$work/fonts" <<< $'y\n'"$work/source") > /dev/null 2>&1
status=$?
set -e
[[ $status != 0 && $(cat "$work/fonts/msyh.ttc") == existing ]]

# 检查内嵌配置代码，所有凭据、终端输入与 Docker 调用均为测试替身。
python_bin="$(command -v python3 || command -v python)"
"$python_bin" - <<'PY'
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from unittest.mock import patch
from types import SimpleNamespace

parts = re.findall(r"<<'PY'\n(.*?)\nPY", Path("install.sh").read_text(encoding="utf-8"), re.S)
assert len(parts) == 2
for part in parts:
    compile(part, "inline-python", "exec")
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    (root / "config.example.json").write_text('{"keep": "unchanged"}')
    aria = root / "aria2.conf"
    aria_text = "#dir=/ignored\n dir = /srv/media downloads///\nrpc-secret=test-only=secret#literal\nenable-rpc=true\nrpc-listen-all=true\nrpc-listen-port=16800\n"
    aria.write_text(aria_text, encoding="utf-8")
    real_open = open

    def fake_open(name, *args, **kwargs):
        if name == "/dev/tty":
            # 终端不支持 r+ 所需的 seek；读写流必须分别打开。
            if "+" in args[0]:
                raise io.UnsupportedOperation("File or stream is not seekable.")
            return io.StringIO()
        return real_open(name, *args, **kwargs)

    with patch.object(sys, "argv", ["check", temp, str(aria)]), patch.object(sys, "stdin"), patch("builtins.open", side_effect=fake_open), patch("builtins.input", return_value=""), patch("getpass.getpass", return_value="test-only-secret") as password_prompt:
        exec(parts[0], {})
        assert password_prompt.call_count == 2
    target = root / "config.json"
    config = json.loads(target.read_text())
    assert config["keep"] == "unchanged"
    assert config["app_password"] == "test-only-secret"
    assert config["openlist_url"] == "http://host.docker.internal:5244"
    assert config["host_download_dir"] == "/srv/media downloads"
    assert config["aria2_secret"] == "test-only=secret#literal"
    assert config["aria2_rpc_url"] == "http://host.docker.internal:16800/jsonrpc"
    assert len(config["secret_key"]) == 64
    if os.name == "posix":
        assert target.stat().st_mode & 0o777 == 0o600
    before = target.read_bytes()
    with patch.object(sys, "argv", ["check", temp]), patch("builtins.input", side_effect=AssertionError("must not prompt")):
        try:
            exec(parts[0], {})
        except SystemExit as exc:
            assert exc.code == 0
    assert target.read_bytes() == before

    for old, new in (
        ("/srv/media downloads///", "relative/path"),
        ("/srv/media downloads///", "/"),
        ("/srv/media downloads///", "/app/data"),
        ("test-only=secret#literal", ""),
        ("16800", "65536"),
        ("enable-rpc=true", "enable-rpc=false"),
        ("rpc-listen-all=true", "rpc-listen-all=false"),
    ):
        target.unlink(missing_ok=True)
        aria.write_text(aria_text.replace(old, new), encoding="utf-8")
        with patch.object(sys, "argv", ["check", temp, str(aria)]), patch("getpass.getpass", side_effect=AssertionError("must fail before prompting")):
            try:
                exec(parts[0], {})
            except SystemExit as exc:
                assert exc.code
            else:
                raise AssertionError("invalid Aria2 config accepted")
        assert not target.exists()
    target.write_bytes(before)

    manifest = root / "manifest.json"
    override = root / "compose.install.json"
    volumes = [{"type": "bind", "source": "/hash/download", "target": dest} for dest in ("/downloads", "/hash/download")]
    volumes.append({"type": "bind", "source": str(root / "config.json"), "target": "/app/config.json"})
    data = {"services": {"example": {"expose": ["5090"], "volumes": volumes}}, "networks": {"shared": {"external": True, "name": "example_shared"}}}
    manifest.write_text(json.dumps(data))
    calls = []

    def fake_run(args, **kwargs):
        calls.append(args)
        return SimpleNamespace(returncode=1 if "inspect" in args else 0)

    with patch.object(sys, "argv", ["check", str(manifest), str(override), "0", ""]), patch("subprocess.run", side_effect=fake_run):
        exec(parts[1], {})
        service = json.loads(override.read_text())["services"]["example"]
        assert service["ports"] == ["127.0.0.1:5090:5090"]
        assert {v["target"] for v in service["volumes"]} == {"/downloads", "/hash/download", "/srv/media downloads"}
        assert all(v["source"] == "/srv/media downloads" for v in service["volumes"])
        assert calls[-1] == ["docker", "network", "create", "example_shared"]
        override.write_text('{"keep": "existing override"}')
        exec(parts[1], {})
        assert json.loads(override.read_text()) == {"keep": "existing override"}
    # 已有部署仅切换端口绑定，保留其他覆盖项，并备份切换前的文件。
    original = {"services": {"example": {"ports": ["127.0.0.1:5090:5090"], "environment": {"KEEP": "yes"}, "volumes": [{"type": "bind", "source": "/custom", "target": "/custom"}]}}, "keep": "unchanged"}
    override.write_text(json.dumps(original))
    for access, host in (("2", "0.0.0.0"), ("1", "127.0.0.1")):
        previous = override.read_bytes()
        backups_before = set(root.glob("compose.install.json.backup.*.save"))
        with patch.object(sys, "argv", ["check", str(manifest), str(override), access, ""]), patch("subprocess.run", side_effect=fake_run):
            exec(parts[1], {})
        backups = set(root.glob("compose.install.json.backup.*.save")) - backups_before
        assert len(backups) == 1 and next(iter(backups)).read_bytes() == previous
        changed = json.loads(override.read_text())
        assert changed["services"]["example"]["ports"] == [f"{host}:5090:5090"]
        changed["services"]["example"]["ports"] = original["services"]["example"]["ports"]
        assert changed == original
    override.unlink()
    with patch.object(sys, "argv", ["check", str(manifest), str(override), "2", ""]), patch("subprocess.run", side_effect=fake_run):
        exec(parts[1], {})
    assert json.loads(override.read_text())["services"]["example"]["ports"] == ["0.0.0.0:5090:5090"]
    runtime = [{"Mounts": [{"Type": "bind", "Source": "/srv/existing/config.json", "Destination": "/app/config.json", "RW": True}, {"Type": "bind", "Source": "/srv/existing/fonts", "Destination": "/app/fonts", "RW": False}]}]
    with patch.object(sys, "argv", ["check", str(manifest), str(override), "2", "example-running-id"]), patch("subprocess.run", side_effect=fake_run), patch("subprocess.check_output", return_value=json.dumps(runtime)) as inspect:
        exec(parts[1], {})
        inspect.assert_called_once_with(["docker", "inspect", "example-running-id"], text=True)
    mounted = {volume["target"]: volume for volume in json.loads(override.read_text())["services"]["example"]["volumes"]}
    assert mounted["/app/config.json"]["source"] == "/srv/existing/config.json"
    assert mounted["/app/fonts"]["source"] == "/srv/existing/fonts" and mounted["/app/fonts"]["read_only"] is True
    # 基础文件已有映射时拒绝叠加，避免两个 host_ip 导致端口占用。
    previous = override.read_bytes()
    data["services"]["example"]["ports"] = [{"target": 5090, "published": "5090", "host_ip": "127.0.0.1", "protocol": "tcp"}]
    manifest.write_text(json.dumps(data))
    with patch.object(sys, "argv", ["check", str(manifest), str(override), "2", ""]), patch("subprocess.run", side_effect=fake_run):
        try:
            exec(parts[1], {})
        except SystemExit as exc:
            assert exc.code
        else:
            raise AssertionError("conflicting base ports accepted")
    assert override.read_bytes() == previous
print("PASS: Aria2 自动配置、无效配置拒绝、已有配置保护、Compose 下载目录挂载。")
PY
echo 'PASS: 选择解析、安装顺序、去重、失败隔离、下载失败和字体保护。'
