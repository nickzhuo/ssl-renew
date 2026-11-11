#!/bin/bash
# =============================================================================
#  批量证书签发 / 续期（DNS-01 验证）
#  scripts/ssl/ssl-issue.sh
#
#  逐个处理 domains.conf 里的每一张证书：
#    ① 发起 ACME 请求  →  ② DNS 域名验证（自动增删 _acme-challenge TXT）→  ③ 部署证书
#
#  ★ 支持多个 DNS 服务商（腾讯云 DNSPod / GoDaddy）与多个账号：
#    每张证书按 domains.conf 里的 dns=<服务商> account=<账号> 选用对应凭据，
#    域名分散在不同服务商 / 不同账号下也能一次跑完。
#
#  ★ 续期决策由本脚本自己做，用的是每张证书自己的 renew 阈值，
#    不依赖 acme.sh 的内部调度。未到期的证书直接跳过，不会白跑 acme.sh。
#
#  ★ 续期后置动作：如果确实有证书被更新，会执行 scripts/ssl/renewpost.sh
#    （自动发现，不需要配 ssl.conf）。拿它重启 docker compose 服务、重启 nginx
#    之类的都可以 —— 模板见 renewpost.sh.example.docker / .example.nginx。
#
#  ★ 每次运行都会往 <证书目录>/renew.log 追加一行结果摘要，
#    因为 CentOS 8 的 systemd journal 默认不持久化，重启就查不到历史了。
#
#  用法:
#    ./ssl-issue.sh               # 遍历列表，该续期的续期，该跳过的跳过
#    ./ssl-issue.sh --check-only  # 只体检：每张证书的状态 + 将要执行的动作
#    ./ssl-issue.sh --list        # 只看解析后的证书列表
#    ./ssl-issue.sh --domain api.example.com --force   # 只强签某一张
#    ./ssl-issue.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

FORCE=0
STAGING=0
CHECK_ONLY=0
DEBUG=0
LIST_ONLY=0
ONLY_DOMAIN=""

FAILURES=()
SUMMARY=()
RELOAD_NEEDED=0
TARGET_FIRST=0
TARGET_LAST=0
TOTAL_TODO=0

# 运行摘要日志用
RUN_LOG_WRITTEN=0
POST_HOOK_STATE="未触发"
N_TOTAL=0
N_UPDATED=0
N_SKIPPED=0
N_FAILED=0

# 谁在跑：判断"这次是不是由 systemd 启动的"，写进日志，好一眼区分
# "半夜 03:17 的定时任务" 和 "我自己在终端手跑的"。
#
# ⚠️ 不能只看 ${INVOCATION_ID}：实测 CentOS 8.5(systemd 239) 的 service 进程里
#    这个变量是**空的**（InvocationID 作为 systemd 属性/日志字段是 232 起就有，
#    但作为**环境变量**导出给进程是更晚的事 —— 两者常被资料混为一谈）。
#    只靠它判断，定时任务会被**全部错标成"手动"**，让人以为从没自动跑过（已踩）。
#    改用三个判据，任一命中即视为 systemd 启动：
#      JOURNAL_STREAM  unit 里配了 StandardOutput/Error=journal 时由 systemd 注入（231+）
#      PPID=1          由 systemd(pid 1) 直接 fork —— oneshot 服务正是这个形态
#      INVOCATION_ID   更高版本 systemd 才有，留着兼容
#    注意：这里"定时"的准确含义是"由 systemd 启动"，`systemctl start` 手工触发
#    同样记"定时"（它走的也是系统通道）；只有从终端直接执行才记"手动"。
RUN_MODE="手动"
if [ -n "${INVOCATION_ID:-}" ] || [ -n "${JOURNAL_STREAM:-}" ] || [ "${PPID:-0}" -eq 1 ]; then
  RUN_MODE="定时"
fi

# --list / --check-only 是纯体检（只读），不写运行摘要 ——
# 否则体检时配置有错，会往续期日志里灌一条 FAIL，越看越乱。
RUN_LOG_SKIP=0

usage() {
  cat <<'EOF'

  批量签发 / 续期 Let's Encrypt 证书（DNS-01 验证）

  用法:
    ./ssl-issue.sh [选项]

  选项:
    --list              只打印解析后的证书列表，不做任何事
    --check-only        只体检：显示每张证书的状态和将要执行的动作
    --domain <主域名>   只处理指定的那一张证书
    --force             忽略剩余天数，强制重签（配合 --domain 可只强签一张）
    --staging           使用 Let's Encrypt 测试环境（调试用）
    --debug             打开 acme.sh 调试输出
    --secrets <文件>    指定密钥文件，   默认 scripts/ssl/secrets.env
    --domains <文件>    指定域名列表，   默认 scripts/ssl/domains.conf
    --policy  <文件>    指定策略文件，   默认 scripts/ssl/ssl.conf
    -h, --help          显示本帮助

  配置文件的分工:
    secrets.env   DNS 服务商的 API 凭据            （已 gitignore，chmod 600）
                  按服务商分段；每个服务商支持多个账号，靠变量名后缀区分：
                    腾讯云： Tencent_SecretId / Tencent_SecretKey        → 账号 default
                             Tencent_SecretId_ACC2 / ..._ACC2            → 账号 ACC2
                    GoDaddy：GD_Key / GD_Secret                         → 账号 default
                             GD_Key_GD2 / GD_Secret_GD2                  → 账号 GD2
    domains.conf  域名列表，每行一张证书             （可提交）
                  用 dns=<服务商> 选服务商（tencent / godaddy），不写就是 tencent；
                  用 account=<账号名> 选该服务商下的账号，不写就是 default。
                  选项写法：  example.com www.example.com | renew=30 dns=godaddy account=GD2
    ssl.conf      全局策略（邮箱 / 算法 / 阈值 / unit 名…）  （可提交）

  ★ 一张证书里的所有域名必须同属一个 DNS 服务商、且同属该服务商下的同一个账号 ——
    DNS-01 验证是一次调用写完整行的 TXT 记录，acme.sh 一次只能用一套凭据。
    域名跨服务商 / 跨账号时，请拆成两行，各自带上 dns= 和 account=。

  续期后置动作:
    某张证书被更新并部署成功后，会自动执行 scripts/ssl/renewpost.sh
    （不需要在 ssl.conf 里配；模板见 renewpost.sh.example.docker / .example.nginx）。
    拿它重启 docker compose 服务、重启 nginx 之类的都可以。
    全部证书都在有效期内时不会执行 —— 不会白重启服务。

  运行日志:
    每跑一次都会往 <证书目录>/renew.log 追加一行结果，例如
      2026-09-18 03:17:02  OK    处理=3  更新=1  跳过=2  失败=0  模式=定时  后置钩子=成功
    OK = 无失败；FAIL = 有失败或中途中止；完全没有记录 = 任务没跑起来。

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list)       LIST_ONLY=1 ;;
    --check-only) CHECK_ONLY=1 ;;
    --domain)     shift; if [ $# -eq 0 ]; then die "--domain 后面要跟主域名"; fi; ONLY_DOMAIN="$1" ;;
    --force)      FORCE=1 ;;
    --staging)    STAGING=1 ;;
    --debug)      DEBUG=1 ;;
    --secrets)    shift; if [ $# -eq 0 ]; then die "--secrets 后面要跟文件路径"; fi; SECRETS_FILE="$1" ;;
    --domains)    shift; if [ $# -eq 0 ]; then die "--domains 后面要跟文件路径"; fi; DOMAINS_FILE="$1" ;;
    --policy)     shift; if [ $# -eq 0 ]; then die "--policy 后面要跟文件路径"; fi; POLICY_FILE="$1" ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; die "未知参数: $1" ;;
  esac
  shift
done

record_fail() { FAILURES+=("$1：$2"); }

# =============================================================================
#  运行摘要日志（<证书目录>/renew.log）
# -----------------------------------------------------------------------------
#  systemd 的 journal 在 CentOS 8 上默认**不持久化**（只写 /run/log/journal），
#  机器一重启，"昨晚到底续没续成"就查不到了。所以再落一个文件，
#  每跑一次追加一行，格式：
#      2026-09-18 03:17:02  OK    处理=3   更新=1   跳过=2   失败=0  模式=定时  后置钩子=成功
#  判断方法：
#      OK    = 本次没有任何失败
#      FAIL  = 有失败项，或中途异常中止
#      什么都没写 = 任务根本没跑起来（看 journalctl）
# =============================================================================

# 统计 SUMMARY 里各类结果的数量
# （SUMMARY 每行格式： 主域名|到期时间|剩余|阈值|本次结果）
count_results() {
  local row res
  N_TOTAL=0; N_UPDATED=0; N_SKIPPED=0; N_FAILED=0
  for row in ${SUMMARY[@]+"${SUMMARY[@]}"}; do
    [ -n "$row" ] || continue
    res="${row##*|}"
    N_TOTAL=$((N_TOTAL + 1))
    case "$res" in
      已更新) N_UPDATED=$((N_UPDATED + 1)) ;;
      失败)   N_FAILED=$((N_FAILED + 1)) ;;
      *)      N_SKIPPED=$((N_SKIPPED + 1)) ;;
    esac
  done
}

# 写日志；只允许写一次（正常收尾写，或 EXIT 兜底写）
#   flush_run_log <OK|FAIL> [附加说明]
flush_run_log() {
  local status="$1" extra="${2:-}" all
  if [ "$RUN_LOG_WRITTEN" = 1 ]; then return 0; fi
  RUN_LOG_WRITTEN=1

  count_results
  # 安全网：只要统计出有失败项，状态就不可能是 OK ——
  # 免得将来有人改调用处时又漏算一次（之前就写成过"失败=2 却是 OK"）。
  # FAILURES 里还包含不属于某张证书的失败（比如后置钩子），所以也要看它。
  if [ "$status" = "OK" ]; then
    if [ "$N_FAILED" -gt 0 ] || [ "${#FAILURES[@]}" -gt 0 ]; then status="FAIL"; fi
  fi

  all="模式=${RUN_MODE}"
  if [ -n "$ONLY_DOMAIN" ]; then all="${all}  范围=${ONLY_DOMAIN}"; fi
  if [ -n "$extra" ]; then all="${all}  ${extra}"; fi

  write_run_log "$status" "$N_TOTAL" "$N_UPDATED" "$N_SKIPPED" "$N_FAILED" "$all"
}

# 兜底：脚本中途异常退出（配置错误 / 被 kill / 命令失败）时也留一条 FAIL，
# 这样"renew.log 里某天完全空白"才能明确等于"任务压根没跑起来"。
on_exit() {
  local rc=$?
  if [ "$RUN_LOG_SKIP" = 1 ]; then return 0; fi
  flush_run_log "FAIL" "提前中止（退出码 ${rc}）"
  return 0
}

# -----------------------------------------------------------------------------
#  --domain 时定位目标下标
# -----------------------------------------------------------------------------
select_target() {
  if [ -z "$ONLY_DOMAIN" ]; then
    TARGET_FIRST=0
    TARGET_LAST=$((CERT_COUNT - 1))
    return 0
  fi

  local i
  for ((i = 0; i < CERT_COUNT; i++)); do
    if [ "${CERT_PRIMARY[i]}" = "$ONLY_DOMAIN" ]; then
      TARGET_FIRST="$i"
      TARGET_LAST="$i"
      return 0
    fi
  done

  local names=""
  for ((i = 0; i < CERT_COUNT; i++)); do names="${names}${CERT_PRIMARY[i]} "; done
  die "--domain ${ONLY_DOMAIN} 不在 ${DOMAINS_FILE} 里。
  当前可用的主域名：${names}"
}

# =============================================================================
#  环境体检（只在真正签发前跑一次）
# =============================================================================
precheck() {
  step "环境与连通性体检"

  local c n
  for c in bash curl openssl tar; do
    if ! command -v "$c" >/dev/null 2>&1; then
      die "缺少命令 $c（CentOS 8 默认自带，请检查 PATH）"
    fi
  done
  ok "基础命令齐备：bash / curl / openssl / tar"

  # 账号归属一览 —— 一眼看清哪张证书用哪个服务商的哪个账号
  info "DNS 凭据（共 ${ACCOUNT_COUNT} 个账号，来自 $(basename "$SECRETS_FILE")）"
  for ((n = 0; n < ACCOUNT_COUNT; n++)); do
    info "  · $(provider_display "${ACCOUNT_PROV[n]}")  / 账号 ${ACCOUNT_NAMES[n]}  (ID 尾号 …${ACCOUNT_TAILS[n]})"
  done
  info "域名 → 凭据归属（来自 $(basename "$DOMAINS_FILE")）"
  for ((n = 0; n < CERT_COUNT; n++)); do
    info "  · ${CERT_PRIMARY[n]}  →  ${CERT_PROV[n]}:${CERT_ACCOUNT[n]}"
  done

  if [ "$(id -u)" -eq 0 ]; then
    info "当前以 root 运行"
  else
    warn "当前不是 root。若需写入 ${ACME_HOME} 或 reload 系统服务，请改用 sudo"
  fi

  local code
  code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "$LE_PROD_DIR" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    ok "可访问 Let's Encrypt ACME 接口"
  else
    warn "访问 Let's Encrypt 返回 '${code:-无响应}' —— 请检查防火墙 / DNS / 代理"
  fi

  # 只探实际用到的服务商 —— 遍历规格表，不在代码里写服务商分支
  local prov url
  for prov in $(providers_in_use); do
    url="$(provider_check_url "$prov")"
    [ -n "$url" ] || continue
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      ok "可访问 $(provider_display "$prov") API"
    else
      warn "访问 $(provider_display "$prov") API 失败，TXT 记录将无法自动写入"
    fi
  done

  # 逐个主域名确认 NS 归属，只在异常时输出，避免刷屏
  local i ns hint bad=0
  for ((i = 0; i < CERT_COUNT; i++)); do
    prov="${CERT_PROV[i]}"
    hint="$(provider_ns_hint "$prov")"
    ns=""
    if command -v dig >/dev/null 2>&1; then
      ns="$(dig +short NS "${CERT_PRIMARY[i]}" 2>/dev/null | tr '\n' ' ' || true)"
    elif command -v nslookup >/dev/null 2>&1; then
      ns="$(nslookup -type=ns "${CERT_PRIMARY[i]}" 2>/dev/null | awk '/nameserver *=/{print $NF}' | tr '\n' ' ' || true)"
    fi

    if [ -z "${ns//[[:space:]]/}" ]; then
      continue
    fi
    case "$ns" in
      *"$hint"*) ;;
      *)
        bad=$((bad + 1))
        warn "${CERT_PRIMARY[i]}（dns=${prov}）的 NS 不像 $(provider_display "$prov")：${ns}"
        warn "  DNS-01 验证要求解析托管在 $(provider_display "$prov")（NS 含 ${hint}），否则无法自动写入 TXT 记录" ;;
    esac
  done
  if [ "$bad" -eq 0 ]; then
    ok "全部主域名的 NS 归属检查通过"
  fi
}

# =============================================================================
#  准备 acme.sh
# =============================================================================
install_acme() {
  local tmp repo tarball src=""
  tmp="$(mktemp -d)"
  repo="${ACME_REPO:-https://github.com/acmesh-official/acme.sh.git}"
  tarball="${ACME_TARBALL:-https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz}"

  if command -v git >/dev/null 2>&1; then
    info "git clone --depth 1 ${repo}"
    if git clone --depth 1 "$repo" "${tmp}/acme" >/dev/null 2>&1; then
      src="${tmp}/acme"
    else
      warn "git clone 失败，改用源码包方式"
    fi
  fi

  if [ -z "$src" ]; then
    info "下载 ${tarball}"
    if curl -fsSL -m 180 "$tarball" -o "${tmp}/acme.tar.gz" 2>/dev/null; then
      if tar -xzf "${tmp}/acme.tar.gz" -C "$tmp" >/dev/null 2>&1; then
        src="$(find "$tmp" -maxdepth 1 -type d -name 'acme.sh-*' 2>/dev/null | head -n1 || true)"
      fi
    fi
  fi

  if [ -z "$src" ] || [ ! -f "${src}/acme.sh" ]; then
    rm -rf "$tmp"
    die "acme.sh 获取失败，服务器可能无法访问 GitHub。两种解法：
  1) 在有网的机器上下载 acme.sh 源码，scp 到服务器后指定本地路径：
         ACME_REPO=/opt/src/acme.sh ${SCRIPT_DIR}/ssl-issue.sh
  2) 使用可访问的镜像：
         export ACME_REPO=<镜像 git 地址>
         export ACME_TARBALL=<镜像 tar.gz 地址>"
  fi

  info "安装到 ${ACME_HOME}"
  if ! ( cd "$src" && LE_WORKING_DIR="$ACME_HOME" ./acme.sh --install -m "$SSL_EMAIL" ) >/dev/null 2>&1; then
    die "acme.sh --install 执行失败，请手动执行：
      cd ${src} && ./acme.sh --install -m ${SSL_EMAIL}"
  fi
  rm -rf "$tmp"

  # ★ 同样用 ${HOME:-/root}：systemd 的 service 里没有 HOME，
  #   裸用 ${HOME} 会在 set -u 下直接 'unbound variable' 退出。
  if [ ! -x "$ACME_BIN" ] && [ -x "${HOME:-/root}/.acme.sh/acme.sh" ]; then
    ACME_HOME="${HOME:-/root}/.acme.sh"
    ACME_BIN="${ACME_HOME}/acme.sh"
    info "实际安装目录：${ACME_HOME}"
  fi
  ok "acme.sh 安装完成"
}

ensure_acme() {
  step "准备 ACME 客户端 acme.sh"

  if [ -x "$ACME_BIN" ]; then
    local ver
    ver="$("$ACME_BIN" --version 2>/dev/null | tail -n1 || true)"
    ok "已安装：${ACME_BIN} ${C_DIM}${ver}${C_RST}"
  else
    info "未检测到 acme.sh，开始自动安装…"
    install_acme
  fi

  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  ok "默认 CA 已固定为 Let's Encrypt"

  local acc_dir="${ACME_HOME}/ca/acme-v02.api.letsencrypt.org"
  if [ -f "${acc_dir}/account.key" ]; then
    ok "ACME 账号已存在，跳过注册"
  else
    info "注册 ACME 账号：${SSL_EMAIL}"
    if "$ACME_BIN" --register-account -m "$SSL_EMAIL" --server letsencrypt >/dev/null 2>&1; then
      ok "账号注册成功"
    else
      warn "账号注册返回非 0（通常表示已注册过），继续尝试签发"
    fi
  fi

  if "$ACME_BIN" --uninstall-cronjob >/dev/null 2>&1; then
    ok "已移除 acme.sh 自带 crontab 任务（续期统一由本脚本 / timer 负责）"
  fi
}

# =============================================================================
#  处理单张证书
# =============================================================================
process_cert() {
  local idx="$1" seq="$2"
  local primary="${CERT_PRIMARY[idx]}"
  local dir="${CERT_DIR[idx]}"
  local renew="${CERT_RENEW[idx]}"
  local acct="${CERT_ACCOUNT[idx]}"
  local prov="${CERT_PROV[idx]}"
  local hook_name
  hook_name="$(provider_hook "$prov")"
  local outdir prefix suffix
  outdir="$(cert_outdir "$dir")"
  prefix="$(cert_prefix "$dir")"
  suffix=""
  if [ "$IS_ECC" = 1 ]; then suffix="_ecc"; fi

  local -a darr=()
  set -f
  # shellcheck disable=SC2206
  darr=( ${CERT_DOMAINS[idx]} )
  set +f

  printf '\n%s━━━ [%s/%s] %s ━━━%s\n' "$C_BLD$C_CYN" "$seq" "$TOTAL_TODO" "$primary" "$C_RST"
  printf '  %s证书域名%s   %s\n' "$C_BLD" "$C_RST" "${darr[*]}"
  printf '  %s输出目录%s   %s/\n' "$C_BLD" "$C_RST" "$outdir"
  printf '  %sDNS 服务商%s %s\n' "$C_BLD" "$C_RST" "$(provider_display "$prov")"
  printf '  %s账号%s       %s:%s  %s(ID 尾号 …%s)%s\n' \
    "$C_BLD" "$C_RST" "$prov" "$acct" "$C_DIM" "$(account_tail "$prov" "$acct")" "$C_RST"
  printf '  %s续期阈值%s   剩余 %s 天时自动续期\n' "$C_BLD" "$C_RST" "$renew"

  local remaining end_str
  remaining="$(cert_remaining_days "$dir")"
  end_str="$(cert_enddate_local "$dir")"

  if [ -z "$remaining" ]; then
    printf '  %s当前状态%s   尚未签发\n' "$C_BLD" "$C_RST"
  elif [ "$remaining" -lt 0 ]; then
    printf '  %s当前状态%s   %s已过期 %d 天%s（%s）\n' \
      "$C_BLD" "$C_RST" "$C_RED" "$(( -remaining ))" "$C_RST" "$end_str"
  else
    printf '  %s当前状态%s   剩余 %s 天（至 %s）\n' "$C_BLD" "$C_RST" "$remaining" "$end_str"
  fi

  # ---------------------------------------------------------------- 决策
  local decision need why
  if [ "$FORCE" = 1 ]; then
    need=1; why="命令行指定了 --force"
  else
    decision="$(cert_decide "$idx")"
    need="${decision%%|*}"
    why="${decision#*|}"
  fi

  if [ "$need" = "0" ]; then
    printf '  %s动作%s       %s跳过%s —— %s\n' "$C_BLD" "$C_RST" "$C_DIM" "$C_RST" "$why"
    SUMMARY+=("${primary}|${end_str:-—}|${remaining:-—}|${renew}|未到续期时间")
    return 0
  fi

  printf '  %s动作%s       %s签发 / 续期%s —— %s\n\n' "$C_BLD" "$C_RST" "$C_YEL" "$C_RST" "$why"

  # ------------------------------------------------- ① 请求 + ② DNS 验证
  local -a cargs=(--issue)
  if [ "$STAGING" = 1 ]; then
    cargs+=(--server "$LE_STAGING_DIR")
  else
    cargs+=(--server "$LE_PROD_DIR")
  fi
  cargs+=(--dns "$hook_name" --keylength "$SSL_KEY_LENGTH" --dnssleep "$SSL_DNS_SLEEP")
  if [ -n "$remaining" ]; then cargs+=(--force); fi
  if [ "$DEBUG" = 1 ]; then cargs+=(--debug); fi
  local d
  for d in "${darr[@]}"; do cargs+=(-d "$d"); done

  info "① ACME 请求：${ACME_HOME}/acme.sh ${cargs[*]}"
  info "② DNS 验证：用 ${prov}:${acct} 在 $(provider_display "$prov") 增删 _acme-challenge TXT → 等 ${SSL_DNS_SLEEP}s → LE 校验"

  # 把凭据切到这张证书所属的服务商 + 账号。
  # acme.sh 的钩子固定读各自的"输出槽"，所以每张证书签发前都必须重新指一次，
  # 否则会沿用上一张证书的凭据（甚至跨服务商串号）。
  account_activate "$prov" "$acct"

  local rc=0
  "$ACME_BIN" "${cargs[@]}" || rc=$?

  # 不管成功失败都清掉 acme.sh 存在 account.conf 里的凭据副本 ——
  # 多账号下它既多余，又可能和当前账号不一致。
  if scrub_acme_account_conf; then
    info "已清除 acme.sh account.conf 里的凭据副本（避免多账号串用）"
  fi

  case "$rc" in
    0) ok "签发成功，DNS 验证通过（${prov}:${acct}）" ;;
    2) info "acme.sh 判定无需续期（退出码 2 = Skip），继续部署现有证书" ;;
    *)
      warn "签发失败（acme.sh 退出码 ${rc}）。排查："
      warn "  ${ACME_HOME}/acme.sh ${cargs[*]} --debug"
      warn "  dig +short NS ${primary}"
      warn "  这张证书用的是 $(provider_display "$prov") 账号 ${prov}:${acct}（ID 尾号 …$(account_tail "$prov" "$acct")）"
      warn "  若这些域名并不在该账号下，$(provider_display "$prov") 会报「记录不存在 / 权限不足」——"
      warn "  跨账号 / 跨服务商的域名必须拆成 ${DOMAINS_FILE} 里的两行（每行一张证书）"
      record_fail "$primary" "签发失败（退出码 ${rc}）"
      SUMMARY+=("${primary}|${end_str:-—}|${remaining:-—}|${renew}|失败")
      return 1 ;;
  esac

  # ---------------------------------------------------------------- ③ 部署
  mkdir -p "$outdir"
  local -a iargs=(--install-cert -d "$primary")
  if [ "$IS_ECC" = 1 ]; then iargs+=(--ecc); fi
  iargs+=(--key-file       "${outdir}/${prefix}privkey.pem")
  iargs+=(--cert-file      "${outdir}/${prefix}cert.pem")
  iargs+=(--ca-file        "${outdir}/${prefix}chain.pem")
  iargs+=(--fullchain-file "${outdir}/${prefix}fullchain.pem")

  # ★ 这里刻意**不**给 acme.sh 传 --reloadcmd。
  #   acme.sh 的 --install-cert 会在装完证书后立刻执行一次 reloadcmd，
  #   而这个脚本本身要遍历多张证书、最后统一执行一次后置动作
  #   （renewpost.sh 或 SSL_RELOAD_CMD）。两边都配 = 重载执行 N+1 次，
  #   对 docker compose --force-recreate / nginx restart 这种重活尤其浪费。
  #   所以重载动作统一由脚本结尾那一步负责，acme.sh 只负责把文件放好。

  if ! "$ACME_BIN" "${iargs[@]}" >/dev/null 2>&1; then
    warn "部署失败，请检查：ls -l ${ACME_HOME}/${primary}${suffix}"
    record_fail "$primary" "部署失败"
    SUMMARY+=("${primary}|${end_str:-—}|${remaining:-—}|${renew}|失败")
    return 1
  fi

  chmod 644 "${outdir}/${prefix}cert.pem" "${outdir}/${prefix}chain.pem" "${outdir}/${prefix}fullchain.pem" 2>/dev/null || true
  chmod 600 "${outdir}/${prefix}privkey.pem" 2>/dev/null || true
  ok "③ 已部署到 ${outdir}/（privkey.pem 权限 600）"
  RELOAD_NEEDED=1

  # ---------------------------------------------------------------- 校验
  local newrem newend
  newrem="$(cert_remaining_days "$dir")"
  newend="$(cert_enddate_local "$dir")"
  if [ -n "$newrem" ]; then
    if [ "$newrem" -lt 0 ]; then
      warn "新证书仍是过期状态，请检查服务器系统时间"
      record_fail "$primary" "证书已过期（请检查系统时间）"
      SUMMARY+=("${primary}|${newend:-—}|${newrem}|${renew}|失败")
      return 1
    fi
    # ---- 检查证书是不是从 Let's Encrypt 测试环境签出来的 ----
    # 2026-11-11 加。背景：www.dudianjian.com / .cn 的证书连续几个月都是
    # STAGING 环境签发的（issuer 带 "(STAGING)" 字样），浏览器不信任、
    # curl 报 exit=60，但脚本只校验剩余天数，全程没有任何告警，
    # 直到用户发现打不开才暴露。这条检查把这种问题挡在部署之后立刻发现。
    local issuer
    issuer="$(openssl x509 -in "${outdir}/${prefix}cert.pem" -noout -issuer 2>/dev/null || true)"
    if printf '%s' "$issuer" | grep -qi 'STAGING'; then
      if [ "$STAGING" = 1 ]; then
        warn "证书来自 STAGING 测试环境（本次显式用了 --staging，属预期）"
      else
        warn "证书来自 Let's Encrypt STAGING 测试环境，浏览器/客户端不会信任！"
        warn "   issuer: ${issuer#issuer=}"
        warn "   检查是否误加了 --staging，或 acme.sh 里残留了测试环境的 CA 配置"
        record_fail "$primary" "签成了 STAGING 测试证书（浏览器不信任）"
        SUMMARY+=("${primary}|${newend:-—}|${newrem:-—}|${renew}|失败(STAGING)")
        return 1
      fi
    else
      ok "证书环境：正式（${issuer#issuer=}）"
    fi

    ok "校验通过：剩余 ${newrem} 天（至 ${newend}）"
  fi

  SUMMARY+=("${primary}|${newend:-—}|${newrem:-—}|${renew}|已更新")
  return 0
}

# =============================================================================
#  主流程
# =============================================================================
main() {
  printf '\n%s  Let'"'"'s Encrypt 批量证书管理  ·  DNS-01 验证%s\n' "$C_BLD$C_CYN" "$C_RST"
  printf '  %s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"
  printf '  %s项目根目录%s  %s\n' "$C_BLD" "$C_RST" "$PROJECT_ROOT"
  printf '  %s域名列表%s    %s\n' "$C_BLD" "$C_RST" "$DOMAINS_FILE"
  printf '  %s策略文件%s    %s\n' "$C_BLD" "$C_RST" "$POLICY_FILE"

  load_policy
  load_domains

  # 纯文本检查，放在 --list / --check-only 之前 —— 让体检也能发现"同一变量定义两次"。
  # （这两条只读通道刻意不载入凭据，所以不能靠 load_secrets 来发现。）
  check_duplicate_secret_vars

  ok "策略：${SSL_KEY_LENGTH} / 默认阈值 ${SSL_RENEW_DAYS} 天 / ${SSL_OUTPUT_LAYOUT} 布局 / unit ${SSL_UNIT_NAME}"
  ok "域名列表：共 ${CERT_COUNT} 张证书（服务商：$(providers_in_use)）"

  if [ "$LIST_ONLY" = 1 ]; then
    render_cert_table ""
    return 0
  fi

  select_target
  TOTAL_TODO=$((TARGET_LAST - TARGET_FIRST + 1))

  if [ "$CHECK_ONLY" = 1 ]; then
    step "体检模式（不会修改任何东西）"
    if [ -z "$SSL_EMAIL" ]; then
      warn "SSL_EMAIL 还没填，正式签发前请先在 ${POLICY_FILE} 里补上"
    fi
    if [ -n "$ONLY_DOMAIN" ]; then
      info "只处理 --domain 指定的：${ONLY_DOMAIN}"
    fi
    render_cert_table "plan" "$TARGET_FIRST" "$TARGET_LAST"
    return 0
  fi

  # ------------------------------------------------------------ 正式执行
  load_secrets
  ok "DNS 凭据已载入：${ACCOUNT_COUNT} 个账号 —— $(account_list_names)"
  verify_accounts
  ok "凭据归属校验通过（domains.conf 用到的服务商/账号都已定义）"

  if [ -z "$SSL_EMAIL" ]; then
    die "SSL_EMAIL 还没填。请编辑 ${POLICY_FILE} 设置 ACME 账号邮箱。"
  fi

  precheck
  ensure_acme

  local i seq=0
  for ((i = TARGET_FIRST; i <= TARGET_LAST; i++)); do
    seq=$((seq + 1))
    if ! process_cert "$i" "$seq"; then
      if [ "$SSL_KEEP_GOING" != "1" ]; then
        die "按 SSL_KEEP_GOING=0 的策略中止（已成功处理的证书保持有效）"
      fi
      warn "继续处理下一个域名（SSL_KEEP_GOING=1）"
    fi
  done

  # ------------------------------------------------------------ 续期后置动作
  # 只有"确实有证书被更新/部署"时才会进来 —— RELOAD_NEEDED 只在该证书部署成功后置 1。
  if [ "$RELOAD_NEEDED" = 1 ]; then
    local post_hook
    post_hook="$(resolve_post_hook)"

    if [ -n "$post_hook" ]; then
      step "证书已更新，执行续期后置钩子"
      info "${post_hook}"
      if [ ! -f "$post_hook" ]; then
        warn "钩子文件不存在：${post_hook}"
        record_fail "后置钩子" "文件不存在（${post_hook}）"
        POST_HOOK_STATE="文件不存在"
      elif bash "$post_hook"; then
        ok "后置钩子执行成功，服务已切到新证书"
        POST_HOOK_STATE="成功"
      else
        warn "后置钩子返回非 0 —— 证书已经部署好了，但服务可能仍在用旧证书！"
        warn "  手工重跑排查：bash ${post_hook}"
        record_fail "后置钩子" "执行失败（证书已更新，但服务可能未重载）"
        POST_HOOK_STATE="失败"
      fi

      if [ -n "$SSL_RELOAD_CMD" ]; then
        warn "检测到 SSL_RELOAD_CMD 和 renewpost.sh 同时存在，本次只执行了 renewpost.sh。"
        warn "  若 SSL_RELOAD_CMD 里的动作仍然需要，请合并进 renewpost.sh，"
        warn "  然后把 ${POLICY_FILE} 里的 SSL_RELOAD_CMD 清空。"
      fi

    elif [ -n "$SSL_RELOAD_CMD" ]; then
      step "重载服务（SSL_RELOAD_CMD）"
      info "$ ${SSL_RELOAD_CMD}"
      if eval "$SSL_RELOAD_CMD"; then
        ok "服务已重载，新证书已生效"
        POST_HOOK_STATE="成功（SSL_RELOAD_CMD）"
      else
        warn "重载命令返回非 0，请手动确认服务状态"
        record_fail "重载命令" "返回非 0"
        POST_HOOK_STATE="失败（SSL_RELOAD_CMD）"
      fi

    else
      warn "有证书被更新，但既没找到 renewpost.sh，也没配 SSL_RELOAD_CMD ——"
      warn "  服务不会自动用上新证书。建议创建：${SSL_LIB_DIR}/renewpost.sh"
      warn "  模板在：${SSL_LIB_DIR}/renewpost.sh.example.docker （或 .example.nginx）"
      POST_HOOK_STATE="未配置"
    fi
  fi

  # ------------------------------------------------------------ 汇总
  step "汇总"
  printf '\n  %s%-28s %17s %9s %7s  %s%s\n' \
    "$C_BLD" "证书（主域名）" "到期时间" "剩余" "阈值" "本次结果" "$C_RST"
  rule

  local row p endd rem rw res color
  for row in "${SUMMARY[@]}"; do
    p="${row%%|*}";    row="${row#*|}"
    endd="${row%%|*}"; row="${row#*|}"
    rem="${row%%|*}";  row="${row#*|}"
    rw="${row%%|*}";   res="${row#*|}"

    case "$res" in
      失败)   color="$C_RED" ;;
      已更新) color="$C_GRN" ;;
      *)      color="$C_DIM" ;;
    esac
    printf '  %-28s %17s %9s %6s天  %s%s%s\n' "$p" "$endd" "$rem" "$rw" "$color" "$res" "$C_RST"
  done

  printf '\n  %s证书输出位置%s\n' "$C_BLD" "$C_RST"
  local k
  for ((k = TARGET_FIRST; k <= TARGET_LAST; k++)); do
    printf '    %s/  ← %s\n' "$(cert_outdir "${CERT_DIR[k]}")" "${CERT_PRIMARY[k]}"
  done

  # ---- 落一行运行摘要 ----
  # 放在失败分支 exit 1 之前，保证成功和失败都会留痕。
  # ★ 必须先 count_results 再判断 N_FAILED —— flush_run_log 内部虽然也会统计，
  #   但那时候 run_status 已经定下来了，会写成 OK（真踩过）。
  local run_status run_extra=""
  count_results
  if [ "$N_FAILED" -gt 0 ]; then run_status="FAIL"; else run_status="OK"; fi
  if [ "$POST_HOOK_STATE" != "未触发" ]; then run_extra="后置钩子=${POST_HOOK_STATE}"; fi
  flush_run_log "$run_status" "$run_extra"

  printf '\n  %s本次结果已记入%s %s\n' "$C_DIM" "$C_RST" "$SSL_RUN_LOG"

  if [ "${#FAILURES[@]}" -gt 0 ]; then
    printf '\n  %s失败 %d 项：%s\n' "$C_RED$C_BLD" "${#FAILURES[@]}" "$C_RST"
    local f
    for f in "${FAILURES[@]}"; do printf '    ✘ %s\n' "$f"; done
    printf '\n  排障见 scripts/ssl/README.md\n\n'
    exit 1
  fi

  printf '\n  %s全部完成。%s\n\n' "$C_GRN$C_BLD" "$C_RST"
}

# =============================================================================
#  ★ 兜底 trap 必须注册在这里（main 之前），不能放进 main 内部。
#    main 内部注册时，load_policy / load_domains / load_secrets / verify_accounts /
#    precheck / ensure_acme 这些步骤全都排在它前面 —— 任何一步 die，
#    结果都是「脚本明明跑过并失败了，renew.log 却完全空白」，
#    与「任务压根没跑」无法区分（已实测复现）。
#    --list / --check-only 是纯体检，不写运行摘要。
# =============================================================================
if [ "$LIST_ONLY" = 1 ] || [ "$CHECK_ONLY" = 1 ]; then
  RUN_LOG_SKIP=1
fi
trap on_exit EXIT

main "$@"
