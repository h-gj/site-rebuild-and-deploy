# site-rebuild-and-deploy

**复刻 → 上线一条龙**（Agent Skill）：给一个参考网站 URL，先 1:1 保真复刻，再把产物发布到 GitHub Pages 并绑定自定义域名。

| 层 | 负责 | 说明 |
|---|---|---|
| 复刻 | [website-rebuild](https://github.com/boyang-hu/website-rebuild-skill)（基础 skill） | 取证式复刻管线，六条宪法纪律 |
| 发布 | 本 skill `scripts/` | 发布树生成、字节保真校验、建仓推送开 Pages、远端 blob sha 复核 |
| 参考 | 本 skill `references/` | 阶段化命令清单、Windows 环境坑、排错速查 |

三段流程：**Phase A 复刻**（判级 → 镜像 → 逆向 → 重拼 → 五层验收门）→ **Phase B 发布包**（CNAME + .nojekyll + .gitattributes + 字节保真校验）→ **Phase C 上线**（建仓 → 推送 → Pages → 绑域名 → 远端复核 → DNS）。

内置实战踩坑手册：Windows + Git Bash 下 gh「假装未登录」（`GH_CONFIG_DIR` 盘符写法）、git LF→CRLF 静默改坏构建产物字节、MSYS 路径喂原生 exe 等。

## 使用

完整规格见 **[SKILL.md](SKILL.md)**。复刻段**必须加载基础 skill [website-rebuild](https://github.com/boyang-hu/website-rebuild-skill) 并按其全流程执行**。

安装：把本目录放入 skills 目录（如 `~/.workbuddy/skills/site-rebuild-and-deploy/`）。环境要求：Node 22+、npx、本地 Chrome/Chromium、`gh` CLI（已登录）。

## 法务边界

继承基础 skill，不可放宽：复刻产出默认私有 + noindex + 不公开部署；公开须用户明确决定 + 逐资产版权取证 + 标注「非官方复刻」。
