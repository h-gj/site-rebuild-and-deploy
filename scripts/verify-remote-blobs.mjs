#!/usr/bin/env node
/**
 * verify-remote-blobs.mjs — 复核 GitHub 上的 blob sha 与本地文件是否一致
 *
 * Git 的对象 id 规则：blob_sha1 = sha1("blob " + byteLength + "\0" + content)
 * 用它可以不下载文件就证明「远端存的和本地是同一份字节」——这是发布后最有力的字节保真证据。
 *
 * 用法：
 *   # 1) 先取远端树（路径 + sha）
 *   gh api "repos/<owner>/<repo>/git/trees/main?recursive=1" \
 *     --jq '.tree[] | select(.type=="blob") | .path + " " + .sha' > remote-tree.txt
 *   # 2) 复核
 *   node verify-remote-blobs.mjs --tree remote-tree.txt --local <deploy目录>
 *
 * 退出码：0 = 全部一致；1 = 有差异；2 = 参数错误
 */
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const argv = process.argv.slice(2);
function arg(n, d = undefined) {
  const i = argv.indexOf("--" + n);
  if (i === -1) return d;
  const v = argv[i + 1];
  return v === undefined || v.startsWith("--") ? true : v;
}

const treeFile = arg("tree");
const local = arg("local");
if (!treeFile || !local) {
  console.error("用法: node verify-remote-blobs.mjs --tree <remote-tree.txt> --local <本地目录>");
  process.exit(2);
}
if (!fs.existsSync(treeFile)) {
  console.error(`FATAL: 找不到 ${treeFile}`);
  console.error(`  先执行: gh api "repos/<owner>/<repo>/git/trees/main?recursive=1" --jq '.tree[] | select(.type=="blob") | .path + " " + .sha' > remote-tree.txt`);
  process.exit(2);
}
if (!fs.existsSync(local) || !fs.statSync(local).isDirectory()) {
  console.error(`FATAL: --local 不是目录: ${local}`);
  process.exit(2);
}

const lines = fs.readFileSync(treeFile, "utf8").trim().split(/\r?\n/).filter(Boolean);
if (!lines.length) {
  console.error(`FATAL: ${treeFile} 是空的 —— gh api 那一步可能失败了（检查 gh 登录态 / GH_CONFIG_DIR）`);
  process.exit(1);
}

let ok = 0;
const bad = [];
const missing = [];
let parsed = 0;
for (const line of lines) {
  const i = line.lastIndexOf(" ");
  if (i === -1) continue;
  const rel = line.slice(0, i).trim();
  const remoteSha = line.slice(i + 1).trim();
  // 只认"路径 + 40 位 hex sha1"。这一条同时挡掉了最常见的喂错：`gh api` 的原始
  // JSON 是**紧凑**的（键值之间没有空格），所以它整份只算 1 行、且 lastIndexOf(" ")
  // 返回 -1 —— 旧代码 `continue` 掉它，于是 0 个文件比对却报「✓ 完全一致」。
  if (!rel || !/^[0-9a-f]{40}$/.test(remoteSha)) continue;
  parsed++;
  const p = path.join(local, rel);
  if (!fs.existsSync(p)) { missing.push(rel); continue; }
  const buf = fs.readFileSync(p);
  const h = crypto.createHash("sha1")
    .update(Buffer.concat([Buffer.from(`blob ${buf.length}\0`), buf]))
    .digest("hex");
  if (h === remoteSha) ok++;
  else bad.push({ rel, remote: remoteSha.slice(0, 12), local: h.slice(0, 12), size: buf.length });
}

// ⛔ "没有可比的东西"不是通过。实测：把 `gh api ... > tree.json`（原始 JSON）而不是
// 文档里的 `--jq '.tree[] | select(.type=="blob") | .path + " " + .sha'` 文本喂进来，
// 解析出 0 行，旧代码照样打印「✓ 远端 blob sha 与本地完全一致」—— 一条全绿的假门，
// 而它守的正是"远端字节有没有被 git 改写"这件最该有人守的事。
if (!parsed) {
  console.error(`FATAL: ${treeFile} 里没有一行解析成 \`<path> <sha1>\` —— 没有可比的东西，不是通过。`);
  console.error(`  期望每行 \`<path> <40位sha1>\`，用文档给的那条命令生成：`);
  console.error(`    gh api "repos/<owner>/<repo>/git/trees/<branch>?recursive=1" \\`);
  console.error(`      --jq '.tree[] | select(.type=="blob") | .path + " " + .sha' > remote-tree.txt`);
  process.exit(2);
}

console.log(`远端树: ${treeFile}  (${parsed} 个 blob)`);
console.log(`本地树: ${local}`);
if (bad.length) {
  console.log("");
  for (const b of bad) console.log(`  MISMATCH  ${b.rel}   remote=${b.remote} local=${b.local}  (${b.size}B)`);
}
if (missing.length) {
  console.log("");
  for (const m of missing.slice(0, 10)) console.log(`  MISSING   ${m}`);
}
console.log("");
console.log(`一致 ${ok}/${parsed}` + (bad.length ? `  差异 ${bad.length}` : "") + (missing.length ? `  本地缺失 ${missing.length}` : ""));

if (bad.length || missing.length) {
  console.error(`\n✗ 远端字节复核失败`);
  console.error(`  差异常见原因：推送前漏了 .gitattributes（'* -text'），git 在检出/入库时改写了字节。`);
  process.exit(1);
}
console.log(`\n✓ 远端 blob sha 与本地完全一致：远端 ${ok} 个文件就是本地这 ${ok} 份字节`);
