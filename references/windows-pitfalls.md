# Windows / Git Bash 环境坑与修法

这套管线原本按 POSIX（macOS / Linux / WSL）设计。在 **Windows + Git Bash** 下跑会撞到下列问题——它们共同特点是**静默失败**，不报出有用错误，只看日志会以为是别的原因。按顺序读完再开工。

---

## 1. gh 明明登录过，却说没登录 ⭐ 最常见

**症状**

```
$ gh auth status
You are not logged into any GitHub hosts. To log in, run: gh auth login
```

而用户明确记得登录过。或者授权流程走到最后一步突然失败：

```
✓ Authentication complete.
open C:\Users\<user>\.config\gh\hosts.yml: The system cannot find the file specified.
```

**根因**：Git Bash 里 `APPDATA` 环境变量为空，gh 解析不到 `%AppData%`，回落到 `$HOME/.config/gh`——那个目录通常不存在，gh 也不会自动创建。真实配置一直在 `%AppData%\GitHub CLI\`，token 存在系统 keyring 里，**你其实一直是登录着的**。

**修法**：跑任何 gh 命令前显式指定配置目录。

```bash
export GH_CONFIG_DIR='C:/Users/<你>/AppData/Roaming/GitHub CLI'
gh auth status
```

### ⚠️ 值必须是 `C:/…` 盘符写法，`$HOME/…` 形式无效

这是最容易反复踩的一点。`gh` 是 **Windows 原生二进制**，不认识 MSYS 路径。而 Git Bash 会把 `"$HOME/AppData/Roaming/GitHub CLI"` 展开成 `/c/Users/<你>/AppData/Roaming/GitHub CLI`，gh 拿到后解析不到，**症状与"未登录"一模一样**，于是你以为坑没修好，或者以为授权丢了。

实测对照（同一台机器、同一时刻，只改这一个变量）：

```bash
# ✗ POSIX / MSYS 形式 —— 无效
export GH_CONFIG_DIR="$HOME/AppData/Roaming/GitHub CLI"
echo "$GH_CONFIG_DIR"        # → /c/Users/69063/AppData/Roaming/GitHub CLI
gh auth status               # → You are not logged into any GitHub hosts.

# ✓ Windows 盘符形式 —— 有效
export GH_CONFIG_DIR='C:/Users/69063/AppData/Roaming/GitHub CLI'
gh auth status               # → ✓ Logged in to github.com account h-gj (keyring)
```

保险的写法（两种 shell 都对）：

```bash
export GH_CONFIG_DIR="$(cygpath -m "$HOME")/AppData/Roaming/GitHub CLI"
```

**先检查这个，再考虑重新授权**。重新授权不仅会白白消耗一个设备码，还会因为同样原因再失败一次。

`ship-to-pages.sh` 已内置自动探测；手写命令时记得自己带上。

### `hosts.yml` 里没有 `oauth_token` 属正常

```yaml
github.com:
    user: h-gj
    git_protocol: https
```

看不到 `oauth_token:` 字段**不代表授权丢失**——token 存在 **Windows keyring** 里，`hosts.yml` 只记用户名与协议。判断"到底登录没有"的唯一可靠方法是 **`gh auth status` 的退出码与输出**，不是翻文件。

反过来也要注意：`gh auth status` 因路径问题报"未登录"时，**不要**据此判定需要重新登录，也不要把这个错误结论写进文档或脚本。

```bash
ls -la "$HOME/AppData/Roaming/GitHub CLI"        # 期望看到 config.yml / hosts.yml
grep -A3 '^github.com:' "$HOME/AppData/Roaming/GitHub CLI/hosts.yml"   # 顺带看出用户名与 scopes
```

---

## 2. git 静默改坏构建产物字节

**症状**：本地 sha256 全对，推送后线上页面空白 / JS 报语法错 / 资源 404。

**根因**：git 默认 `core.autocrlf` 会在**检出时**把 LF 转成 CRLF。构建产物里若是二进制或对字节敏感的文本（minified JS、sourcemap、wasm），字节就被改了。**这个改动只在检出/入库路径上发生，在与源目录直接比对时查不出来。**

**修法**：发布树根目录放 `.gitattributes`：

```
# 字节保真：禁止任何 EOL 转换与文本规范化
* -text
```

并**用全新 clone 验证**（这才是能抓到问题的检法）：

```bash
git clone -q . ../verify-clone
node scripts/verify-bytes.mjs --ref <产物目录> --check ../verify-clone
```

---

## 3. `spawnSync("npx")` 在 Windows 返回 EINVAL

**症状**（复刻管线里的 `beautify-bundle.mjs` / `census-bundles.mjs` / `slice-esm.mjs` 会用到）

```
Error: spawnSync npx EINVAL
```

或者更隐蔽：`status === null`，脚本"跑完了"但没有任何产出。

**根因**：`npx` / `npm` / `yarn` 在 Windows 上是 `.cmd` 批处理。Node 从 CVE-2024-27980 修复起**不允许直接 spawn `.cmd`/`.bat`**，必须经由 `cmd.exe`。

**修法**：用 preload 垫片拦截，**不改动 skill 本体**。把下面内容存成项目里的 `npx-shim.cjs`，然后在调用 skill 脚本时用 `-r` 预加载：

```bash
node -r ./npx-shim.cjs <skill>/scripts/beautify-bundle.mjs mirror/assets/*.js --out mirror/_pretty
```

`npx-shim.cjs`：

```js
#!/usr/bin/env node
/**
 * preload 垫片：让 Windows 上的 spawnSync("npx") 能跑起来。
 * 用法: node -r ./npx-shim.cjs <原命令> <原参数...>
 */
'use strict';
const cp = require('child_process');
const isWin = process.platform === 'win32';

function needsShell(cmd) {
  if (!isWin || typeof cmd !== 'string') return false;
  if (/[\\/]/.test(cmd)) return false;    // 带路径的交给 Node 自己处理
  if (/\.exe$/i.test(cmd)) return false;  // 真 exe 不用管
  return true;                            // npx / npm / yarn / tsc …（含 .cmd / .bat）
}
function quote(a) {
  const s = String(a);
  return /[\s"^&|<>()]/.test(s) ? '"' + s.replace(/"/g, '\\"') + '"' : s;
}
function toCmd(cmd, args) {
  const comspec = process.env.ComSpec || process.env.COMSPEC || 'cmd.exe';
  const line = [cmd, ...args].map(quote).join(' ');
  return { cmd: comspec, args: ['/d', '/s', '/c', '"' + line + '"'], opts: { windowsVerbatimArguments: true } };
}

for (const name of ['spawnSync', 'execFileSync']) {
  const orig = cp[name];
  if (typeof orig !== 'function') continue;
  cp[name] = function (cmd, args, opts) {
    if (typeof args === 'object' && args !== null && !Array.isArray(args)) { opts = args; args = []; }
    args = args || [];
    if (needsShell(cmd)) {
      const t = toCmd(cmd, args);
      return orig.call(cp, t.cmd, t.args, Object.assign({}, opts, t.opts));
    }
    return orig.call(cp, cmd, args, opts);
  };
}

const origSpawn = cp.spawn;
cp.spawn = function (cmd, args, opts) {
  if (typeof args === 'object' && args !== null && !Array.isArray(args)) { opts = args; args = []; }
  args = args || [];
  if (needsShell(cmd)) {
    const t = toCmd(cmd, args);
    return origSpawn.call(cp, t.cmd, t.args, Object.assign({}, opts, t.opts));
  }
  return origSpawn.call(cp, cmd, args, opts);
};
```

---

## 4. CDP 脚本跑完把外层 shell 一起杀掉

**症状**：一条能跑通的命令，包在 `for` 循环或脚本里就 `exit=1` 且**没有任何输出**；有时连正在执行的那一层 shell 一起消失。

**根因**：管线里的 headless Chrome 辅助代码用 `process.kill(-pgid)` 收割整个进程组。Windows 没有真正的进程组语义，这个信号会向上波及，把外层 shell 一同带走。

**修法**（三条一起用）：

```bash
# ① 用后台任务跑，让进程组隔离
#    (在 agent 环境里用 run_in_background；在纯 shell 里用 `... > log 2>&1 &` 后轮询 log)

# ② 每次调用换一个端口槽位，避免上一轮残留的 Chrome 占着 CDP 端口
WRS_PORT_SLOT=6 CHROME_PATH="C:/Program Files/Google/Chrome/Application/chrome.exe" \
  node <skill>/scripts/probe.mjs "http://127.0.0.1:26001/#/create" --side mirror --no-external --wait 5000
# 下一轮用 WRS_PORT_SLOT=7，依此类推

# ③ 一轮跑完统一收割残留实例（只杀带 remote-debugging-port 的，别动用户自己的 Chrome！）
```

```powershell
# PowerShell：只杀管线起的实例
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
  Where-Object { $_.CommandLine -match 'remote-debugging-port' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
```

⚠️ **不要**无条件 `Stop-Process -Name chrome`——用户自己开着的 Chrome 会被一起杀掉。判断依据是命令行里有没有 `remote-debugging-port`（不要用 `--headless` 单独判断，用户也可能开着 headless）。

⚠️ Chrome 退出有延迟。刚跑完立刻查端口可能还占着，**不要据此判定"没收割成功"**。

---

## 5. acorn 把 ESM chunk 误判为排版腐坏

**症状**：token 一致性自查 / beautify 的解析检查报错，说文件语法有问题——但那其实是合法的 ESM chunk。

**根因**：acorn CLI 默认按 `script` 模式解析。chunk 里有顶层 `import` / `export` 时，script 模式必然报错。

**修法**：检测到顶层 `import`/`export` 时按 `module` 解析（加 `--module`，或脚本内判断后重试）。

涉及 `website-rebuild` 的两处：

- `scripts/lib/tokens.mjs` 的 `tokenStream()` —— acorn 调用加 module 兜底
- `scripts/beautify-bundle.mjs` 的 `--silent` 解析检查 —— 同上

判断标准：**报错位置在文件开头附近且内容是 import/export** → 就是这个问题，不是文件真的坏了。

---

## 6. 其他环境细节

| 现象 | 原因 / 处置 |
|---|---|
| Windows 原生 `curl` 写 `/tmp/xxx` 找不到文件 | Git Bash 的 `/tmp` 映射与原生 curl 理解不一致。**统一用项目目录下的相对/绝对路径** |
| `nslookup` 输出乱码 | 中文 Windows 的 nslookup 输出是 GBK。解析时套 `iconv -f gbk -t utf-8`，或改用 PowerShell `Resolve-DnsName` |
| `--resolve` 直连 GitHub Pages 边缘 IP 全部失败（code 000） | 沙箱出口走代理（`env \| grep -i proxy` 能看到），代理不接受直连 IP。**属环境限制，不是配置问题**；用域名访问即可 |
| 拿不到 `wmic` 输出 | 新版 Windows 已弃用 wmic。改用 PowerShell `Get-CimInstance Win32_Process` + `Select-Object ProcessId,CommandLine` |
| PowerShell 里写中文文件名变乱码 | 不要写 `.ps1`/`.bat` 脚本文件装非 ASCII 路径。把结果 `Out-File -Encoding utf8` 到文件再读，或用 Bash 直接操作 |
| 需要给长命令传绝对路径 | 一律用双引号包住（`"C:\Users\...\"`），Windows 路径里的空格与反斜杠最容易在这里出问题 |
| `gh` 输出的 `--jq` 里引号被 shell 吃掉 | 用单引号包 jq 表达式；同时避免在表达式里再嵌套双引号 |
| 后台任务在 agent 环境里"看起来结束了但没有输出" | 命令可能真的被 §4 的进程组问题带走了。检查日志文件是否有内容，再决定是否要换端口槽位重跑 |
| `ERR_INVALID_PACKAGE_CONFIG` 指向 deploy 根目录的 `package.json`（1nx.net 实测） | SPA catch-all 站会把 `/package.json` 的 404 兜底页（内容实为 index.html）镜像/部署到根目录。**任何以 deploy 为 cwd 启动的 node 进程都会被它炸掉**（ship-to-pages 6/7 的远端复核因此崩）。修法：从项目根跑 node，`--local`/`--tree` 全部传盘符绝对路径；skill 改进方向：verify-remote-blobs 调用点固定 cwd 为脚本目录 |
| `git clone file:///C:/...` 报 "does not appear to be a git repository" | Git Bash 把 `file:///C:/...` 改写成 `/C:/...`。**用相对路径**（`git clone ./deploy verify-clone`）最稳 |

---

## 7. MSYS 路径喂给 Windows 原生二进制（gh / node）⭐ 与 §1 同源

**症状**（三种，看起来毫不相干，其实是同一个根因）

```
# ① node 找不到模块
Error: Cannot find module 'C:\c\Users\69063\...\verify-bytes.mjs'

# ② node 说路径不是目录
FATAL: --check 不是目录: /c/Users/69063/.../deploy

# ③ gh 说未登录（同 §1）
You are not logged into any GitHub hosts.
```

**根因**：Git Bash 的 `/c/Users/…` 是 **MSYS 虚拟路径**，只在 MSYS 自己的环境里有效。

- **node**：收到 `/c/Users/x/verify-bytes.mjs` 会把它当成**当前盘符下的相对路径**，拼成 `C:\c\Users\x\verify-bytes.mjs` → MODULE_NOT_FOUND。
- **gh**：拿到 `/c/…` 直接解析失败，症状与"没登录"一样（见 §1）。

共同点：**Git Bash 变量展开产出 `/c/…`，Windows 原生二进制不认。**

### 实测数据（本机复核，别靠印象）

```
node -e "fs.existsSync('/c/Users/69063')"        → true   ⚠️ 见下方"更坏的形态"
node -e "fs.realpathSync('/c/Users/69063')"      → C:\c\Users\69063
node -e "fs.existsSync('/c/Users/69063/WorkBuddy/…/deploy')" → false  （目录不存在）
node -e "fs.existsSync('/c/Windows')"            → false  （C:\c\Windows 不存在）
```

**Git Bash 不会替你自动转换。** 实测把 `/c/Users/…` 作为参数传给 `node.exe`，node 的 `process.argv` 收到的就是**原封不动的** `/c/Users/…`（v22.22.2）。所以"MSYS 应该会自动转路径"这个直觉是错的。

**⚠️ 更坏的形态：`C:\c\…` 一旦存在，就不再报错，而是静默读错文件。**

本机 `C:\c\Users\69063\.hermes\…` 是历史上某次误用 MSYS 路径装东西时**真的建出来的**目录（2025-08-04）。它的后果是：

```js
fs.existsSync('/c/Users/69063')   // → true  —— 但不是你以为的那个 C:\Users\69063！
```

于是脚本不会崩，它会**愉快地在 `C:\c\Users\69063\…` 里读写**——校验通过、文件生成、报告全绿，内容是错的。这类假绿比崩溃难查一个数量级。

**自检时看到 `C:\c\` 出现，先别删（可能是别人的安装），但要立刻知道：路径归一化不能再靠"反正会报错"兜底。**

**修法**：跨边界前先转成 Windows 盘符形式（`C:/…`，**正斜杠没问题**）。

```bash
# 单次转换
cygpath -m "$HOME"                    # → C:/Users/69063

# 在脚本里：定义一个 winpath 助手，凡是交给 .exe 的路径都过一遍
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
HERE_NODE="$(winpath "$HERE")"
node "$HERE_NODE/scripts/verify-bytes.mjs" --ref "$(winpath "$REF")" --check "$(winpath "$SRC")"
node "$HERE_NODE/scripts/verify-remote-blobs.mjs" --tree "$TREE" --local "$(winpath "$SRC")"
```

**经验法则**：凡是**要传参给 `.exe` 的路径**（node、gh、chrome），一律先 `cygpath -m`；凡是**只在 Bash 内部用的路径**（`ls` / `cp` / `rm`），保持 `/c/…` 即可。

**⚠️ 例外：git 不是原型**。Git for Windows 自带 MSYS 运行时，**认 `/c/…`**——所以 `cd "$SRC" && git add -A` 一直是对的。别因为 node 炸了就把 git 的调用也一起改坏。

**副作用：`path.join()` 会产出"无盘符绝对路径"**

```js
path.join('/c/Users/x', 'a.html')   // → '\c\Users\x\a.html'
```

开头反斜杠、没有盘符 —— 这是**当前盘符根目录下的相对路径**。传到别的盘（比如 `D:`）上跑，它会去 `D:\c\Users\x\a.html` 找文件。所以归一化必须发生在**入口处（argv 解析后立即）**，不是等 `path.join` 之后。

**脚本侧也要容错**：`scripts/verify-bytes.mjs` 内置了归一化，把误传进来的 `/c/…` 转回盘符形式，**并且真的用归一化后的值**（只校验不赋值是假修，见下）。

```js
const msys = (p) =>
  process.platform === "win32" && typeof p === "string" && /^\/[a-zA-Z]\//.test(p)
    ? p[1].toUpperCase() + ":" + p.slice(2) : p;
// ⚠️ 关键：校验之后必须真的用下去，否则等于没修
ref = msys(ref); check = msys(check);
```

**反向教训**：先给变量做合法性校验、再把**原值**拿去用，是这类修复的经典假绿形态——`if (!isDir(msys(p))) die()` 通过之后仍然 `readdirSync(p)`，照样炸。修完要**跑一遍真命令**确认，不能只看代码像对。

本轮实测对照（`ship-to-pages.sh` 第 6 步的真实调用点）：

```
# 旧：--local "$SRC"（$SRC 由 cd+pwd 得到，是 /c/…）
FATAL: --local 不是目录: /c/Users/69063/…/dict2json-rebuild/deploy
exit=2

# 新：--local "$(winpath "$SRC")"
一致 130/130
✓ 远端 blob sha 与本地完全一致
exit=0
```

---

## 开工前 30 秒自检

```bash
# ① gh：直接用盘符形式探测，别用 $HOME/…（§1）
export GH_CONFIG_DIR="$(cygpath -m "$HOME")/AppData/Roaming/GitHub CLI"
echo "GH_CONFIG_DIR=$GH_CONFIG_DIR"
gh auth status 2>&1 | head -3      # 期望 "✓ Logged in to github.com account <你> (keyring)"

# ② node：确认能拿到盘符路径（§7）
node -v 2>/dev/null || ls -d "$HOME"/.workbuddy/binaries/node/versions/*/node.exe
echo "cygpath -m \$HOME = $(cygpath -m "$HOME")"   # 期望 C:/Users/<你>，不是 /c/Users/<你>

# ③ Chrome（headless 门需要）
ls "/c/Program Files/Google/Chrome/Application/chrome.exe" 2>/dev/null && echo "Chrome OK"

# ④ 代理
env | grep -i proxy || echo "无代理"
```

判定顺序说明：

- ① 若打印 `not logged in`，**先怀疑路径形式**（`$GH_CONFIG_DIR` 是不是 `/c/…` 开头），再考虑是否真的要重新授权。`hosts.yml` 里没有 `oauth_token` 不是判据（token 在 keyring）。
- ② `echo` 出来若是 `/c/Users/…`，说明后续所有传给 node/gh 的路径都得自己 `cygpath -m`。
- 若输出里出现 `C:\c\Users\…` 之类的拼接痕迹，是 §7 的 MODULE_NOT_FOUND 前兆。
