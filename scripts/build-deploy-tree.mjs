#!/usr/bin/env node
/**
 * build-deploy-tree.mjs — 从复刻产物生成 GitHub Pages 发布树
 *
 * 用法：
 *   node build-deploy-tree.mjs --src <产物目录> --out <发布目录> [选项]
 *
 * 选项：
 *   --domain <域名>       写入 CNAME（省略则不写，表示只发布到 <user>.github.io/<repo>/）
 *   --repo   <owner/repo> 写进默认 README
 *   --title  <标题>       写进默认 README
 *   --desc   <描述>       写进默认 README
 *   --no-readme           不生成 README.md
 *   --dry-run             只打印将要做什么，不落盘
 *   --force               允许清空已存在的 --out（含 .git 时默认拒绝，保护仓库历史）
 *
 * 固定产出：
 *   CNAME           自定义域名（仅当给了 --domain）
 *   .nojekyll       阻止 Jekyll 处理（否则下划线开头的目录会被吞掉）
 *   .gitattributes  `* -text` —— 禁用一切 EOL 转换与文本规范化，锁死字节保真
 */
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const argv = process.argv.slice(2);
function flag(name) { return argv.includes("--" + name); }
function arg(name, def = undefined) {
  const i = argv.indexOf("--" + name);
  if (i === -1) return def;
  const v = argv[i + 1];
  return v === undefined || v.startsWith("--") ? true : v;
}

const src = arg("src");
const out = arg("out");
const domain = arg("domain");
const repo = arg("repo");
const title = arg("title") || "静态站点";
const desc = arg("desc") || "";
const noReadme = flag("no-readme");
const dryRun = flag("dry-run");
const force = flag("force");

if (!src || !out) {
  console.error(`用法: node build-deploy-tree.mjs --src <产物目录> --out <发布目录> [--domain 域名] [--repo owner/repo] [--title 标题] [--desc 描述] [--no-readme] [--dry-run]`);
  process.exit(2);
}
if (!fs.existsSync(src) || !fs.statSync(src).isDirectory()) {
  console.error(`FATAL: --src 不是目录: ${src}`);
  process.exit(2);
}
if (path.resolve(src) === path.resolve(out)) {
  console.error(`FATAL: --src 与 --out 不能是同一个目录（会被清空）`);
  process.exit(2);
}

// --- 扫描源目录 ---
const SKIP_DIRS = new Set([".git", "node_modules"]);
function walk(dir, base = dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory() && SKIP_DIRS.has(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, base, acc);
    else if (e.isFile()) acc.push(path.relative(base, p).split(path.sep).join("/"));
  }
  return acc;
}
const files = walk(src).sort();

// --- 拒绝明显危险的发布树 ---
if (files.length === 0) {
  console.error(`FATAL: --src 目录为空: ${src}`);
  process.exit(2);
}
if (!files.some((f) => f === "index.html")) {
  console.warn(`⚠ 警告: 源目录里没有 index.html —— GitHub Pages 根路径会 404。确认产物是否正确。`);
}
const skipped = fs.readdirSync(src, { withFileTypes: true })
  .map((e) => e.name)
  .filter((n) => SKIP_DIRS.has(n));
if (skipped.length) console.log(`(跳过不发布的目录: ${skipped.join(", ")})`);

console.log(`源目录: ${src}`);
console.log(`发布树: ${out}`);
console.log(`文件数: ${files.length}`);
if (dryRun) {
  for (const f of files) console.log(`  ${f}`);
  console.log(`\n(dry-run，未落盘)`);
  process.exit(0);
}

// --- 重建发布树（含删除保护）---
const resolvedOut = path.resolve(out);
const rootDir = path.parse(resolvedOut).root;
const segs = resolvedOut.slice(rootDir.length).split(/[\\/]/).filter(Boolean);
if (segs.length < 1) {
  console.error(`FATAL: --out 指向磁盘根目录（${resolvedOut}），拒绝操作。`);
  process.exit(2);
}
if (fs.existsSync(resolvedOut)) {
  const ents = fs.readdirSync(resolvedOut);
  if (ents.includes(".git") && !force) {
    console.error(`FATAL: --out 里已有 .git（${resolvedOut}）。清空会丢掉仓库历史与 remote。`);
    console.error(`  确认要重建请加 --force，或先手动移走/备份。`);
    process.exit(2);
  }
  const looksLikeDeploy = ents.length === 0 || ents.some((e) => ["index.html", ".gitattributes", ".nojekyll", "CNAME"].includes(e));
  if (!looksLikeDeploy && !force) {
    console.error(`FATAL: --out 已存在且不像发布树（含: ${ents.slice(0, 8).join(", ")}${ents.length > 8 ? " …" : ""}）。拒绝清空。`);
    console.error(`  确认要覆盖请加 --force。`);
    process.exit(2);
  }
}

fs.rmSync(resolvedOut, { recursive: true, force: true });
fs.mkdirSync(resolvedOut, { recursive: true });
for (const e of fs.readdirSync(src, { withFileTypes: true })) {
  if (e.isDirectory() && SKIP_DIRS.has(e.name)) continue;
  fs.cpSync(path.join(src, e.name), path.join(out, e.name), { recursive: true });
}

// --- 固定文件 ---
if (domain && domain !== true) {
  fs.writeFileSync(path.join(out, "CNAME"), domain + "\n");
  console.log(`+ CNAME            ${domain}`);
}
fs.writeFileSync(path.join(out, ".nojekyll"), "");
console.log(`+ .nojekyll        (空文件，阻止 Jekyll 处理)`);
fs.writeFileSync(
  path.join(out, ".gitattributes"),
  "# 字节保真：禁止任何 EOL 转换与文本规范化\n# 若缺少此文件，git 会在检出时把 LF 转成 CRLF，静默改坏构建产物字节\n* -text\n"
);
console.log(`+ .gitattributes   * -text（禁用 EOL 转换）`);

if (!noReadme && !files.includes("README.md")) {
  const lines = [
    `# ${title}`,
    "",
    desc,
    "",
    domain && domain !== true ? `- 线上地址：https://${domain}` : "",
    repo && repo !== true ? `- 仓库：https://github.com/${repo}` : "",
    "",
    "## 部署",
    "",
    "本仓库是构建产物（静态站点）。推送到 `main` 分支即由 GitHub Pages 发布。",
    domain && domain !== true ? "自定义域名由根目录 `CNAME` 声明。" : "",
    "",
    "> `.gitattributes`（`* -text`）用于锁死字节保真，请勿删除——删掉会让 git 在检出时改写文件字节。",
    "",
  ].filter((l) => l !== "");
  fs.writeFileSync(path.join(out, "README.md"), lines.join("\n") + "\n");
  console.log(`+ README.md        (默认生成，可用 --no-readme 关闭)`);
}

// --- 汇报 ---
const sha256 = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
console.log(`\n发布树内容：`);
let total = 0;
for (const f of walk(out).sort()) {
  const p = path.join(out, f);
  const size = fs.statSync(p).size;
  total += size;
  console.log(`  ${String(size).padStart(10)}  ${sha256(p).slice(0, 16)}  ${f}`);
}
console.log(`\n共 ${walk(out).length} 个文件，${(total / 1024).toFixed(1)} KB`);
console.log(`下一步: node verify-bytes.mjs --ref "${src}" --check "${out}"`);
