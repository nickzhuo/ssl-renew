#!/bin/bash
# =============================================================================
#  证书到期时间总览
#  scripts/ssl-status.sh
#
#  逐个域名列出：到期时间、剩余天数、本证书的续期阈值、状态、下次自动续期时间。
#  只读取，不修改任何东西 —— 随时可以跑。
#
#  用法:
#    ./ssl-status.sh            # 总览
#    ./ssl-status.sh --detail   # 加上每张证书的详细信息
#    ./ssl-status.sh --quiet    # 只输出一行汇总（适合塞进监控脚本）
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

DETAIL=0
QUIET=0

usage() {
  cat <<'EOF'

  证书到期时间总览

  用法:
    ./ssl-status.sh [选项]

  选项:
    --detail            额外显示每张证书的详细信息
    --quiet             只输出一行汇总（适合监控脚本 / 定时巡检）
    --secrets <文件>    指定密钥文件， 默认 scripts/secrets.env
    --domains <文件>    指定域名列表， 默认 scripts/domains.conf
    --policy  <文件>    指定策略文件， 默认 scripts/ssl.conf
    -h, --help          显示本帮助

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --detail)  DETAIL=1 ;;
    --quiet)   QUIET=1 ;;
    --secrets) shift; if [ $# -eq 0 ]; then die "--secrets 后面要跟文件路径"; fi; SECRETS_FILE="$1" ;;
    --domains) shift; if [ $# -eq 0 ]; then die "--domains 后面要跟文件路径"; fi; DOMAINS_FILE="$1" ;;
    --policy)  shift; if [ $# -eq 0 ]; then die "--policy 后面要跟文件路径"; fi; POLICY_FILE="$1" ;;
    -h|--help) usage; exit 0 ;;
    *)         usage; die "未知参数: $1" ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
#  证书目录下已部署的证书名（用于发现"已不在列表里"的孤儿证书）
# -----------------------------------------------------------------------------
deployed_names() {
  local n f d
  case "$SSL_OUTPUT_LAYOUT" in
    flat)
      for f in "$SSL_DIR"/*.fullchain.pem; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        printf '%s\n' "${n%.fullchain.pem}"
      done
      ;;
    *)
      for d in "$SSL_DIR"/*/; do
        [ -d "$d" ] || continue
        printf '%s\n' "$(basename "$d")"
      done
      ;;
  esac
}

# =============================================================================
#  主流程
# =============================================================================
main() {
  load_policy
  load_domains

  # ---- 统计 ----
  local i label remaining renew
  local n_ok=0 n_due=0 n_exp=0 n_new=0
  local warn_lines=()

  for ((i = 0; i < CERT_COUNT; i++)); do
    label="$(cert_status_label "$i")"
    remaining="$(cert_remaining_days "${CERT_DIR[i]}")"
    renew="${CERT_RENEW[i]}"

    case "$label" in
      正常)   n_ok=$((n_ok + 1)) ;;
      待续期) n_due=$((n_due + 1))
              warn_lines+=("${CERT_PRIMARY[i]} 剩余 ${remaining} 天 ≤ 阈值 ${renew} 天，下次定时任务会续期") ;;
      已过期) n_exp=$((n_exp + 1))
              warn_lines+=("${CERT_PRIMARY[i]} 已过期 ${remaining#-} 天，请立即执行 ./ssl-issue.sh") ;;
      未签发) n_new=$((n_new + 1))
              warn_lines+=("${CERT_PRIMARY[i]} 尚未签发，执行 ./ssl-issue.sh 即可") ;;
    esac
  done

  # ---- quiet 模式：只给一行，便于监控 ----
  if [ "$QUIET" = 1 ]; then
    printf 'certs=%d ok=%d due=%d expired=%d missing=%d\n' \
      "$CERT_COUNT" "$n_ok" "$n_due" "$n_exp" "$n_new"
    if [ "$n_exp" -gt 0 ] || [ "$n_new" -gt 0 ]; then exit 1; fi
    return 0
  fi

  # ---- 头部 ----
  printf '\n%s  Let'"'"'s Encrypt 证书到期总览%s\n' "$C_BLD$C_CYN" "$C_RST"
  printf '  %s──────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"
  printf '  %s域名列表%s  %s\n' "$C_BLD" "$C_RST" "$DOMAINS_FILE"
  printf '  %s输出根目录%s %s/   (%s 布局)\n' "$C_BLD" "$C_RST" "$SSL_DIR" "$SSL_OUTPUT_LAYOUT"

  # DNS 账号一览 —— 只提取密钥文件里"声明了哪些账号"的变量名，不读取密钥值
  local declared_accounts
  declared_accounts="$(accounts_declared_in_file | sort -u | tr '\n' ' ')"
  declared_accounts="${declared_accounts% }"
  if [ -n "$declared_accounts" ]; then
    printf '  %sDNS 账号%s    %s\n' "$C_BLD" "$C_RST" "$declared_accounts"
  else
    printf '  %sDNS 账号%s    %s（没能从 %s 里识别到账号）%s\n' \
      "$C_BLD" "$C_RST" "$C_DIM" "$(basename "$SECRETS_FILE")" "$C_RST"
  fi

  printf '  %s默认策略%s  %s / 默认阈值 %s 天 / 邮箱 %s\n' \
    "$C_BLD" "$C_RST" "$SSL_KEY_LENGTH" "$SSL_RENEW_DAYS" "${SSL_EMAIL:-（未设置）}"

  # ---- 主表 ----
  render_cert_table ""

  # ---- 统计 ----
  printf '  统计：共 %s 张证书  |  %s正常 %d%s  |  %s待续期 %d%s  |  %s已过期 %d%s  |  %s未签发 %d%s\n\n' \
    "$CERT_COUNT" \
    "$C_GRN" "$n_ok" "$C_RST" \
    "$C_YEL" "$n_due" "$C_RST" \
    "$C_RED" "$n_exp" "$C_RST" \
    "$C_DIM" "$n_new" "$C_RST"

  # ---- 详细信息 ----
  if [ "$DETAIL" = 1 ]; then
    local endd san nextr perm
    for ((i = 0; i < CERT_COUNT; i++)); do
      printf '  %s── %s ──%s\n' "$C_CYN$C_BLD" "${CERT_PRIMARY[i]}" "$C_RST"
      printf '     配置域名   %s\n' "$(normalize_domain_string "${CERT_DOMAINS[i]}")"
      printf '     DNS 凭据   %s:%s  （%s）\n' \
        "${CERT_PROV[i]}" "${CERT_ACCOUNT[i]}" "$(provider_display "${CERT_PROV[i]}")"
      endd="$(cert_enddate_local "${CERT_DIR[i]}")"
      if [ -z "$endd" ]; then
        printf '     证书       %s尚未签发%s\n' "$C_DIM" "$C_RST"
      else
        san="$(cert_san_list "${CERT_DIR[i]}")"
        printf '     证书域名   %s\n' "${san:-（读取不到）}"
        printf '     到期时间   %s\n' "$endd"
        printf '     剩余 / 阈值 %s 天 / %s 天\n' "$(cert_remaining_days "${CERT_DIR[i]}")" "${CERT_RENEW[i]}"
        printf '     输出目录   %s/\n' "$(cert_outdir "${CERT_DIR[i]}")"
        perm="$(stat -c '%a' "$(cert_file "${CERT_DIR[i]}" privkey.pem)" 2>/dev/null || echo '?')"
        if [ "$perm" = "600" ]; then
          printf '     私钥权限   %s%s%s\n' "$C_GRN" "$perm" "$C_RST"
        else
          printf '     私钥权限   %s%s（建议 chmod 600）%s\n' "$C_YEL" "$perm" "$C_RST"
        fi
      fi
      nextr="$(acme_next_renew "${CERT_PRIMARY[i]}")"
      if [ -n "$nextr" ]; then
        printf '     acme 记录的下次续期  %s\n' "$nextr"
      fi
      printf '\n'
    done
  fi

  # ---- 密钥文件体检（不读取内容，只看是否存在与权限）----
  if [ -f "$SECRETS_FILE" ]; then
    local sp
    sp="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo '?')"
    ok "密钥文件 ${SECRETS_FILE} 存在（权限 ${sp}）"
  else
    warn "密钥文件不存在：${SECRETS_FILE}
     cp ${SSL_LIB_DIR}/secrets.env.example ${SECRETS_FILE} && chmod 600 ${SECRETS_FILE}"
  fi

  # ---- 孤儿证书：证书目录下有，但不在 domains.conf 里 ----
  local deployed configured row is_conf
  deployed="$(deployed_names | sort -u)"
  configured="$(printf '%s\n' "${CERT_DIR[@]}" | sort -u)"
  local orphans=""
  while IFS= read -r row; do
    if [ -z "$row" ]; then continue; fi
    is_conf=0
    while IFS= read -r configured_line; do
      if [ "$row" = "$configured_line" ]; then is_conf=1; break; fi
    done <<< "$configured"
    if [ "$is_conf" = 0 ] && [ "$row" != ".gitkeep" ]; then
      orphans="${orphans}${row} "
    fi
  done <<< "$deployed"

  if [ -n "${orphans//[[:space:]]/}" ]; then
    warn "${SSL_DIR}/ 下存在不在 ${DOMAINS_FILE} 里的证书：${orphans}"
    warn "  如果是历史遗留，可自行删除；如果还需要，就把它加回域名列表"
  fi

  # ---- 定时器状态 ----
  # ★ unit 名不再写死 —— 来自 ssl.conf 的 SSL_UNIT_NAME。
  #   同一台机器上可能同时跑多套（Traefik / nginx），名字必须每台机器自己定。
  # ★ 三段判断：装没装 → 启用没启用 → 正在运行没。
  #   只判"装没装"会漏掉最常见的故障：unit 文件在、但没 enable/start，
  #   此时 systemctl list-timers 显示 "0 timers listed"，会让人误以为从未安装过。
  local timer_unit service_unit
  timer_unit="$(timer_unit)"
  service_unit="$(service_unit)"
  # timer 上次"触发"的日期 —— 只取日期，不解析时区缩写（EDT/CST 在不同 tzdata 下含义不同）。
  # 用来和 renew.log 对账：触发过但没有对应记录 = 那一次没跑成。
  local TIMER_LAST_DATE=""
  if command -v systemctl >/dev/null 2>&1; then
    printf '\n  %s自动续期%s  %s(unit: %s)   %s\n' "$C_BLD" "$C_RST" "$C_DIM" "$timer_unit" "$C_RST"
    # ★ 用 `systemctl cat` 判断"装没装" —— 它的退出码可靠。
    #   不要用 `systemctl list-unit-files <名字>`：模式匹配不到时某些版本**仍返回 0**，
    #   于是会掉进"已安装"分支、接着打印 `list-timers <不存在的 unit>` 的结果
    #   —— 那是两行 `0 timers listed.` + `Pass --all to see ...`，
    #   看起来就像"从来没装过"，非常误导（实测踩过）。
    if ! systemctl cat "$timer_unit" >/dev/null 2>&1; then
      printf '    %s%s 未安装%s —— 执行 sudo ./ssl-setup.sh 可装配\n' \
        "$C_DIM" "$timer_unit" "$C_RST"
      # ★ 防呆：本机若存在**别的名字**的 ssl timer，八成是 ssl.conf 里的
      #   SSL_UNIT_NAME 没跟着这台机器改（历史遗留的 ssl-renew / ssl-nginx-renew），
      #   于是 status 去查了一个不存在的 unit，报「未安装」，白误导一轮排查。
      #   直接把它查出来告诉你，比让人自己去猜快得多。
      local others
      others="$(systemctl list-unit-files --type=timer --no-legend 2>/dev/null \
                | awk '{print $1}' | grep -E '^ssl.*\.timer$' | grep -vx "$timer_unit" | tr '\n' ' ' || true)"
      others="${others% }"
      if [ -n "$others" ]; then
        printf '    %s本机另有 ssl 定时器：%s%s\n' "$C_YEL" "$others" "$C_RST"
        printf '    %s→ 多半是 %s 里的 SSL_UNIT_NAME 没改成实际在用的那个名字%s\n' \
          "$C_YEL" "$(basename "$POLICY_FILE")" "$C_RST"
        warn_lines+=("ssl 定时器名字对不上：期望 ${timer_unit}，但本机装的是 ${others} —— 请改 ${POLICY_FILE} 的 SSL_UNIT_NAME")
      fi
    elif ! systemctl is-enabled --quiet "$timer_unit" 2>/dev/null; then
      printf '    %s%s 已安装但未启用%s（开机不会自启，续期不会跑）\n' \
        "$C_YEL" "$timer_unit" "$C_RST"
      printf '    %s修复：sudo systemctl enable --now %s%s\n' "$C_DIM" "$timer_unit" "$C_RST"
      warn_lines+=("自动续期定时器 ${timer_unit} 已安装但未启用")
    elif ! systemctl is-active --quiet "$timer_unit" 2>/dev/null; then
      printf '    %s%s 已启用但当前未运行%s\n' "$C_YEL" "$timer_unit" "$C_RST"
      printf '    %s修复：sudo systemctl start %s%s\n' "$C_DIM" "$timer_unit" "$C_RST"
      warn_lines+=("自动续期定时器 ${timer_unit} 已启用但未运行")
    else
      local lt_out
      lt_out="$(systemctl list-timers "$timer_unit" --no-pager 2>/dev/null)"
      printf '%s\n' "$lt_out" | head -n2 | sed 's/^/    /'
      # 表头下面那一行里有两个日期：第 1 个是 NEXT，第 2 个是 LAST。
      # 从未触发过时 LAST 显示 n/a（整行只剩 1 个日期），取不到就留空、跳过对账。
      TIMER_LAST_DATE="$(printf '%s\n' "$lt_out" | sed -n '2p' \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sed -n '2p')"
    fi
  fi

  # ---- 续期后置钩子 ----
  # 证书更新后要不要自动重启服务，就看这里配没配。
  local hook_path
  hook_path="$(resolve_post_hook)"
  printf '\n  %s续期后置钩子%s\n' "$C_BLD" "$C_RST"
  if [ -n "$hook_path" ] && [ -f "$hook_path" ]; then
    printf '    %s%s%s\n' "$C_GRN" "$hook_path" "$C_RST"
    hook_reload_mode="$(sed -n 's/^RELOAD_MODE="\(.*\)".*$/\1/p' "$hook_path" | head -n1)"
    if [ -n "$hook_reload_mode" ]; then
      printf '    模式 %s%s%s —— 证书有更新时自动执行\n' "$C_BLD" "$hook_reload_mode" "$C_RST"
    else
      printf '    %s证书有更新时自动执行，用来重启容器 / 重启 nginx 等%s\n' "$C_DIM" "$C_RST"
      printf '    %s（没读到 RELOAD_MODE，可能是旧版模板；新版见 renewpost.sh.example）%s\n' \
        "$C_DIM" "$C_RST"
    fi
    printf '    %s空跑确认命令：bash %s --dry-run%s\n' "$C_DIM" "$hook_path" "$C_RST"
  elif [ -n "$hook_path" ]; then
    warn_lines+=("续期后置钩子指向的文件不存在：${hook_path}（证书更新后服务不会重载）")
    printf '    %s%s（文件不存在）%s\n' "$C_YEL" "$hook_path" "$C_RST"
  else
    printf '    %s未配置%s —— 证书更新后服务不会自动重载\n' "$C_DIM" "$C_RST"
    printf '    模板：%s/renewpost.sh.example（顶部 RELOAD_MODE 四选一：none/nginx/traefik/compose）\n' \
      "$SSL_LIB_DIR"
    printf '    用法：cp %s/renewpost.sh.example %s/renewpost.sh && chmod +x %s/renewpost.sh\n' \
      "$SSL_LIB_DIR" "$SSL_LIB_DIR" "$SSL_LIB_DIR"
  fi

  # ---- 运行日志（最近几次的结果摘要）----
  # 判断"昨晚到底续没续成"就看这里；CentOS 8 的 journal 默认不持久化，重启就没了。
  printf '\n  %s续期运行日志%s\n' "$C_BLD" "$C_RST"
  local last_rec_date=""
  if [ -n "${SSL_RUN_LOG:-}" ] && [ -f "$SSL_RUN_LOG" ]; then
    tail -n 5 "$SSL_RUN_LOG" | sed 's/^/    /'
    printf '    %s── 完整文件：%s%s\n' "$C_DIM" "$SSL_RUN_LOG" "$C_RST"
    last_rec_date="$(tail -n 1 "$SSL_RUN_LOG" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')"
  else
    printf '    %s暂无记录%s —— 还没跑过 ssl-issue.sh，或日志被清掉了\n' "$C_DIM" "$C_RST"
    printf '    %s预期位置：%s%s\n' "$C_DIM" "${SSL_RUN_LOG:-<证书目录>/renew.log}" "$C_RST"
  fi

  # ---- ★ 对账：timer 触发时间 vs 实际运行记录 ----
  # list-timers 的 LAST 只说明"到点触发过一次"，**不说明脚本跑成功了**。
  # 触发日期比日志里最后一条还新 => 那几次触发没留下任何记录，
  # 说明脚本根本没跑起来、或一启动就失败了 —— 这正是"日志里看不到自动记录"的成因。
  if [ -n "$TIMER_LAST_DATE" ]; then
    if [ -z "$last_rec_date" ]; then
      warn_lines+=("定时任务在 ${TIMER_LAST_DATE} 触发过，但运行日志里一条记录都没有 —— 脚本没跑起来，或一启动就失败")
      warn_lines+=("  取证据：journalctl -u ${service_unit} -n 200 --no-pager")
    elif [[ "$TIMER_LAST_DATE" > "$last_rec_date" ]]; then
      warn_lines+=("定时任务在 ${TIMER_LAST_DATE} 触发过，但日志最后一条停在 ${last_rec_date} —— 触发后没留下记录，说明那几次没跑成")
      warn_lines+=("  取证据：journalctl -u ${service_unit} -n 200 --no-pager")
    fi
  fi

  # 备用日志有内容 = 有运行在"配置还没解析出来"就失败了（见 lib.sh 的 SSL_RUN_LOG_FALLBACK）
  if [ -s "${SSL_RUN_LOG_FALLBACK:-}" ]; then
    warn_lines+=("存在备用日志 ${SSL_RUN_LOG_FALLBACK} —— 有运行在解析配置前就失败了，看它最后几行")
  fi

  # ---- 凭据归属校验：domains.conf 里写的 (服务商, 账号)，密钥文件里定义了吗 ----
  if [ -f "$SECRETS_FILE" ]; then
    local k acct_bad=""
    for ((k = 0; k < CERT_COUNT; k++)); do
      if ! printf '%s\n' "$declared_accounts" | tr ' ' '\n' | grep -qx "${CERT_PROV[k]}:${CERT_ACCOUNT[k]}"; then
        acct_bad="${acct_bad}${CERT_PRIMARY[k]}(${CERT_PROV[k]}:${CERT_ACCOUNT[k]}) "
      fi
    done
    if [ -n "${acct_bad//[[:space:]]/}" ]; then
      warn_lines+=("这些证书指定的 DNS 账号，在 $(basename "$SECRETS_FILE") 里找不到：${acct_bad}")
      warn_lines+=("  腾讯云补这两行：Tencent_SecretId_<账号名> / Tencent_SecretKey_<账号名>")
      warn_lines+=("  GoDaddy 补这两行：GD_Key_<账号名> / GD_Secret_<账号名>")
    fi
  fi

  # ---- 需要关注的事项 ----
  if [ "${#warn_lines[@]}" -gt 0 ]; then
    printf '\n  %s需要关注%s\n' "$C_YEL$C_BLD" "$C_RST"
    local w
    for w in "${warn_lines[@]}"; do printf '    · %s\n' "$w"; done
  fi

  printf '\n  %s下一步%s\n' "$C_BLD" "$C_RST"
  printf '    正式续期 / 签发   %s/ssl-issue.sh\n' "$SSL_LIB_DIR"
  printf '    先看会做什么      %s/ssl-issue.sh --check-only\n' "$SSL_LIB_DIR"
  printf '    只续某一个域名    %s/ssl-issue.sh --domain <主域名>\n\n' "$SSL_LIB_DIR"
}

main "$@"
