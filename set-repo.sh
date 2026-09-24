#!/usr/bin/env bash
# ============================================================================
#  set-repo.sh —— 把这个包"改写成你自己的仓库"
#
#  作用：把三份 README 里所有一键命令、clone 地址、占位符，以及 gost.sh 里
#        "配套文件从哪拉"的地址，统一换成你自己的 GitHub 仓库。
#
#  用法：
#    ./set-repo.sh <GitHub用户名> <仓库名> [分支]
#
#  例：
#    ./set-repo.sh zhangsan my-cn-pack            # 分支默认 main
#    ./set-repo.sh zhangsan frp-tools master
#
#  默认按"完整包"布局处理（仓库根目录下有 frp-panel/ 和 Multi-EasyGost/ 两个子目录）。
#  如果你是单独建仓库，用 --flat-frp / --flat-gost 指定：
#    ./set-repo.sh zhangsan frp-panel-only --flat-frp   # 仓库根目录就是 frp-panel 的内容
# ============================================================================
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SELF_DIR" || { echo "[错误] 无法进入脚本目录" >&2; exit 1; }

# ---------- 参数 ----------
USER_NAME="${1:-}"
REPO_NAME="${2:-}"
BRANCH="${3:-main}"
FLAT_FRP=0
FLAT_GOST=0
DO_ZIP=0
for a in "$@"; do
  case "$a" in
    --flat-frp)  FLAT_FRP=1 ;;
    --flat-gost) FLAT_GOST=1 ;;
    --zip)       DO_ZIP=1 ;;
  esac
done
# 第三个位置被写成了开关（而不是分支名）时，分支回落到默认的 main
case "$BRANCH" in
  --*) BRANCH="main" ;;
esac

info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

if [ -z "$USER_NAME" ] || [ -z "$REPO_NAME" ]; then
  cat <<'EOF'
用法: ./set-repo.sh <GitHub用户名> <仓库名> [分支]

  例: ./set-repo.sh zhangsan my-cn-pack          # 分支默认 main
      ./set-repo.sh zhangsan frp-tools master

可选项:
  --flat-frp    仓库根目录直接就是 frp-panel 的内容（不是放在 frp-panel/ 子目录里）
  --flat-gost   仓库根目录直接就是 Multi-EasyGost 的内容

先确认你要做什么：
  · 传的是"完整包" cn-github-pack.zip  → 直接 ./set-repo.sh 用户名 仓库名
  · 传的是"单项目包" frp-panel-cn.zip   → ./set-repo.sh 用户名 仓库名 --flat-frp
  · 传的是"单项目包" Multi-EasyGost-cn.zip → ./set-repo.sh 用户名 仓库名 --flat-gost
EOF
  exit 1
fi

case "$USER_NAME" in
  *[!A-Za-z0-9-]*) err "GitHub 用户名只能包含字母、数字和减号：$USER_NAME"; exit 1 ;;
esac
case "$REPO_NAME" in
  *[!A-Za-z0-9._-]*) err "仓库名只能包含字母、数字、点、下划线和减号：$REPO_NAME"; exit 1 ;;
esac

# 自检：确认是在这个包里跑。
# 注意不能强制要求 README.md —— 单项目包根目录里的说明文件叫
# README-国内反代说明.md，写死 README.md 会导致单项目包直接被拒。
if [ ! -f "ghcn.sh" ] && [ ! -d "frp-panel" ] && [ ! -d "Multi-EasyGost" ]; then
  err "当前目录($SELF_DIR)看起来不是这个包。请把它和 ghcn.sh 放在同一目录后再跑。"
  exit 1
fi
if [ ! -f "README.md" ]; then
  warn "当前目录没有 README.md —— 单项目包的说明文件是 README-国内反代说明.md，"
  warn "主说明里的占位符会跳过，只改写各项目自己的 README 和脚本。"
fi

# ---------- 计算各种地址 ----------
FRP_PREFIX="frp-panel";     [ "$FLAT_FRP" = "1" ]  && FRP_PREFIX=""
GOST_PREFIX="Multi-EasyGost"; [ "$FLAT_GOST" = "1" ] && GOST_PREFIX=""

REPO_SLUG="$USER_NAME/$REPO_NAME"
REPO_HTTPS="https://github.com/$REPO_SLUG.git"
REPO_RAW="https://raw.githubusercontent.com/$REPO_SLUG/$BRANCH"

# 子目录的 raw 前缀（拼接时注意空前缀不要多出斜杠）
GOST_RAW_PREFIX="$REPO_RAW"
[ -n "$GOST_PREFIX" ] && GOST_RAW_PREFIX="$REPO_RAW/$GOST_PREFIX"
FRP_RAW_PREFIX="$REPO_RAW"
[ -n "$FRP_PREFIX" ] && FRP_RAW_PREFIX="$REPO_RAW/$FRP_PREFIX"

# 完整包里的 .gitignore 需要排除旧的 zip，顺便算一下 zip 名
ZIP_NAME="$REPO_NAME.zip"

info "目标仓库：$REPO_SLUG  分支：$BRANCH"
[ "$FLAT_FRP" = "1" ]  && info "frp-panel 按「仓库根目录」布局处理"
[ "$FLAT_GOST" = "1" ] && info "Multi-EasyGost 按「仓库根目录」布局处理"

# 备份，方便改错了回滚
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=".set-repo-backup-$STAMP"
mkdir -p "$BACKUP"
for f in README.md frp-panel/README.md Multi-EasyGost/README.md Multi-EasyGost/gost.sh install.sh; do
  [ -f "$f" ] && cp --parents "$f" "$BACKUP/" 2>/dev/null || { mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f" 2>/dev/null; }
done
info "已备份到 $BACKUP（改坏了可以从这里恢复）"

# 统一的替换函数（用 | 作分隔符，避免和路径里的 / 打架）
sub() {
  local file="$1" from="$2" to="$3"
  [ -f "$file" ] || return 0
  # 先判断文件里到底有没有，避免 sed 无谓地重写文件
  if grep -qF -- "$from" "$file" 2>/dev/null; then
    # 用 python 做替换，避免 sed 对特殊字符的转义问题（都是纯文本，不需要正则）
    python - "$file" "$from" "$to" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
s = s.replace(old, new)
with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(s)
PY
    printf '      · %s ：替换 %s\n' "$file" "$from"
  fi
}

echo
info "开始改写……"

# ---------- 1. 主 README ----------
sub "README.md" "<你的用户名>/<仓库名>" "$REPO_SLUG"
sub "README.md" "<你的用户名>/cn-github-pack" "$REPO_SLUG"
sub "README.md" "cd <仓库名>-main" "cd $REPO_NAME-$BRANCH"
sub "README.md" "cd <仓库名>" "cd $REPO_NAME"
sub "README.md" "把 <你的用户名>/<仓库名> 换成实际值" "把 <你的用户名>/<仓库名> 换成 $REPO_SLUG"
sub "README.md" "cd cn-github-pack" "cd $REPO_NAME"
sub "README.md" "\`cn-github-pack\` 文件夹" "\`$REPO_NAME\` 文件夹"
sub "README.md" "\`cn-github-pack\` 这一层文件夹" "\`$REPO_NAME\` 这一层文件夹"
sub "README.md" "**Repository name**：比如 \`cn-github-pack\`" "**Repository name**：\`$REPO_NAME\`"
sub "README.md" "把 \`cn-github-pack.zip\` 拖到下方的附件区" "把 \`$ZIP_NAME\` 拖到下方的附件区"
sub "README.md" "releases/download/v1.0/cn-github-pack.zip" "releases/download/v1.0/$ZIP_NAME"
sub "README.md" "git clone https://ghfast.top/https://github.com/$REPO_SLUG.git" "git clone https://ghfast.top/$REPO_HTTPS"
sub "README.md" "git remote add origin https://github.com/$REPO_SLUG.git" "git remote add origin $REPO_HTTPS"
sub "README.md" "git remote set-url origin git@github.com:$REPO_SLUG.git" "git remote set-url origin git@github.com:$REPO_SLUG.git"

# ---------- 2. frp-panel 的 README ----------
if [ -f "frp-panel/README.md" ]; then
  sub "frp-panel/README.md" "https://ghfast.top/https://github.com/ychenfen/frp-panel.git" "https://ghfast.top/$REPO_HTTPS"
  sub "frp-panel/README.md" "https://gh-proxy.com/https://github.com/ychenfen/frp-panel.git" "https://gh-proxy.com/$REPO_HTTPS"
  sub "frp-panel/README.md" "https://github.com/ychenfen/frp-panel.git" "$REPO_HTTPS"
  if [ "$FLAT_FRP" = "1" ]; then
    sub "frp-panel/README.md" "cd frp-panel" "cd $REPO_NAME"
  else
    sub "frp-panel/README.md" "cd frp-panel" "cd $REPO_NAME/frp-panel"
  fi
  sub "frp-panel/README.md" "https://raw.githubusercontent.com/ychenfen/frp-panel/main/scripts/install_frp.sh" "$FRP_RAW_PREFIX/scripts/install_frp.sh"
fi

# ---------- 3. Multi-EasyGost 的 README ----------
if [ -f "Multi-EasyGost/README.md" ]; then
  sub "Multi-EasyGost/README.md" \
      "https://ghfast.top/https://raw.githubusercontent.com/KANIKIG/Multi-EasyGost/master/gost.sh" \
      "https://ghfast.top/$GOST_RAW_PREFIX/gost.sh"
  # 注意：这里刻意不往一键命令里塞 cd。
  # 用户常常是"只 wget 了脚本、并没有 clone 整个仓库"，
  # 塞了 cd 就会 No such file or directory，后面的 && 全断掉（实测踩过这个坑）。
fi

# ---------- 4. gost.sh 里的 SELF_REPO_RAW ----------
if [ -f "Multi-EasyGost/gost.sh" ]; then
  sub "Multi-EasyGost/gost.sh" \
      'SELF_REPO_RAW="${SELF_REPO_RAW:-https://raw.githubusercontent.com/KANIKIG/Multi-EasyGost/master}"' \
      "SELF_REPO_RAW=\"\${SELF_REPO_RAW:-$GOST_RAW_PREFIX}\""
  sub "Multi-EasyGost/gost.sh" \
      "SELF_UPDATE_URL=https://raw.githubusercontent.com/你的用户名/你的仓库/main/gost.sh" \
      "SELF_UPDATE_URL=$GOST_RAW_PREFIX/gost.sh"
fi

# ---------- 5. install.sh 的路径示例注释 ----------
sub "install.sh" "/opt/cn-github-pack/install.sh" "/opt/$REPO_NAME/install.sh"

# ---------- 6. 输出最终的一键命令 ----------
echo
info "改写完成。以下是换好仓库名之后的「一键命令」，可以直接复制使用："
cat <<EOF

────────────────────────────────────────────────────────────
  ① 服务器上拉取整个包（推荐给国内服务器用）

    git clone https://ghfast.top/$REPO_HTTPS

  或者不用 git，直接下 zip：

    wget https://ghfast.top/https://github.com/$REPO_SLUG/archive/refs/heads/$BRANCH.zip
    unzip $BRANCH.zip && cd $REPO_NAME-$BRANCH

────────────────────────────────────────────────────────────
  ② 选反代 + 部署（在拉下来的目录里执行）

    chmod +x ghcn.sh install.sh
    ./ghcn.sh test        # 实测选最快的反代（首次约 10 秒）
    ./install.sh          # 交互式菜单，选要部署哪个项目

────────────────────────────────────────────────────────────
  ③ Multi-EasyGost 一键安装（不下载整个包，只拉脚本）

    wget --no-check-certificate -O gost.sh \\
      https://ghfast.top/$GOST_RAW_PREFIX/gost.sh && chmod +x gost.sh && ./gost.sh

────────────────────────────────────────────────────────────
  ④ frp-panel 脚本方式安装 FRP

    cd $REPO_NAME/${FRP_PREFIX:+$FRP_PREFIX/}   # 进入项目目录
    sudo -E bash scripts/install_frp.sh

────────────────────────────────────────────────────────────
  ⑤ 如果你把 zip 传到 Releases，服务器直接下 zip

    wget https://ghfast.top/https://github.com/$REPO_SLUG/releases/download/v1.0/$ZIP_NAME

────────────────────────────────────────────────────────────

  以上命令里的 https://ghfast.top/ 是反代前缀，随时可以换成：
    https://gh-proxy.com/   https://gh.llkk.cc/   https://gh.monlor.com/
    https://ghproxy.net/    https://gh.xxooo.cf/  https://gh.chjina.com/
  或者直接删掉前缀走直连（服务器能直连 GitHub 时最快）。

EOF

# ---------- 7. 可选：按新仓库名重新打包 ----------
if [ "$DO_ZIP" = "1" ]; then
  if ! command -v python >/dev/null 2>&1; then
    warn "本机没有 python，跳过重新打包。"
  else
    ZIP_OUT="$SELF_DIR/../$ZIP_NAME"
    python - "$SELF_DIR" "$ZIP_OUT" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames
                       if d not in ('.git', '__pycache__')
                       and not d.startswith('.set-repo-backup')]
        for f in filenames:
            if f.endswith('.zip'):
                continue
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, os.path.dirname(src))
            zi = zipfile.ZipInfo.from_file(full, rel)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = ((0o755 if f.endswith('.sh') else 0o644) | 0o100000) << 16
            with open(full, 'rb') as fh:
                z.writestr(zi, fh.read())
print("  已重新打包 -> " + dst)
PY
    info "zip 里的顶层目录名取自当前文件夹名（$(basename "$SELF_DIR")）。"
    info "想让解压出来的文件夹就叫 $REPO_NAME，先把当前文件夹重命名成 $REPO_NAME 再跑本脚本。"
  fi
fi
