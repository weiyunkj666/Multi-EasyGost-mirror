#!/usr/bin/env bash
# ============================================================================
#  ghcn.sh —— GitHub 国内反代（加速镜像）选择 / 测速 / 下载 / 克隆 工具
#  版本: 1.0.0
#
#  作用：把 GitHub 的下载地址或 git clone 地址自动换成"国内可用的反代"，
#        支持手动指定用哪一个，也支持自动测速选最快的那个。
#
#  ---------------------------------------------------------------------------
#  作为命令行使用：
#    ./ghcn.sh                    交互式菜单（推荐，第一次用这个）
#    ./ghcn.sh list               列出全部反代
#    ./ghcn.sh test               实测全部反代速度，自动选出最快的并记住
#    ./ghcn.sh use 3              固定使用第 3 号反代
#    ./ghcn.sh auto               每次自动测速选最快（默认模式）
#    ./ghcn.sh off                直连 GitHub，不用反代
#    ./ghcn.sh show               查看当前生效的反代
#    ./ghcn.sh get <URL> [文件]   用当前反代下载任意 GitHub 地址
#    ./ghcn.sh clone <仓库> [目录]  用当前反代克隆，如 ychenfen/frp-panel
#
#  作为函数库使用（写在你自己的脚本里）：
#    . /path/to/ghcn.sh
#    prefix="$(ghcn_resolve)"     # 形如 https://gh-proxy.com/；直连时为空串
#    curl -L "${prefix}https://github.com/xxx/yyy/releases/download/v1/a.tar.gz" -o a.tar.gz
#    ghcn_clone ychenfen/frp-panel
# ============================================================================

GHCN_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# 1. 反代清单（顺序 = 优先级）
#    这些地址都经过实测：既支持 releases/archive 直链下载，也支持 git clone。
#    ghcn.sh 会自动跳过失效的，所以照抄即可，挂了不影响使用。
# ---------------------------------------------------------------------------
GHCN_URLS=(
  "https://gh-proxy.com/"
  "https://gh.llkk.cc/"
  "https://ghfast.top/"
  "https://gh.monlor.com/"
  "https://ghproxy.net/"
  "https://gh.xxooo.cf/"
  "https://gh.chjina.com/"
  "https://gh.ddlc.top/"
  "https://ghproxy.cxkpro.top/"
  "https://gh.jasonzeng.dev/"
  "https://ghproxy.imciel.com/"
  "https://ghfile.geekertao.top/"
)

GHCN_NOTES=(
  "老牌稳定，下载+clone 都支持"
  "速度快，下载+clone 都支持"
  "速度最快之一，下载+clone 都支持"
  "较稳定，下载+clone 都支持"
  "老牌，下载+clone 都支持"
  "较稳定，下载+clone 都支持"
  "国内节点，下载+clone 都支持"
  "下载快，clone 会跳转（可能失败）"
  "下载可用，clone 不保证"
  "下载可用，clone 不保证"
  "下载可用，clone 不保证"
  "下载可用（偶尔较慢）"
)

# 直连（不用任何反代）—— 对应菜单里的第 0 号
GHCN_DIRECT=""

# 测速用的目标文件（随便一个 20KB 左右的小文件即可，越小测速越快）
GHCN_TEST_URL="${GHCN_TEST_URL:-https://github.com/KANIKIG/Multi-EasyGost/archive/refs/heads/v2.zip}"
# 校验阈值：下载字节数大于这个值才算反代真的可用（避免把错误页当成成功）
GHCN_TEST_MIN="${GHCN_TEST_MIN:-10000}"
# 单个反代测速超时（秒）
GHCN_TIMEOUT="${GHCN_TIMEOUT:-10}"
# HTTPS 证书校验开关：1=跳过校验（默认，兼容证书库过旧的老服务器，与原项目 wget --no-check-certificate 行为一致）
#                    0=严格校验
GHCN_INSECURE="${GHCN_INSECURE:-1}"

# ---------------------------------------------------------------------------
# 2. 配置与缓存位置
# ---------------------------------------------------------------------------
GHCN_DIR="${GHCN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ghcn}"
GHCN_CONF="$GHCN_DIR/config"
GHCN_CACHE="$GHCN_DIR/cache"

# 当前生效配置（由 ghcn_config_load 填充）
GHCN_MODE="${GHCN_MODE:-auto}"     # auto | fixed | direct
GHCN_MIRROR="${GHCN_MIRROR:-}"     # fixed 模式下生效

# ---------------------------------------------------------------------------
# 3. 小工具函数
# ---------------------------------------------------------------------------
ghcn_has() { command -v "$1" >/dev/null 2>&1; }

ghcn_color() {
  # 输出颜色（非终端环境自动关闭，避免污染管道）
  if [ -t 1 ]; then
    case "$1" in
      red)    printf '\033[31m' ;;
      green)  printf '\033[32m' ;;
      yellow) printf '\033[33m' ;;
      blue)   printf '\033[36m' ;;
      bold)   printf '\033[1m' ;;
      off)    printf '\033[0m' ;;
    esac
  fi
}

ghcn_msg()  { printf '%s[信息]%s %s\n' "$(ghcn_color green)" "$(ghcn_color off)" "$*" >&2; }
ghcn_warn() { printf '%s[警告]%s %s\n' "$(ghcn_color yellow)" "$(ghcn_color off)" "$*" >&2; }
ghcn_err()  { printf '%s[错误]%s %s\n' "$(ghcn_color red)" "$(ghcn_color off)" "$*" >&2; }

# ---------------------------------------------------------------------------
# 4. 配置文件读写
# ---------------------------------------------------------------------------
ghcn_config_load() {
  [ -f "$GHCN_CONF" ] || return 0
  # 只读取我们认识的键，避免配置文件把环境搞坏
  local line key val
  while IFS= read -r line; do
    case "$line" in
      MODE=*|GHCN_MODE=*)   key=MODE;   val="${line#*=}" ;;
      MIRROR=*|GHCN_MIRROR=*) key=MIRROR; val="${line#*=}" ;;
      *) continue ;;
    esac
    val="${val%\"}"; val="${val#\"}"
    case "$key" in
      MODE)   [ -n "$val" ] && GHCN_MODE="$val" ;;
      MIRROR) GHCN_MIRROR="$val" ;;
    esac
  done < "$GHCN_CONF"
}

ghcn_config_save() {
  mkdir -p "$GHCN_DIR" 2>/dev/null || { ghcn_err "无法创建配置目录 $GHCN_DIR"; return 1; }
  {
    echo "# ghcn.sh 配置文件 —— 由 ./ghcn.sh use <编号> 等命令自动生成"
    echo "# MODE 可选: auto(自动测速) / fixed(固定某个) / direct(直连)"
    echo "MODE=$GHCN_MODE"
    echo "MIRROR=$GHCN_MIRROR"
  } > "$GHCN_CONF"
  return 0
}

# ---------------------------------------------------------------------------
# 5. 网络探测：返回 "状态码 字节数 耗时秒"
# ---------------------------------------------------------------------------
ghcn_probe() {
  # 用法: ghcn_probe <前缀> <完整URL>
  local prefix="$1" url="$2"
  if ! ghcn_has curl; then
    ghcn_err "测速需要 curl，请先安装：apt install -y curl  或  yum install -y curl"
    return 1
  fi
  if [ "${GHCN_INSECURE:-1}" = "1" ]; then
    curl -ksL --max-time "$GHCN_TIMEOUT" -o /dev/null \
         -w '%{http_code} %{size_download} %{time_total}' \
         "${prefix}${url}" 2>/dev/null
  else
    curl -sL --max-time "$GHCN_TIMEOUT" -o /dev/null \
         -w '%{http_code} %{size_download} %{time_total}' \
         "${prefix}${url}" 2>/dev/null
  fi
}

# 判断一次探测结果是否算"可用"
ghcn_probe_ok() {
  # 用法: ghcn_probe_ok "200 23002 1.23"
  local code size
  code="${1%% *}"
  size="$(printf '%s' "$1" | awk '{print $2}')"
  [ "$code" = "200" ] || return 1
  [ -n "$size" ] || return 1
  # 用 awk 做浮点比较
  awk -v s="$size" -v m="$GHCN_TEST_MIN" 'BEGIN{exit !(s+0 >= m+0)}'
}

# ---------------------------------------------------------------------------
# 6. 测速：遍历所有反代（含直连），返回最快的一个（含直连则参与比较）
# ---------------------------------------------------------------------------
ghcn_speedtest() {
  local quiet="${1:-}"
  local best_prefix="" best_time="" i n prefix result cur_time count=0

  [ "$quiet" = "quiet" ] || ghcn_msg "开始实测反代速度（每个最多 ${GHCN_TIMEOUT}s，目标文件约 20KB）..."

  # 先测直连，作为"反代到底有没有用"的参照
  result="$(ghcn_probe "$GHCN_DIRECT" "$GHCN_TEST_URL")"
  if ghcn_probe_ok "$result"; then
    best_time="$(printf '%s' "$result" | awk '{print $3}')"
    [ "$quiet" = "quiet" ] || printf '  %-34s %s✔%s  %ss\n' "直连 GitHub" "$(ghcn_color green)" "$(ghcn_color off)" "$best_time" >&2
  else
    best_time=""
    [ "$quiet" = "quiet" ] || printf '  %-34s %s✘%s  (%s)\n' "直连 GitHub" "$(ghcn_color red)" "$(ghcn_color off)" "$result" >&2
  fi

  n=${#GHCN_URLS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    prefix="${GHCN_URLS[$i]}"
    result="$(ghcn_probe "$prefix" "$GHCN_TEST_URL")"
    if ghcn_probe_ok "$result"; then
      count=$((count + 1))
      cur_time="$(printf '%s' "$result" | awk '{print $3}')"
      if [ -z "$best_time" ] || awk -v a="$cur_time" -v b="$best_time" 'BEGIN{exit !(a+0 < b+0)}'; then
        best_time="$cur_time"
        best_prefix="$prefix"
      fi
      [ "$quiet" = "quiet" ] || printf '  %-34s %s✔%s  %ss\n' "$prefix" "$(ghcn_color green)" "$(ghcn_color off)" "$cur_time" >&2
    else
      [ "$quiet" = "quiet" ] || printf '  %-34s %s✘%s  (%s)\n' "$prefix" "$(ghcn_color red)" "$(ghcn_color off)" "$result" >&2
    fi
    i=$((i + 1))
  done

  if [ -z "$best_time" ]; then
    ghcn_warn "所有反代和直连都测不通，稍后再试，或检查服务器网络/DNS。"
    printf '%s\n' "$GHCN_DIRECT"
    return 1
  fi

  if [ -z "$best_prefix" ]; then
    ghcn_msg "直连就是最快的（本机到 GitHub 通），继续用直连。"
  else
    ghcn_msg "最快的是：$best_prefix  用时 ${best_time}s"
  fi
  printf '%s\n' "$best_prefix"
}

# ---------------------------------------------------------------------------
# 6.5 缓存有效性校验
#     缓存是 ghcn_resolve 用来"跳过下次测速"的快捷路径，但它只是个普通文本文件，
#     可能被写坏（写到一半被中断、被别的程序改过、旧版本留下的格式）。
#     所以采信之前必须校验，否则会把一段垃圾字符串当成反代前缀拼进 URL。
# ---------------------------------------------------------------------------
ghcn_cache_fresh() {
  # $1 = 缓存里的 TIME 值：是"24 小时内的纯数字秒"才返回 0
  local ts="$1" now
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ -n "$now" ] || return 1
  [ $((now - ts)) -lt 86400 ]
}

ghcn_cache_valid() {
  # $1 = 缓存里的 MIRROR 值：空串（=直连）或 http(s):// 开头且不含空白才算合法
  local m="$1"
  [ -z "$m" ] && return 0
  case "$m" in *[[:space:]]*) return 1 ;; esac
  [ "${m#http}" != "$m" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# 7. 解析"当前该用哪个前缀" —— 这是给别的脚本调用的核心函数
#    输出：反代前缀字符串（直连时是一个空行）
# ---------------------------------------------------------------------------
ghcn_resolve() {
  # 环境变量 GHCN_PROXY 优先级最高（哪怕被设成空串，也代表明确要求直连）
  if [ -n "${GHCN_PROXY+x}" ]; then
    printf '%s\n' "$GHCN_PROXY"
    return 0
  fi

  ghcn_config_load

  case "$GHCN_MODE" in
    direct)
      printf '\n'
      return 0
      ;;
    fixed)
      printf '%s\n' "$GHCN_MIRROR"
      return 0
      ;;
  esac

  # auto 模式：优先用 24 小时内的缓存，避免每次部署都重新测速
  if [ -f "$GHCN_CACHE" ]; then
    local ts cached
    ts="$(awk -F= '/^TIME=/{print $2; exit}' "$GHCN_CACHE" 2>/dev/null)"
    cached="$(awk -F= '/^MIRROR=/{sub(/^MIRROR=/,"");print; exit}' "$GHCN_CACHE" 2>/dev/null)"
    if ghcn_cache_fresh "$ts" && ghcn_cache_valid "$cached"; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi

  local picked
  picked="$(ghcn_speedtest)" || true
  mkdir -p "$GHCN_DIR" 2>/dev/null
  {
    echo "TIME=$(date +%s)"
    echo "MIRROR=$picked"
  } > "$GHCN_CACHE" 2>/dev/null
  printf '%s\n' "$picked"
}

# 把一个 GitHub 地址套上当前反代
ghcn_wrap() {
  # 用法: ghcn_wrap https://github.com/xxx/yyy
  printf '%s%s\n' "$(ghcn_resolve)" "$1"
}

# ---------------------------------------------------------------------------
# 8. 下载 / 克隆（自动降级：当前反代失败就依次换其他的）
# ---------------------------------------------------------------------------
ghcn_download() {
  # 用法: ghcn_download <URL> [输出文件名]
  local url="$1" out="${2:-}" prefix
  [ -n "$url" ] || { ghcn_err "用法: ghcn_download <URL> [输出文件名]"; return 1; }
  [ -n "$out" ] || out="$(basename "${url%%\?*}")"

  prefix="$(ghcn_resolve)"
  if ghcn__fetch "${prefix}${url}" "$out"; then
    return 0
  fi

  ghcn_warn "用「${prefix:-直连}」下载失败，正在自动尝试其他反代..."
  local i n
  n=${#GHCN_URLS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${GHCN_URLS[$i]}" != "$prefix" ]; then
      ghcn_msg "换用 ${GHCN_URLS[$i]} ..."
      if ghcn__fetch "${GHCN_URLS[$i]}${url}" "$out"; then
        # 记住这个能用的反代
        GHCN_MODE="fixed"; GHCN_MIRROR="${GHCN_URLS[$i]}"; ghcn_config_save
        ghcn_msg "已切换并记录：${GHCN_URLS[$i]}"
        return 0
      fi
    fi
    i=$((i + 1))
  done

  ghcn_err "所有反代都下载失败：$url"
  return 1
}

ghcn__fetch() {
  # 内部：用 curl 或 wget 下载，成功返回 0
  # 注意：curl 没有 --no-check-certificate 这个参数（那是 wget 的），跳过校验要用 -k
  local full="$1" out="$2"
  if ghcn_has curl; then
    if [ "${GHCN_INSECURE:-1}" = "1" ]; then
      curl -kfL --retry 2 --connect-timeout 10 --max-time 600 --progress-bar -o "$out" "$full" && [ -s "$out" ]
    else
      curl -fL --retry 2 --connect-timeout 10 --max-time 600 --progress-bar -o "$out" "$full" && [ -s "$out" ]
    fi
  elif ghcn_has wget; then
    if [ "${GHCN_INSECURE:-1}" = "1" ]; then
      wget -q --show-progress --no-check-certificate --timeout=30 --tries=2 -O "$out" "$full" && [ -s "$out" ]
    else
      wget -q --show-progress --timeout=30 --tries=2 -O "$out" "$full" && [ -s "$out" ]
    fi
  else
    ghcn_err "需要 curl 或 wget，请先安装。"
    return 1
  fi
}

ghcn_clone() {
  # 用法: ghcn_clone <user/repo | 完整URL> [目标目录] [git 额外参数...]
  local repo="$1" dir="$2"; shift 2 2>/dev/null
  [ -n "$repo" ] || { ghcn_err "用法: ghcn_clone <user/repo> [目标目录]"; return 1; }

  # 允许直接传完整 URL
  case "$repo" in
    http*) ;;
    *) repo="https://github.com/${repo%.git}.git" ;;
  esac
  [ -n "$dir" ] || dir="$(basename "$repo" .git)"

  ghcn_has git || { ghcn_err "未安装 git，请先安装：apt install -y git"; return 1; }

  local prefix
  prefix="$(ghcn_resolve)"
  ghcn_msg "git clone 使用：${prefix:-直连 GitHub}"

  if git clone "$@" "${prefix}${repo}" "$dir"; then
    return 0
  fi

  ghcn_warn "克隆失败，正在自动尝试其他反代..."
  rm -rf "$dir"
  local i n
  n=${#GHCN_URLS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${GHCN_URLS[$i]}" != "$prefix" ]; then
      ghcn_msg "换用 ${GHCN_URLS[$i]} ..."
      if git clone "$@" "${GHCN_URLS[$i]}${repo}" "$dir"; then
        GHCN_MODE="fixed"; GHCN_MIRROR="${GHCN_URLS[$i]}"; ghcn_config_save
        ghcn_msg "已切换并记录：${GHCN_URLS[$i]}"
        return 0
      fi
      rm -rf "$dir"
    fi
    i=$((i + 1))
  done

  ghcn_err "所有反代都无法克隆 $repo"
  return 1
}

# ---------------------------------------------------------------------------
# 8.5 只读查看（不联网）—— 给"列清单 / 看设置"这类纯显示场景用，
#     免得为了打印一行字就跑一次完整测速。真正要干活时才调 ghcn_resolve。
# ---------------------------------------------------------------------------
ghcn_peek() {
  if [ -n "${GHCN_PROXY+x}" ]; then printf '%s\n' "$GHCN_PROXY"; return 0; fi
  ghcn_config_load
  case "$GHCN_MODE" in
    direct) printf '\n'; return 0 ;;
    fixed)  printf '%s\n' "$GHCN_MIRROR"; return 0 ;;
  esac
  if [ -f "$GHCN_CACHE" ]; then
    local ts cached
    ts="$(awk -F= '/^TIME=/{print $2; exit}' "$GHCN_CACHE" 2>/dev/null)"
    cached="$(awk -F= '/^MIRROR=/{sub(/^MIRROR=/,"");print; exit}' "$GHCN_CACHE" 2>/dev/null)"
    if ghcn_cache_fresh "$ts" && ghcn_cache_valid "$cached"; then
      printf '%s\n' "$cached"; return 0
    fi
  fi
  printf '\n'
}
# ---------------------------------------------------------------------------
# 9. 命令行界面
# ---------------------------------------------------------------------------
ghcn_cmd_list() {
  # 必须在当前 shell 里加载配置：$(ghcn_peek) 是子 shell，它对变量的修改传不回来
  ghcn_config_load
  local i=0 n=${#GHCN_URLS[@]} cur cur_desc
  cur="$(ghcn_peek)"
  case "$GHCN_MODE" in
    direct) cur_desc="直连 GitHub（不使用反代）" ;;
    *)      if [ -n "$cur" ]; then cur_desc="$cur"; else cur_desc="未确定（首次使用时会自动测速）"; fi ;;
  esac
  printf '\n%s可用反代清单%s（当前：%s）\n\n' "$(ghcn_color bold)" "$(ghcn_color off)" "$cur_desc"
  printf '  %-4s %-36s %s\n' "编号" "反代地址" "说明"
  printf '  %-4s %-36s %s\n' "----" "------------------------------------" "------------------------------"
  printf '  %-4s %-36s %s\n' "0" "(直连 GitHub，不用反代)" "服务器能直连时最快的选择"
  while [ "$i" -lt "$n" ]; do
    printf '  %-4s %-36s %s\n' "$((i + 1))" "${GHCN_URLS[$i]}" "${GHCN_NOTES[$i]}"
    i=$((i + 1))
  done
  printf '\n用法示例： ./ghcn.sh use 3      固定用第 3 个\n'
  printf '          ./ghcn.sh test       让脚本自己测速挑最快的\n\n'
}

ghcn_cmd_use() {
  local idx="$1"
  [ -n "$idx" ] || { ghcn_err "用法: ./ghcn.sh use <编号>   （编号见 ./ghcn.sh list）"; return 1; }
  if [ "$idx" = "0" ]; then
    GHCN_MODE="direct"; GHCN_MIRROR=""
    ghcn_config_save && ghcn_msg "已设为直连 GitHub（不使用反代）"
    return 0
  fi
  local n=${#GHCN_URLS[@]}
  if ! [ "$idx" -ge 1 ] 2>/dev/null || [ "$idx" -gt "$n" ]; then
    ghcn_err "编号 $idx 不存在，有效范围 0 ~ $n"
    return 1
  fi
  GHCN_MODE="fixed"; GHCN_MIRROR="${GHCN_URLS[$((idx - 1))]}"
  ghcn_config_save && ghcn_msg "已固定使用：$GHCN_MIRROR"
}

ghcn_cmd_auto() {
  GHCN_MODE="auto"; GHCN_MIRROR=""
  ghcn_config_save
  rm -f "$GHCN_CACHE" 2>/dev/null
  ghcn_msg "已设为自动模式，正在测速选出最快的..."
  local picked; picked="$(ghcn_resolve)"
  ghcn_msg "当前将使用：${picked:-直连 GitHub}"
}

ghcn_cmd_show() {
  # 必须在当前 shell 里加载配置：$(ghcn_peek) 是子 shell，它对变量的修改传不回来
  ghcn_config_load
  local cur cur_desc
  cur="$(ghcn_peek)"
  case "$GHCN_MODE" in
    direct) cur_desc="直连 GitHub（不使用反代）" ;;
    fixed)  cur_desc="$cur" ;;
    *)      if [ -n "$cur" ]; then cur_desc="$cur（上次测速结果）"; else cur_desc="未确定 —— 运行 ./ghcn.sh test 立即测速"; fi ;;
  esac
  printf '\n当前反代设置\n'
  printf '  模式     : %s   (auto=自动测速 / fixed=固定 / direct=直连)\n' "$GHCN_MODE"
  printf '  固定值   : %s\n' "${GHCN_MIRROR:-（未设置）}"
  printf '  实际会用 : %s\n' "$cur_desc"
  printf '  配置文件 : %s\n\n' "$GHCN_CONF"
}

ghcn_cmd_help() {
  cat <<'EOF'

ghcn.sh —— GitHub 国内反代选择/下载/克隆工具

  ./ghcn.sh                交互式菜单（第一次用推荐）
  ./ghcn.sh list           列出全部反代
  ./ghcn.sh test           实测全部反代速度，自动选最快并记住
  ./ghcn.sh use <编号>     固定使用某个反代（0 = 直连）
  ./ghcn.sh auto           每次自动测速选最快（默认）
  ./ghcn.sh off            直连 GitHub
  ./ghcn.sh show           查看当前设置
  ./ghcn.sh get <URL> [文件]     用反代下载任意 GitHub 地址
  ./ghcn.sh clone <仓库> [目录]  用反代 git clone，如 ychenfen/frp-panel

作为函数库引用：
  . ./ghcn.sh
  prefix="$(ghcn_resolve)"        # 反代前缀，直连时为空串
  echo "${prefix}https://github.com/xxx/yyy/archive/refs/heads/main.zip"

环境变量：
  GHCN_PROXY        临时指定前缀（会覆盖配置文件），如 GHCN_PROXY=https://ghfast.top/
  GHCN_TIMEOUT      单个反代测速超时秒数，默认 10
  GHCN_TEST_URL     测速用目标文件
EOF
}

ghcn_cmd_menu() {
  while :; do
    clear 2>/dev/null
    printf '\n%s============================================%s\n' "$(ghcn_color blue)" "$(ghcn_color off)"
    printf '%s   GitHub 国内反代工具 ghcn.sh v%s%s\n' "$(ghcn_color bold)" "$GHCN_VERSION" "$(ghcn_color off)"
    printf '%s============================================%s\n\n' "$(ghcn_color blue)" "$(ghcn_color off)"
    ghcn_config_load
    _cur="$(ghcn_peek)"; [ -n "$_cur" ] || _cur="未确定（选 1 测速）"
    printf '当前模式：%s   实际使用：%s\n\n' "$GHCN_MODE" "$_cur"
    printf '  1. 测速并自动选择最快的反代\n'
    printf '  2. 查看反代清单\n'
    printf '  3. 手动指定反代\n'
    printf '  4. 改为直连 GitHub\n'
    printf '  5. 测试下载（下载 20KB 测试文件验证是否真的能用）\n'
    printf '  0. 退出\n\n'
    printf '请选择 [0-5]: '
    read -r choice
    case "$choice" in
      1) ghcn_cmd_auto ;;
      2) ghcn_cmd_list ;;
      3) ghcn_cmd_list; printf '请输入编号: '; read -r idx; ghcn_cmd_use "$idx" ;;
      4) ghcn_cmd_use 0 ;;
      5) ghcn_msg "下载测试文件中..."; if ghcn_download "$GHCN_TEST_URL" "/tmp/ghcn-test.zip"; then ghcn_msg "下载成功：/tmp/ghcn-test.zip （$(wc -c < /tmp/ghcn-test.zip) 字节）"; else ghcn_err "下载失败"; fi ;;
      0) return 0 ;;
      *) ghcn_err "输入无效" ;;
    esac
    printf '\n按回车继续...'; read -r _dummy
  done
}

ghcn_main() {
  local cmd="${1:-menu}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    menu|"") ghcn_cmd_menu ;;
    list)    ghcn_cmd_list ;;
    test)    local p; p="$(ghcn_speedtest)"; GHCN_MODE="fixed"; GHCN_MIRROR="$p"; ghcn_config_save && ghcn_msg "已记住该反代（模式：fixed）" ;;
    use)     ghcn_cmd_use "$@" ;;
    auto)    ghcn_cmd_auto ;;
    off)     ghcn_cmd_use 0 ;;
    show)    ghcn_cmd_show ;;
    get)     ghcn_download "$@" ;;
    clone)   ghcn_clone "$@" ;;
    version|-v|--version) echo "ghcn.sh v$GHCN_VERSION" ;;
    help|-h|--help) ghcn_cmd_help ;;
    *) ghcn_err "未知命令: $cmd"; ghcn_cmd_help; return 1 ;;
  esac
}

# 只有"直接执行"时才跑主逻辑；被 source 引用时只提供函数，不产生任何副作用
if [ -n "${BASH_VERSION:-}" ]; then
  if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ghcn_main "$@"; fi
else
  case "${0##*/}" in
    ghcn.sh|ghcn) ghcn_main "$@" ;;
  esac
fi
