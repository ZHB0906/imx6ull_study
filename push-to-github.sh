#!/bin/bash
#
# push-to-github.sh —— 一条命令把本工程推到 GitHub
#
# 前提（用户侧两件事 ✓）：
#   ① 把公钥加到 GitHub：https://github.com/settings/keys → New SSH key
#      公钥内容见 ~/.ssh/id_ed25519_github.pub
#   ② 在 GitHub 上建一个**空仓库**（★ 不要勾 README / .gitignore / license ✗，
#      否则会和本地历史冲突 ✗）
#
# 用法：
#   bash push-to-github.sh <GitHub用户名> <仓库名>
#   例：bash push-to-github.sh zhanghaibin imx6ull-atk-port
#
set -e

U="${1:?用法: bash push-to-github.sh <GitHub用户名> <仓库名>}"
R="${2:?用法: bash push-to-github.sh <GitHub用户名> <仓库名>}"

cd "$(dirname "$0")"

echo "=== ① 验证 SSH 身份（要看到 Hi <用户名>! You've successfully authenticated ✓）==="
ssh -o StrictHostKeyChecking=no -T git@github.com 2>&1 | head -2 || true

echo
echo "=== ② 配置 remote ==="
git remote remove origin 2>/dev/null || true
git remote add origin "git@github.com:${U}/${R}.git"
git remote -v

echo
echo "=== ③ 推送 master（首次约 50MB ✓ 走 SSH 443/22 ✓）==="
git push -u origin master

echo
echo "=== ✓ 完成 ==="
echo "    仓库地址: https://github.com/${U}/${R}"
echo "    后续更新: git add <文件> && git commit -m '说明' && git push"
