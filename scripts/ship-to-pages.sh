#!/usr/bin/env bash
# ship-to-pages.sh — 建仓 + 推送 + 开启 GitHub Pages + 绑定自定义域名 + 字节保真复核
#
# 用法：
#   bash ship-to-pages.sh <repo名> <域名|-> <发布目录> [选项]
#   bash ship-to-pages.sh qrcard card.hgjhub.com pinit-rebuild/deploy --ref pinit-rebuild/site
#   bash ship-to-pages.sh my-site - ./deploy            # 不绑域名，只发到 <user>.github.io/my-site/
#
# 选项：
#   --ref <目录>    字节保真参照目录（复刻产物）。给了就跑前置校验 + 远端 blob sha 复核
#   --desc <描述>   仓库描述
#   --owner <账号>  指定 GitHub 账号（默认取 gh 当前登录账号）
#   --private       建私有仓库（⚠️ Pages 从私有仓库发布需要 GitHub Pro/Team）
#   --branch <名>   分支名，默认 main
#   --no-dns-check  跳过末尾的 DNS 探测
#
# 幂等：仓库/Pages 已存在时走更新流程，可反复执行。
set -euo pipefail

# ---------------------------------------------------------------------------
# 坑一修正：Windows + Git Bash 里 APPDATA 为空 → gh 会去找 ~/.config/gh（不存在）
# 症状是「明明登录过却报未登录」，或 Authentication complete 之后报 hosts.yml 找不到。
# 必须在跑任何 gh 命令之前把配置目录指回真实位置。
# ---------------------------------------------------------------------------
if [ -z "${GH_CONFIG_DIR:-}" ]; then
  for cand in "$HOME/AppData/Roaming/GitHub CLI" "${APPDATA:-}/GitHub CLI"; do
    if [ -d "$cand" ]; then
      # ⛔ gh 是 Windows 原生二进制，MSYS 的 /c/Users/… 它解析不到 —— 症状与"未登录"
      # 一模一样，于是会被误判成"授权丢了"而白跑一次设备授权。必须给 C:/… 形式。
      if command -v cygpath >/dev/null 2>&1; then
        export GH_CONFIG_DIR="$(cygpath -m "$cand")"
      else
        export GH_CONFIG_DIR="$cand"
      fi
      break
    fi
  done
fi

# node 探测（优先 PATH，回落到 WorkBuddy 托管版本）
NODE_BIN="${NODE_BIN:-}"
if [ -z "$NODE_BIN" ]; then
  if command -v node >/dev/null 2>&1; then NODE_BIN=node
  else NODE_BIN="$(ls -d "$HOME"/.workbuddy/binaries/node/versions/*/node.exe 2>/dev/null | head -1 || true)"; fi
fi
[ -n "$NODE_BIN" ] || { echo "FATAL: 找不到 node（可用 NODE_BIN=/path/to/node 指定）"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# ⛔ node / gh / git 都是 Windows 原生二进制：把 MSYS 的 /c/Users/… 交给它们会拼成 C:\c\Users\…
# 实测 MODULE_NOT_FOUND: 'C:\c\Users\…\verify-bytes.mjs'，以及 fs.existsSync('/c/…') === false
# → verify-remote-blobs 报「FATAL: --local 不是目录」。凡是传给 .exe 的路径一律转盘符写法。
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
HERE_NODE="$(winpath "$HERE")"

REPO="${1:-}"; DOMAIN="${2:-}"; SRC="${3:-}"
[ -n "$REPO" ] && [ -n "$DOMAIN" ] && [ -n "$SRC" ] || {
  sed -n '2,17p' "$0"; exit 2
}
shift 3 || true

REF=""; DESC=""; OWNER=""; VIS="--public"; BRANCH="main"; DNS_CHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:-}"; shift 2 ;;
    --desc) DESC="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --private) VIS="--private"; shift ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --no-dns-check) DNS_CHECK=0; shift ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

[ "$DOMAIN" = "-" ] && DOMAIN="" || true
[ -d "$SRC" ] || { echo "FATAL: 发布目录不存在: $SRC"; exit 1; }
SRC="$(cd "$SRC" && pwd)"

echo "=============================================="
echo " 发布目标: $REPO    域名: ${DOMAIN:-<无，用 github.io 子路径>}"
echo " 发布目录: $SRC"
echo " GH_CONFIG_DIR=${GH_CONFIG_DIR:-<默认>}"
echo "=============================================="

# --- 0/7 授权 ---
echo "== 0/7 校验 GitHub 授权 =="
if ! gh auth status >/dev/null 2>&1; then
  cat <<'EOF'
FATAL: gh 未登录（或配置目录没找对）。

  ⚠️ Windows + Git Bash 下最常见的原因不是"真没登录"，而是 APPDATA 为空导致
     gh 去 ~/.config/gh 找配置。先确认真实配置目录存在：

       ls "$HOME/AppData/Roaming/GitHub CLI"      # 期望看到 config.yml / hosts.yml
       export GH_CONFIG_DIR="$(cygpath -m "$HOME")/AppData/Roaming/GitHub CLI"   # ⛔ 必须 C:/… 形式
       gh auth status                              # 现在应该正常

  ⛔ 用 "$HOME/AppData/Roaming/GitHub CLI"（即 /c/Users/…）是**没用的**：gh 是 Windows
     原生二进制，解析不了 MSYS 路径，症状与"未登录"一模一样 —— 于是你会以为修法失效、
     转头去重新授权，白费一个设备码。hosts.yml 里看不到 oauth_token 也是正常的
     （token 在系统 keyring 里，hosts.yml 只留 user:）。

  ⚠️ 不要急着重新授权 —— 同样原因会让你再失败一次，还白费一个设备码。

  确实需要新授权时（设备码流程，无需新开会话）：
       GH_PROMPT_DISABLED=1 gh auth login --hostname github.com --git-protocol https --web </dev/null
EOF
  exit 1
fi
[ -n "$OWNER" ] || OWNER="$(gh api /user --jq .login)"
# 允许 <owner>/<repo> 或 <repo> 两种写法：传了 owner/ 就以它为准，否则用 gh 当前账号。
# （不这么写就会拼出 h-gj/h-gj/dict2json 这种双重前缀，然后 404 —— 实测。）
if [ "${REPO#*/}" != "$REPO" ]; then
  OWNER="${REPO%%/*}"
  REPO="${REPO#*/}"
fi
FULL="$OWNER/$REPO"
echo " 身份: $OWNER   目标仓库: $FULL"

# --- 1/7 字节保真前置检查 ---
echo "== 1/7 字节保真前置检查 =="
if [ ! -f "$SRC/.gitattributes" ] || ! grep -qE '^\* +-text' "$SRC/.gitattributes"; then
  cat <<EOF
⚠️  $SRC/.gitattributes 缺少 '* -text'。
    git 默认会做 LF→CRLF 转换，足以改坏构建产物字节（且只在检出时才暴露）。
    已自动补写：
EOF
  printf '# 字节保真：禁止任何 EOL 转换与文本规范化\n* -text\n' > "$SRC/.gitattributes"
  echo "   ✓ 已写入 $SRC/.gitattributes"
else
  echo "  ✓ .gitattributes 就位（EOL 转换已禁用）"
fi
[ -f "$SRC/.nojekyll" ] || { touch "$SRC/.nojekyll"; echo "  + 补写 .nojekyll（否则下划线开头的目录会被 Jekyll 吞掉）"; }
if [ -n "$DOMAIN" ] && [ ! -f "$SRC/CNAME" ]; then
  printf '%s\n' "$DOMAIN" > "$SRC/CNAME"; echo "  + 补写 CNAME = $DOMAIN"
fi

# --- 2/7 本地字节保真校验 ---
echo "== 2/7 本地字节保真校验 =="
if [ -n "$REF" ] && [ -d "$REF" ]; then
  "$NODE_BIN" "$HERE_NODE/verify-bytes.mjs" --ref "$(winpath "$REF")" --check "$(winpath "$SRC")" --quiet || {
    echo "FATAL: 发布目录与参照目录字节不一致，先修好再推送。"; exit 1; }
else
  echo "  (未提供 --ref，跳过；建议传复刻产物目录以端到端锁死字节)"
fi

# --- 3/7 git 化 + 提交 ---
echo "== 3/7 git 化 =="
cd "$SRC"
if [ ! -d .git ]; then git init -q -b "$BRANCH" 2>/dev/null || { git init -q; git checkout -q -b "$BRANCH" 2>/dev/null || true; }; echo "  + git init"; fi
git rev-parse --git-dir >/dev/null
git symbolic-ref -q HEAD >/dev/null 2>&1 || git checkout -q -b "$BRANCH" 2>/dev/null || true
if ! git config user.name >/dev/null 2>&1; then
  git config user.name "$OWNER"; echo "  + git user.name = $OWNER（未检测到全局配置，用账号名占位）"
fi
git add -A
if git diff --cached --quiet; then
  echo "  工作区无变化，跳过提交"
else
  git commit -q -m "发布：$REPO${DOMAIN:+（$DOMAIN）}"
  echo "  已提交: $(git log --oneline -1)"
fi

# --- 4/7 建仓 / 推送 ---
echo "== 4/7 建仓并推送 =="
if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "  仓库已存在，走更新流程"
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$FULL.git"
  git push -u origin "$BRANCH"
else
  gh repo create "$FULL" $VIS --source=. --remote=origin --push --description "${DESC:-$REPO}"
  echo "  + 已创建并推送: https://github.com/$FULL"
fi

# --- 5/7 开启 Pages（一次调用带上 source + cname）---
echo "== 5/7 配置 GitHub Pages =="
BODY="$(mktemp)"
if [ -n "$DOMAIN" ]; then
  printf '{"source":{"branch":"%s","path":"/"},"cname":"%s"}\n' "$BRANCH" "$DOMAIN" > "$BODY"
else
  printf '{"source":{"branch":"%s","path":"/"}}\n' "$BRANCH" > "$BODY"
fi
if gh api "/repos/$FULL/pages" >/dev/null 2>&1; then
  gh api -X PUT "/repos/$FULL/pages" --input "$BODY" >/dev/null && echo "  Pages 已更新"
else
  gh api -X POST "/repos/$FULL/pages" --input "$BODY" >/dev/null && echo "  Pages 已开启"
fi
# ⛔ `rm -f` 也可能失败并把整个发布流程带走：沙箱/EDR 会把删除改成"移到回收站"，
# 而回收站包装器对着一个 %TEMP% 路径可能直接 fail-closed（实测 safe-delete FAIL_CLOSED），
# 于是 set -e 在"Pages 已开通之后、远端复核之前"中止——配置其实成功了，脚本却报死。
# 临时文件的清理绝不该决定发布成败，所以它必须是非致命的。
rm -f "$BODY" || true

# --- 6/7 远端字节保真复核 ---
echo "== 6/7 远端字节保真复核 =="
TREE="$(mktemp)"
if gh api "repos/$FULL/git/trees/$BRANCH?recursive=1" \
     --jq '.tree[] | select(.type=="blob") | .path + " " + .sha' > "$TREE" 2>/dev/null && [ -s "$TREE" ]; then
  # ⛔ 这里的 $SRC 必须转成盘符写法：node 不是 MSYS 程序，收到 /c/Users/… 会去找 C:\c\Users\…
  # 旧写法直接传 "$SRC"，因发布目录恰好不存在于 C:\c\… 而报「FATAL: --local 不是目录」(exit 2)。
  "$NODE_BIN" "$HERE_NODE/verify-remote-blobs.mjs" --tree "$TREE" --local "$(winpath "$SRC")" || echo "  ⚠️ 远端复核未通过，见上方明细"
else
  echo "  ⚠️ 取远端树失败（仓库刚建时可能还没索引好，稍后重跑本步）"
fi
rm -f "$TREE" || true

# --- 7/7 等构建 + 状态 + DNS 指引 ---
echo "== 7/7 等构建并取状态 =="
for _ in 1 2 3 4 5 6 7 8; do
  sleep 10
  ST="$(gh api "/repos/$FULL/pages/builds/latest" --jq .status 2>/dev/null || echo "")"
  [ "$ST" = "built" ] && break
  [ "$ST" = "errored" ] && { echo "  ✗ 构建失败:"; gh api "/repos/$FULL/pages/builds/latest" --jq '.error.message'; break; }
done
gh api "/repos/$FULL/pages" --jq '{status, cname, html_url, https_enforced, build_type}' || true

echo ""
echo "=============================================="
if [ -n "$DOMAIN" ]; then
  cat <<EOF
 还需你手工做一步：配 DNS（只有这一步 agent 做不了）

   类型:   CNAME
   名称:   ${DOMAIN%%.*}          ← 只填子域名前缀，不要填全名
   目标:   $OWNER.github.io
   代理:   DNS only（灰色云朵）   ← 首次建议关代理，最省事
   TTL:    Auto

   ⚠️ 不要用 A 记录指向 GitHub IP（185.199.108.153 等），换 IP 就断。
   ⚠️ 同名的旧 A/AAAA/CNAME 记录必须先删，冲突会导致校验失败。
   ⚠️ 域名在 Cloudflare 时，代理开着也能用，但要另配三项（详见 gh-pages-deploy skill）。

  配完后验证（注意：先问权威 NS，别先查公共解析器——有缓存会误导）：
EOF
  echo "     nslookup $DOMAIN              # 有结果 = 生效"
  ZONE="$(echo "$DOMAIN" | cut -d. -f2-)"
  echo "     nslookup $DOMAIN \$(nslookup -type=NS $ZONE 2>/dev/null | sed -n 's/.*nameserver = //p' | head -1)   # 直接问权威"
  echo "     curl -sI https://$DOMAIN/ | head -1     # 期望 HTTP/2 200"
  echo ""
  echo "  若权威 NS 直答 NXDOMAIN 而根域正常 → 记录没保存成功，不是传播延迟，回控制台重配。"
else
  echo " 线上地址: https://$OWNER.github.io/$REPO/"
  echo " 生效后验证: curl -sI https://$OWNER.github.io/$REPO/ | head -1"
fi
echo " 仓库: https://github.com/$FULL"
echo "=============================================="

if [ "$DNS_CHECK" = 1 ] && [ -n "$DOMAIN" ]; then
  echo ""
  echo "== DNS 现状探测 =="
  nslookup "$DOMAIN" 2>&1 | tail -6 || true
  ZONE="$(echo "$DOMAIN" | cut -d. -f2-)"
  NS="$(nslookup -type=NS "$ZONE" 2>/dev/null | sed -n 's/.*nameserver = //p' | head -1 || true)"
  if [ -n "$NS" ]; then
    echo "-- 权威 NS @$NS"
    nslookup "$DOMAIN" "$NS" 2>&1 | tail -5 || true
  fi
  echo "-- HTTP 探测"
  curl -sS --max-time 25 -o /dev/null -w "  https://$DOMAIN/ => %{http_code}\n" "https://$DOMAIN/" 2>&1 | tail -1 || echo "  (无法连接，DNS 可能还没生效)"
fi
