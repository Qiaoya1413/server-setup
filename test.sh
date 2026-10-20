#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./install.sh
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

parse_selection '2'
[[ ${selected[*]} == '2 4' ]]
parse_selection '1,2 4,4'
[[ ${selected[*]} == '1 2 4 4' ]]
parse_selection a
[[ ${selected[*]} == '1 2 3 4 5' ]]
for invalid in '' 0 6 12 '1 two' '1;id' 'a 1'; do
    if parse_selection "$invalid"; then
        fail "错误接受了输入：$invalid"
    fi
done

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
        return io.StringIO() if name == "/dev/tty" else real_open(name, *args, **kwargs)

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

    with patch.object(sys, "argv", ["check", str(manifest), str(override)]), patch("subprocess.run", side_effect=fake_run):
        exec(parts[1], {})
        service = json.loads(override.read_text())["services"]["example"]
        assert service["ports"] == ["127.0.0.1:5090:5090"]
        assert {v["target"] for v in service["volumes"]} == {"/downloads", "/hash/download", "/srv/media downloads"}
        assert all(v["source"] == "/srv/media downloads" for v in service["volumes"])
        assert calls[-1] == ["docker", "network", "create", "example_shared"]
        override.write_text('{"keep": "existing override"}')
        exec(parts[1], {})
        assert json.loads(override.read_text()) == {"keep": "existing override"}
print("PASS: Aria2 自动配置、无效配置拒绝、已有配置保护、Compose 下载目录挂载。")
PY
echo 'PASS: 选择解析、安装顺序、去重、失败隔离、下载失败和字体保护。'
