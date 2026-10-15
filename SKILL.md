---
name: site-rebuild-and-deploy
description: 端到端一条龙——给一个参考网站 URL，先做 1:1 保真复刻（取证式镜像 → 逐行逆向 → 拼接式重拼 → 五层自动验收），再把产物发布到 GitHub Pages 并绑定自定义域名。当用户说「复刻这个网站然后上线」「参考这个站做一个并部署」「clone this site and deploy it」「复刻完帮我发到 GitHub Pages / 绑定我的域名」时使用。底层组合 website-rebuild 复刻管线 + 本 skill 自带的发布脚本与踩坑手册。
agent_created: true
metadata:
  version: "1.0.1"
---

# 复刻 → 上线 一条龙

## 这个 skill 解决什么

用户给一个网址，最后要拿到一个**能访问的线上地址**。中间隔着两段都容易翻车的路：

- **复刻段**：证据基座（镜像）、坐标系（展开的 bundle）、构造性证明（重拼逐字节一致）、五层自动验收门
- **发布段**：发布包的字节保真、gh 在 Windows 下"假装未登录"、Pages 与自定义域名的绑定、DNS 排查

本 skill 把这两段固化成一个流程，并把三个**会静默失败、浪费大量时间**的坑前置规避。

## 组成

| 层 | 谁负责 | 说明 |
|---|---|---|
| 复刻 | `website-rebuild` skill | 取证式管线。**必须先加载它、按它的全流程走、遵守它的六条宪法纪律** |
| 发布 | 本 skill `scripts/` | 发布树生成、字节保真校验、建仓推送开 Pages、远端 blob sha 复核 |
| 参考 | 本 skill `references/` | 阶段化命令清单、Windows 环境坑、排错速查 |

**不要自己重写复刻管线**。`website-rebuild` 的价值在于量化验收门和法务纪律，绕过它等于把"看着像"当成"复刻完成"。

## 总流程（三段，每段有门）

```
Phase A 复刻     判级 → 镜像 → 逆向 → 重拼 → 五层验收门
Phase B 发布包   产物 → deploy/（CNAME + .nojekyll + .gitattributes + README）→ 字节保真校验
Phase C 上线     建仓 → 推送 → 开 Pages → 绑域名 → 远端字节复核 → DNS → 线上验收
```

**阶段门（不过门不许进下一段）**：

| 段 | 门 | 判定标准 |
|---|---|---|
| A | `verify-mirror` | 五项断言 PASS（源站自身的洞登记豁免，不伪造字节） |
| A | `verify-reassembly` | 重拼结果**逐字节等于源站原件** |
| A | `sweep-routes` | 全路由 0 控制台错误 / 0 请求失败 / 0 外联 |
| A | `pixelcompare` | 先建自比带宽，跨侧残差全部落在带宽内（逐像素一致最佳） |
| B | 全新 clone sha256 | 检出后每一文件与复刻产物一致（证明 git 没改字节） |
| C | 远端 blob sha | GitHub 上每个 blob 与本地重算值一致 |
| C | 线上验收 | 域名 200 + 主 bundle 线上下载 sha256 与产物一致 + 浏览器 0 控制台错误 |

## 开工前必须问用户的（用 `AskUserQuestion`，一次问完）

1. **复刻终点**：L1 镜像存档 / **L2 工程化复刻（默认推荐）** / L3 源码化。三级梯子单调，选低不亏，日后可续跑升级。
2. **复刻范围**：整站全部路由 / 只做首页+核心流程 / 自定义。
3. **发布去向**：仓库名 + 是否绑自定义域名（要域名就一并问域名）。仓库可见性说明清楚——**GitHub Pages 免费账号只支持 public 仓库**。

⛔ **法务边界（继承 website-rebuild，不可放宽）**：

- 复刻产出**默认私有 + noindex + 不公开部署**。要公开，必须由用户**明确决定**，并完成逐资产版权取证（`website-rebuild/references/legal-and-deploy.md`）。
- 公开部署前建议在页面保留原作者归属、标注「非官方复刻」。
- 源站 `robots.txt` / 服务条款 / 版权要遵守；抓取保持低频单会话。
- 法务判断归用户，agent 只取证与呈现事实、列选项与风险边界。**未获明确决定前，只能往保守侧执行默认。**

## Phase A · 复刻

```
Skill: website-rebuild        # 先加载它
```

按它的 Step 0 → M0 → M(n) 推进。**逐步命令清单（含每个脚本的准确参数）见 [references/pipeline.md](references/pipeline.md)。**

要点速记：

1. **Step 0 指纹侦察**判级（A/B/C/D/X 类）。判成 C/D 类要解释原因，不要硬跑。
2. **M0 镜像永远最先做**——镜像是全项目的证据基座，`mirror/` 磁盘文件永不修改。
3. **判 bundle 形态**决定路线：scope-hoisted ESM 走**拼接式分解**（切片→重拼逐字节）；有打包容器则走模块级分解。
4. **纪律 4：bug / 死代码 / 怪写法照抄不修**。源站自己 404 的资源（如 `favicon.svg`、`sw.js`）登记进 `external.txt` 豁免，**不伪造字节补齐**。
5. **纪律 5：有意偏差必须登记**。没登记的差异一律视为 bug。
6. 每个里程碑产出成对提交（代码 + 文档）。

## Phase B · 发布包

```bash
NODE=node    # 若 node 不在 PATH，用 `$HOME/.workbuddy/binaries/node/versions/*/node.exe`

# 1) 生成发布树（自动带 CNAME / .nojekyll / .gitattributes / README）
$NODE scripts/build-deploy-tree.mjs \
  --src   <复刻产物目录，如 pinit-rebuild/site> \
  --out   <项目>/deploy \
  --domain card.example.com \
  --repo  <owner>/<repo> \
  --title "站点标题"

# 2) 字节保真：逐文件 sha256 与源对比（生成完立刻查，不要等推完再查）
$NODE scripts/verify-bytes.mjs --ref <复刻产物目录> --check <项目>/deploy

# 3) git 化 + 全新 clone 复核（比在源目录里比更可信）
cd <项目>/deploy
git init -b main && git add -A && git commit -m "首次发布"
```

**为什么必须有 `.gitattributes`（`* -text`）**：git 默认做 LF→CRLF 转换，**足以改坏构建产物字节**，而且只在检出时才发生——源目录里查不出来。这是坑二。

## Phase C · 上线

```bash
bash scripts/ship-to-pages.sh <repo名> <域名> <deploy目录> [--ref <本地产物目录>] [--desc "描述"]
# 例：bash scripts/ship-to-pages.sh qrcard card.hgjhub.com pinit-rebuild/deploy --ref pinit-rebuild/site
```

脚本一次跑完 7 步：gh 配置目录修正 → 授权检查 → `.gitattributes` 检查 → 字节前置校验 → 建仓/推送 → 开 Pages 带 cname → **远端 blob sha 逐一复核** → 等构建 → 打印 DNS 指引。

之后**只剩 DNS 需要用户手工**（脚本会打印准确指令）：

| Type | Name | Target | Proxy |
|---|---|---|---|
| `CNAME` | 子域名前缀 | `<user>.github.io` | **首次建议 DNS only（灰色云朵）** |

- ❌ 不要用 `A` 记录指向 GitHub IP（换 IP 就断）
- ❌ 同名旧记录（`A`/`AAAA`/`CNAME`）必须先删
- 用户报"配好了"之后，**立刻验证**：先问 zone 的权威 NS，别先查公共解析器（有缓存）。命令见 `references/pipeline.md` §C4。
- Cloudflare 代理开着也能用，但有代价，见 `gh-pages-deploy` skill 的"坑三"一节。

## 四个必踩的坑（详见 references/windows-pitfalls.md）

1. **Windows + Git Bash：gh "假装未登录"** —— `APPDATA` 为空导致 gh 找错配置目录（`~/.config/gh`）。跑任何 gh 命令前 `export GH_CONFIG_DIR='C:/Users/<你>/AppData/Roaming/GitHub CLI'`。
   ⛔ **值必须是 `C:/…` 盘符写法**：`"$HOME/AppData/Roaming/GitHub CLI"` 展开成 `/c/Users/…`，gh 解析不了，**症状与真未登录完全一样**。保险写法 `$(cygpath -m "$HOME")/AppData/Roaming/GitHub CLI`。`hosts.yml` 里没有 `oauth_token` 属正常（token 在 keyring）。**先试这个，别急着重新授权**。
2. **git 静默改坏构建产物字节** —— 缺 `.gitattributes`（`* -text`）。用全新 clone + sha256 复核验证。
3. **MSYS 路径喂给 Windows 原生二进制（gh / node）** —— 与坑 1 同源。`node` 收到 `/c/Users/…` 会拼成 `C:\c\Users\…` → MODULE_NOT_FOUND；`verify-remote-blobs --local /c/…` 直接 `FATAL: --local 不是目录`。**Git Bash 不会自动转换**（实测 `process.argv` 收到原样的 `/c/…`）。脚本里的 `winpath()` 助手就是为这个存在的：凡是交给 `.exe` 的路径先 `cygpath -m`。⚠️ `git` 例外（自带 MSYS，认 `/c/…`）。
4. **复刻管线的 Windows 不适配** —— `spawnSync("npx")` 报 EINVAL（Node 不能直接跑 `npx.cmd`）、`process.kill(-pgid)` 连带杀掉外层 shell、acorn 按 script 模式误判 ESM。修法与垫片见 `references/windows-pitfalls.md`。

## 排错速查

| 现象 | 原因 / 处置 |
|---|---|
| `gh auth status` 说没登录，但用户记得登录过 | `APPDATA` 空 → 设 `GH_CONFIG_DIR`；**确认值是 `C:/…` 而不是 `/c/…`** |
| `Authentication complete.` 后报 hosts.yml 找不到 | 同上，先建目录再重跑 |
| `hosts.yml` 里没有 `oauth_token` | **正常**，token 在 Windows keyring。`gh auth status` 才是判据 |
| `verify-remote-blobs` 报 `FATAL: --local 不是目录: /c/…` | MSYS 路径没转盘符 → `--local "$(cygpath -m "$SRC")"` |
| `Cannot find module 'C:\c\Users\…'` | 同上；`C:\c\` 是历史误建目录，**别删**，但要知道它会让路径错误静默化 |
| 推送后页面空白 / JS 报语法错 | 漏了 `.gitattributes`，字节被 EOL 转换改坏 |
| `github.io/<repo>/` 返回 301 | **正常**——已配 cname，重定向到自定义域名 |
| 域名 502 / host unknown | 自定义域名的 DNS 记录还没加 |
| DNS 查权威 NS 是 NXDOMAIN 但用户说配了 | 记录没保存成功（不是传播延迟）；让用户回控制台确认 zone、Save、字段 |
| 域名是 CF 的 IP 而非 github.io | 代理开着。能用，但 `https_enforced` 不可用 + 要开 Always Use HTTPS + SSL 须 Full |
| 域名 522 / 证书签不出 | 可改 DNS only；或按上一条配 Full |
| 全站 404 但根目录 200 | `index.html` 用绝对路径 `/assets/...` 且站点在子路径下 |
| 下划线开头的目录取不到 | 漏了 `.nojekyll` |
| 直连 GitHub IP 全部超时 | 环境出口走代理，属沙箱限制；用域名访问即可 |
| 无头浏览器验收多出一条 CF 外联 | Cloudflare 注入的分析脚本，不是站点发的 |

## 交付清单（收尾必须给全）

- 线上地址 + 仓库地址
- 验收证据表：镜像门 / 重拼门 / 广度门 / 像素门 / 远端字节 / 线上浏览器验收
- `README.md`（项目根）：站点是什么 + 复刻怎么来的 + 部署全流程 + 目录结构 + 复现命令 + 已知项
- `DEPLOY-STATUS.md`：部署记录与实测结果
- 遗留待办（如 CF 的 Always Use HTTPS、源站自带 404 洞是否保留）

## References

- [references/pipeline.md](references/pipeline.md) — 三阶段逐步命令清单（含每个脚本的准确参数与已验证的调用样例）
- [references/windows-pitfalls.md](references/windows-pitfalls.md) — Windows / Git Bash 环境坑与修法
