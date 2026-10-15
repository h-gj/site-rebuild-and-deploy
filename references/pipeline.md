# 三阶段逐步命令清单

所有 `$N` 代表 node 可执行文件；`$S` 代表 `website-rebuild` skill 的 `scripts/` 目录。
Windows 上若 node 不在 PATH：

```bash
N="$HOME/.workbuddy/binaries/node/versions/22.22.2-2/node.exe"   # 按实际版本号替换
S="$HOME/.workbuddy/skills/website-rebuild/scripts"
```

统一约定：先 `cd` 到项目工作目录（下称 `$P`），所有产物落在 `$P` 下。

---

## Phase A · 复刻

### A0 指纹侦察（判级）

```bash
mkdir -p "$P" && cd "$P"
"$N" "$S/fingerprint.mjs" --target "<源站URL>" --out probe
```

产出 `probe/verdict.md`（判级 + 证据）。看到主 bundle 引用后，用 `--bundle` 再跑一次可逆向性初检：

```bash
"$N" "$S/fingerprint.mjs" --target "<源站URL>" \
  --bundle "<源站URL>/assets/index-XXXX.js" --out probe
```

**此时向用户提问**（`AskUserQuestion`，一次问完）：复刻终点（L1/L2/L3）、复刻范围（整站/部分/自定义）。

### A1 M0 · 镜像取证

```bash
# BFS 爬取整站；--probe-404 用一个不存在的路径做 404 基线判定
"$N" "$S/mirror-site.mjs" --origin "<源站URL>" --out mirror --probe-404 /no-such-page-mirror-probe

# 静态五项断言（会报出 missing 清单）
"$N" "$S/verify-mirror.mjs" --mirror mirror
```

对**源站自身就是 404** 的引用（爬取结果里 missing 且实测源站也 404），登记豁免，**不伪造字节**：

```bash
cat > mirror/external.txt <<'EOF'
# 源站自身缺失（origin 404，爬取与 verify-mirror 双重确认）——忠实镜像不伪造字节
https://<源站>/favicon.svg
https://<源站>/assets/sw.js
EOF
"$N" "$S/verify-mirror.mjs" --mirror mirror --allow-missing mirror/external.txt
```

**补抓被 JSON 引用漏掉的资源**（如 manifest 里引用的图标）——走正式下载器入账，保持"一个镜像一本账"：

```bash
printf '%s\n' "https://<源站>/icons/icon-512.png" "https://<源站>/icons/icon-512-maskable.png" > solved-urls.txt
"$N" "$S/mirror-site.mjs" --origin "<源站URL>" --out mirror --seeds solved-urls.txt
```

### A2 M0.5 · 浏览器补录 + 断网验收

```bash
# CDP 补录运行时请求（--fetch 顺带补抓缺口）
CHROME_PATH="C:/Program Files/Google/Chrome/Application/chrome.exe" \
  "$N" "$S/netcapture.mjs" --origin "<源站URL>" --mirror mirror \
  --routes "/,/create,/scan,/view" --fetch
# 目标：GAP = 0
```

起参照服 + 逐路由探针（**用后台任务跑，见 windows-pitfalls §4**）：

```bash
"$N" "$S/serve.mjs" --side mirror --root mirror      # 记下端口，下面假设 26001
for r in "/" "/create" "/scan" "/view"; do
  CHROME_PATH="C:/Program Files/Google/Chrome/Application/chrome.exe" \
    "$N" "$S/probe.mjs" "http://127.0.0.1:26001/#$r" --side mirror --no-external --wait 5000
done
```

### A3 M1 · 逆向建坐标系

```bash
# 展开 bundle（token 流与源字节一致，保证展开不改语义）
"$N" "$S/beautify-bundle.mjs" mirror/assets/*.js --out mirror/_pretty

# 判形态 / 路由表 / 协议层 —— 用 Grep 在 _pretty 里定位
#   createApp / createRouter / createWebHashHistory  → 确认 SPA 与路由模式
#   path:"..."                                       → 列出路由表
grep -oE 'path:"[^"]*"' mirror/_pretty/*.js | sort -u
```

写 `docs/engine-notes.md`（技术栈版本、bundle 形态判定、路由表、数据模型、私有协议、存储层、源站洞）。

### A4 M2 · 拼接式分解

```bash
# chunk 账本
"$N" "$S/census-bundles.mjs" --dir mirror/assets --out docs/bundle-census.json --md docs/chunk-graph.md

# 按顶层声明切成语义部件
mkdir -p port
for c in index-XXXX index-YYYY pako.esm-ZZZZ; do
  "$N" "$S/slice-esm.mjs" --in "mirror/assets/$c.js" --out "port/$c"
done

# 重拼门：逐部件 sha / 按序拼接 sha / 对活原件 sha
for c in index-XXXX index-YYYY pako.esm-ZZZZ; do
  "$N" "$S/verify-reassembly.mjs" --dir "port/$c" --against mirror
done
```

### A5 M3 · 组装 site/

写项目自己的 `build.mjs`：按各目录的 `slices.json` 顺序拼接部件 → 输出 `site/`，并对每个产物做 sha256 与 `mirror/` 闭环。

```bash
"$N" build.mjs      # 目标输出：BYTE-EXACT
```

### A6 M4/M5 · 运行时门

```bash
# 起重建侧参照服
"$N" "$S/serve.mjs" --side rebuild --root site       # 假设端口 26002

# 需要真实载荷时，按逆出的协议链现场造一个（JSON → 压缩 → 编码）
"$N" gen-payload.mjs > test-payload.txt
P=$(cat test-payload.txt)

# 广度门：hash 路由必须写成 "/#/create" 形式；--allow-* 放行已登记的源站洞
for side in 26001 26002; do
  CHROME_PATH="C:/Program Files/Google/Chrome/Application/chrome.exe" \
    "$N" "$S/sweep-routes.mjs" --base "http://127.0.0.1:$side" \
    --routes "/,/#/create,/#/scan,/#/view,/#/p/$P" \
    --allow-failures "favicon" --allow-errors "bad HTTP response code|status of 404" \
    --out "docs/sweep-$side.tsv"
done

# 深度门：先建自比带宽（同侧交错多跑），再跨侧对拍
CHROME_PATH="..." "$N" "$S/pixelcompare.mjs" --a http://127.0.0.1:26001/ --b http://127.0.0.1:26001/ \
  --self --name self1 --out docs/pixelcompare
CHROME_PATH="..." "$N" "$S/pixelcompare.mjs" --a http://127.0.0.1:26002/ --b http://127.0.0.1:26001/ \
  --name home --out docs/pixelcompare-cross --max-mean 1
```

**门不过不许进 Phase B。** 有意偏差必须登记（纪律 5）。

---

## Phase B · 发布包

```bash
"$N" "<本skill>/scripts/build-deploy-tree.mjs" \
  --src "$P/site" --out "$P/deploy" \
  --domain card.example.com --repo "<owner>/<repo>" --title "站点标题"

"$N" "<本skill>/scripts/verify-bytes.mjs" --ref "$P/site" --check "$P/deploy"

# ⚠️ Windows + Git Bash：`$P` 是 `/c/Users/…`（MSYS 路径），而 `$N`（node.exe）是 Windows
# 原生二进制。verify-bytes.mjs 内部有归一化能兜住，但**自己写命令时别赌**：
#   NODE_SAFE="$(cygpath -m "$N")"; P_SAFE="$(cygpath -m "$P")"
# 凡是--ref/--check/--local 这类**交给 node 的路径参数**，一律先转盘符写法。

cd "$P/deploy" && git init -b main && git add -A && git commit -m "首次发布"

# 全新 clone 复核（比在源目录里比更可信——EOL 转换只在检出时发生）
git clone -q . ../verify-clone
"$N" "<本skill>/scripts/verify-bytes.mjs" --ref "$P/site" --check "$P/../verify-clone"
```

---

## Phase C · 上线

```bash
bash "<本skill>/scripts/ship-to-pages.sh" <repo> <域名> "$P/deploy" \
  --ref "$P/site" --desc "描述"
```

脚本已内置：gh 配置目录修正 / 授权检查 / `.gitattributes` 检查 / 本地字节校验 / git 化 / 建仓推送 / 开 Pages 带 cname / 远端 blob sha 复核 / 等构建 / DNS 指引 / DNS 现状探测。

### C3 · 域名在 Cloudflare 时（选配，不影响能不能上线）

记录保存后若解析结果是 CF 的边缘 IP（`104.21.x` / `172.67.x` / `172.64.x`，通常与 zone 根域同 IP），说明**代理开着（橙云）**。实测**站点照样正常 200**——CF 对 `子域 → <user>.github.io` 做 CNAME 回源并透传 `Host`，Pages 按 Host 头路由到正确站点；浏览器侧 TLS 由 CF Universal SSL 覆盖。

但有三个代价必须处理：

1. `https_enforced` 永远 `false` 且**无法开启**（域名没指向 GitHub，GitHub 签不出证书）——不影响访问，但别指望 GitHub 那侧变绿
2. HTTP **不自动跳 HTTPS** → 去 `SSL/TLS → Edge Certificates → Always Use HTTPS` 打开
3. `SSL/TLS` 加密模式必须是 **Full**（Flexible 会撞上 Pages 的 HTTPS 重定向 → 死循环）。判别：能正常 200 且无循环就是安全的

另外 CF 会**自动注入 `static.cloudflareinsights.com` 分析脚本**——无头浏览器验收时会显示为一条外联请求，那是 CF 注入的，不是站点发的。

⚠️ 开代理时，任何"检查 CNAME 是否指向 github.io"的自检脚本都会**误判为配错**（记录里是 CF 的 IP）。**以实际 `curl -I https://域名/` 返回 200 为准。**

其余禁忌（无论代理开关）：不要用 `A` 记录指向 GitHub 的 IP；同名旧记录（`A`/`AAAA`/`CNAME`）必须先删。

> 想看更细的排错矩阵（含 Cloudflare 与 GitHub Pages 的完整坑位表），可加载配套 skill `gh-pages-deploy`——本 skill 已内联关键结论，不加载也能独立完成。

### C4 · 用户报"DNS 配好了"之后的验证顺序 ⭐

```bash
# ① 先问权威 NS（不要先查公共解析器 —— 有缓存，会误判）
ZONE=example.com
NS=$(nslookup -type=NS $ZONE 2>/dev/null | sed -n 's/.*nameserver = //p' | head -1)
nslookup card.$ZONE "$NS"

# ② 对照探一下根域（确认查询链路本身正常）
nslookup $ZONE

# ③ 再实测 HTTP
curl -sS --max-time 30 -o /dev/null -w "%{http_code} %{size_download}B\n" -L https://card.$ZONE/

# ④ 线上字节复核（最关键的一步）：把线上文件下载回来与本地比 sha256
curl -sS --max-time 60 -o live-main.js "https://card.$ZONE/assets/index-XXXX.js"
sha256sum live-main.js mirror/assets/index-XXXX.js
```

**判定规则**：权威 NS 直答 NXDOMAIN 且根域正常 → **记录没保存成功**，不是传播延迟。让用户回控制台检查三件事：zone 选对没、点没点 Save、字段填对没（Name 只填前缀，不要填全名）。

### C5 · 上线后浏览器验收

```bash
for r in "" "#/create" "#/scan" "#/view"; do
  WRS_PORT_SLOT=$((i++)) CHROME_PATH="..." \
    "$N" "$S/probe.mjs" "https://card.$ZONE/$r" --side live --wait 6000
  # 目标：0 控制台错误；域名走 Cloudflare 时会多出一条 CF 注入的分析外联，非站点行为
done
```

### C6 · 收尾文档

- `README.md`（项目根）：站点是什么 / 复刻怎么来的 / 部署全流程 / 目录结构 / 复现命令 / 已知项
- `DEPLOY-STATUS.md`：部署记录与实测结果
- `docs/legal-dossier.md`：逐资产版权取证（`website-rebuild` 的 `legal-and-deploy.md` 有模板与读法）
