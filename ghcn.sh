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

# ---------------------------------------------------------------------------
# 测速用什么文件、量什么指标
#   踩过的坑：原来用 20KB 小文件比"耗时"，那只量到延迟、量不到吞吐 ——
#   直连下 20KB 不到 1 秒（看着最快），真去下 5MB 时只有 24KB/s，花了 2 分 53 秒。
#   现在改成：限时下载一个真实的大文件，比"固定时间内谁拉到的字节多"（吞吐量）。
# ---------------------------------------------------------------------------
GHCN_TEST_URL="${GHCN_TEST_URL:-https://github.com/ginuerzh/gost/releases/download/v2.11.2/gost-linux-amd64-2.11.2.gz}"
# 每个地址最多下多少秒（这段时间里拉到的字节数就是它的吞吐量）
GHCN_PROBE_TIME="${GHCN_PROBE_TIME:-6}"
# 至少拉到这么多字节才算这个地址可用（避免把错误页或几乎不通的当成可用）
GHCN_TEST_MIN="${GHCN_TEST_MIN:-100000}"
# 兼容旧变量名：GHCN_TIMEOUT 仍然接受
GHCN_TIMEOUT="${GHCN_TIMEOUT:-10}"
# 优先用 IPv4。raw.githubusercontent.com 的 IPv6 在国内经常是黑洞，
# wget/curl 会卡在 "HTTP request sent, awaiting response..." 再也不返回。
# 1=优先 IPv4（连不上会自动放开重试）；0=不特殊处理
GHCN_IPV4="${GHCN_IPV4:-1}"
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
  # 配置目录建不出来不算致命：警告一下继续，否则调用方脚本开了 set -e 会被直接带崩
  mkdir -p "$GHCN_DIR" 2>/dev/null || { ghcn_warn "无法创建配置目录 $GHCN_DIR（本次选择不会被记住）"; return 0; }
  {
    echo "# ghcn.sh 配置文件 —— 由 ./ghcn.sh use <编号> 等命令自动生成"
    echo "# MODE 可选: auto(自动测速) / fixed(固定某个) / direct(直连)"
    echo "MODE=$GHCN_MODE"
    echo "MIRROR=$GHCN_MIRROR"
  } > "$GHCN_CONF"
  return 0
}

ghcn__curl_probe() {
  # $1 = url，$2 = 额外 curl 参数（可为空串）
  local url="$1" extra="${2:-}" insecure=""
  [ "${GHCN_INSECURE:-1}" = "1" ] && insecure="-k"
  # shellcheck disable=SC2086
  curl -s $insecure -L $extra --max-time "$GHCN_PROBE_TIME" -o /dev/null \
       -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null
}

ghcn_probe() {
  # 用法: ghcn_probe <前缀>
  # 输出: "状态码 下载字节数 耗时秒 字节每秒"
  # 关键：量的是"固定时间内下了多少字节"（吞吐量），不是"下完一个小文件花了几秒"（延迟）。
  # 用 20KB 小文件测延迟会把直连选成"最快"，结果真下 5MB 时只有 24KB/s —— 这个坑实测踩过。
  local prefix="$1" url r
  ghcn_has curl || { ghcn_err "测速需要 curl，请先安装：apt install -y curl  或  yum install -y curl"; return 1; }
  url="${prefix}${GHCN_TEST_URL}"
  if [ "${GHCN_IPV4:-1}" = "1" ]; then
    r="$(ghcn__curl_probe "$url" "-4")"
    case "$r" in
      "000 "*|""|"000") r="$(ghcn__curl_probe "$url" "")" ;;   # IPv4 连不上就放开地址族重试
    esac
  else
    r="$(ghcn__curl_probe "$url" "")"
  fi
  printf '%s %s\n' "$r" "$(ghcn_bps "$r")"
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
  local best_prefix="" best_bps=0 i=-1 n prefix label result bps

  [ "$quiet" = "quiet" ] || ghcn_msg "开始实测吞吐量：每个地址限时 ${GHCN_PROBE_TIME}s，比谁在这段时间里拉到的字节多（这才代表真实下载速度）"

  n=${#GHCN_URLS[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -lt 0 ]; then
      prefix="$GHCN_DIRECT"; label="直连 GitHub"
    else
      prefix="${GHCN_URLS[$i]}"; label="$prefix"
    fi
    result="$(ghcn_probe "$prefix")"
    if ghcn_probe_ok "$result"; then
      bps="$(printf '%s' "$result" | awk '{print $4 + 0}')"
      [ "${bps:-0}" -gt 0 ] || bps=0
      [ "$quiet" = "quiet" ] || printf '  %-38s %s%-10s%s\n' "$label" "$(ghcn_color green)" "$(ghcn_human "$bps")" "$(ghcn_color off)" >&2
      if [ "$bps" -gt "$best_bps" ]; then
        best_bps="$bps"
        best_prefix="$prefix"
      fi
    else
      [ "$quiet" = "quiet" ] || printf '  %-38s %s%s%s\n' "$label" "$(ghcn_color red)" "不通 / 太慢" "$(ghcn_color off)" >&2
    fi
    i=$((i + 1))
  done

  if [ "${best_bps:-0}" -le 0 ]; then
    ghcn_warn "所有地址都没测通（或都慢到拉不到 ${GHCN_TEST_MIN} 字节），建议手动指定一个反代。"
    printf '%s\n' "$GHCN_DIRECT"
    return 1
  fi
  if [ -z "$best_prefix" ]; then
    ghcn_msg "最快的是：直连 GitHub   $(ghcn_human "$best_bps")"
  else
    ghcn_msg "最快的是：$best_prefix   $(ghcn_human "$best_bps")"
  fi
  printf '%s\n' "$best_prefix"
}

# ---------------------------------------------------------------------------
# 6.6 吞吐量格式化
# ---------------------------------------------------------------------------
ghcn_bps() {
  # $1 = "状态码 字节 耗时" -> 打印整数 字节/秒
  printf '%s' "$1" | awk '{ t = $3 + 0; if (t <= 0) t = 0.001; printf "%d", ($2 + 0) / t }'
}

ghcn_human() {
  # $1 = 字节/秒 -> 人类可读
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1048576)   printf "%.2f MB/s", b / 1048576;
    else if (b >= 1024) printf "%.0f KB/s", b / 1024;
    else                printf "%.0f B/s",  b;
  }'
}

# ---------------------------------------------------------------------------
# 6.7 让用户自己选反代（安装脚本里用这个，而不是偷偷自动测速）
#     为什么要交互：自动测速要等几十秒，而且"测速快"和"现在真能用"经常不是一回事。
#     把清单摊开、让用户自己点，最不容易出意外；直接回车才是自动测速。
# ---------------------------------------------------------------------------
ghcn_choose() {
  # 用法: prefix="$(ghcn_choose "用途说明")"
  # 输出: 选中的反代前缀（选直连时是空行）
  local purpose="${1:-下载}"
  local i=0 n=${#GHCN_URLS[@]} choice cur mark picked

  # 1) 已经有明确的反代（环境变量指定，或上次选过并记住了）→ 直接用，不重复问。
  #    注意这里判断的是"非空"，不是"变量是否已定义"：变量被定义成空串时必须继续
  #    往下弹菜单，否则就会重演"反代一直是空的、静默走直连"的老问题。
  #    想每次安装都重新问一遍：GHCN_ALWAYS_ASK=1
  if [ -n "${GHCN_PROXY:-}" ] && [ "${GHCN_ALWAYS_ASK:-0}" != "1" ]; then
    ghcn_msg "沿用已选定的加速地址：$GHCN_PROXY"
    ghcn_msg "（想换一个：运行 ./ghcn.sh 重新选择，或临时用 GHCN_PROXY=<地址> 跑本脚本）"
    printf '%s\n' "$GHCN_PROXY"; return 0
  fi
  # 2) 非交互环境（管道 / 定时任务 / CI）自动退回按配置解析
  if [ "${GHCN_NO_PROMPT:-0}" = "1" ] || [ ! -t 0 ]; then
    ghcn_resolve; return 0
  fi

  ghcn_config_load
  cur="$(ghcn_peek)"

  # 菜单写到 stderr：这样 $(ghcn_choose) 的 stdout 只含"选中的前缀"这一个值
  {
    printf '\n%s请选择用哪个加速地址来%s：%s\n' "$(ghcn_color bold)" "$purpose" "$(ghcn_color off)"
    printf '    %-4s %-38s %s\n' "编号" "地址" "说明"
    printf '    %-4s %-38s %s\n' "0" "直连 GitHub（不使用反代）" "服务器能直连时选它"
    while [ "$i" -lt "$n" ]; do
      mark=""
      [ "${GHCN_URLS[$i]}" = "$cur" ] && mark="   <= 上次用的"
      printf '    %-4s %-38s %s%s\n' "$((i + 1))" "${GHCN_URLS[$i]}" "${GHCN_NOTES[$i]}" "$mark"
      i=$((i + 1))
    done
    printf '    %-4s %-38s %s\n' "A" "自动测速（比吞吐量，最准）" "约 $(( (n + 1) * GHCN_PROBE_TIME )) 秒"
    printf '    %-4s %-38s %s\n' "S" "跳过，沿用上次的设置" "${cur:-（当前：直连）}"
    printf '\n请输入编号或字母 [直接回车 = A 自动测速]: '
  } >&2

  read -r choice
  case "$choice" in
    ""|a|A)
      picked="$(ghcn_speedtest)" || picked=""
      GHCN_MODE="fixed"; GHCN_MIRROR="$picked"; ghcn_config_save
      ;;
    s|S)
      picked="$cur"
      ;;
    0)
      picked=""
      GHCN_MODE="direct"; GHCN_MIRROR=""; ghcn_config_save
      ghcn_msg "已选：直连 GitHub（不使用反代）"
      ;;
    *[!0-9]*)
      ghcn_warn "输入无效（$choice），改用自动测速"
      picked="$(ghcn_speedtest)" || picked=""
      GHCN_MODE="fixed"; GHCN_MIRROR="$picked"; ghcn_config_save
      ;;
    *)
      if [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
        picked="${GHCN_URLS[$((choice - 1))]}"
        GHCN_MODE="fixed"; GHCN_MIRROR="$picked"; ghcn_config_save
        ghcn_msg "已选：$picked"
      else
        ghcn_warn "编号 $choice 超出范围，改用自动测速"
        picked="$(ghcn_speedtest)" || picked=""
        GHCN_MODE="fixed"; GHCN_MIRROR="$picked"; ghcn_config_save
      fi
      ;;
  esac
  printf '%s\n' "$picked"
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
  local full="$1" out="$2" insecure="" ipv4=""
  [ "${GHCN_INSECURE:-1}" = "1" ] && insecure="-k"
  [ "${GHCN_IPV4:-1}" = "1" ] && ipv4="-4"

  if ghcn_has curl; then
    # 先按 IPv4 下载（raw.githubusercontent.com 的 IPv6 在国内经常是黑洞，
    # 会卡在 "HTTP request sent, awaiting response..." 再也不返回）
    # shellcheck disable=SC2086
    curl -s $insecure $ipv4 -fL --retry 2 --connect-timeout 10 --max-time 900 \
         --progress-bar -o "$out" "$full" && [ -s "$out" ] && return 0
    if [ -n "$ipv4" ]; then
      ghcn_warn "IPv4 没连上，放开地址族再试一次……"
      # shellcheck disable=SC2086
      curl -s $insecure -fL --retry 2 --connect-timeout 10 --max-time 900 \
           --progress-bar -o "$out" "$full" && [ -s "$out" ] && return 0
    fi
    return 1
  elif ghcn_has wget; then
    if [ -n "$ipv4" ]; then
      # shellcheck disable=SC2086
      wget -q $insecure -4 --show-progress --timeout=30 --tries=2 -O "$out" "$full" && [ -s "$out" ] && return 0
      ghcn_warn "IPv4 没连上，放开地址族再试一次……"
    fi
    # shellcheck disable=SC2086
    wget -q $insecure --show-progress --timeout=30 --tries=2 -O "$out" "$full" && [ -s "$out" ] && return 0
    return 1
  else
    ghcn_err "需要 curl 或 wget，请先安装。"
    return 1
  fi
}

# 公开版下载函数，给项目脚本直接调用（已带反代前缀、IPv4 优先、失败自动换镜像）
ghcn_fetch() {
  # 用法: ghcn_fetch <完整URL> <输出文件>
  ghcn__fetch "$1" "$2"
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
