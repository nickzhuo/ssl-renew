#!/bin/bash
# =============================================================================
#  证书续期定时器 —— 体检 / 冲突分析 / 收敛成一个
#  scripts/ssl/ssl-repair.sh
#
#  背景（为什么会装上两个）
#    本套证书工具只有**一套代码**（scripts/ssl/），靠 ssl.conf 的
#    SSL_UNIT_NAME 区分不同机器 / 不同消费方：
#        Traefik 机器   SSL_UNIT_NAME="ssl-renew"        unit ssl-renew.*
#        nginx   机器   SSL_UNIT_NAME="ssl-nginx-renew"  unit ssl-nginx-renew.*
#    unit 名不同，本来是为了让**同一台机器上两套能共存**。
#    但如果一台机器上先后用两个不同的 SSL_UNIT_NAME 跑过 ssl-setup.sh，
#    就会装上两个定时器 —— 两个都在跑、各续各的 domains.conf，
#    事后很难分清谁管哪些域名。
#
#  ★ 判断"某个 timer 该不该留"的权威依据不是猜目录名，而是读本目录里的
#    ssl.conf —— SSL_UNIT_NAME 就是"本目录本该装哪个 unit"。
#    unit 名与之不符的，就是被别的配置误装进来的**外来户**。
#
#  用法（需要 root）：
#    ./ssl-repair.sh                             # ① 体检（默认，只读，不改任何东西）
#    ./ssl-repair.sh --apply --keep ssl-nginx-renew.timer
#                                                # ② 确认后执行：只保留指定的那个
#    ./ssl-repair.sh --apply --keep X --force
#                                                # 明知有域名会失去续期，仍要删（不推荐）
#
#  安全设计
#    ① 默认 dry-run 只读；删除必须显式 --apply + --keep
#    ② 删前做「域名丢失检查」：准备删掉那套的 domains.conf 里的域名，
#       若没有出现在保留那套里，**直接拒绝执行**，并列出需要先合并的行
#    ③ 只有当没有其它定时器引用同一个 .service 时才删它
#    ④ 顺带检查 acme.sh 自带 crontab（它会和本定时器重复续期）
#
#  可测试性
#    单元目录 / systemctl 都可用环境变量覆盖，便于在沙箱里验证：
#        SSL_REPAIR_UNIT_DIR=/tmp/x SSL_REPAIR_SYSTEMCTL=/tmp/fake-systemctl ./ssl-repair.sh
# =============================================================================

set -uo pipefail

UNIT_DIR="${SSL_REPAIR_UNIT_DIR:-/etc/systemd/system}"
SYSTEMCTL="${SSL_REPAIR_SYSTEMCTL:-systemctl}"

APPLY=0
FORCE=0
KEEP=""

# -----------------------------------------------------------------------------
#  输出
# -----------------------------------------------------------------------------
b()   { printf '%s' "$1"; }
head_() { printf '\n  %s\n' "$1"; }
info()  { printf '     %s\n' "$*"; }
ok()    { printf '  ✔ %s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*"; }
bad()   { printf '  ✘ %s\n' "$*"; }
rule()  { printf '  ──────────────────────────────────────────────────────────────\n'; }

usage() {
  cat <<'EOF'

  证书续期定时器 体检 / 收敛成一个

  用法:
    ./ssl-repair.sh                              体检（默认，只读）
    ./ssl-repair.sh --apply --keep <unit>        执行清理，只保留 <unit>
    ./ssl-repair.sh --apply --keep <unit> --force  有域名会失去续期时仍强行删
    -h, --help

  说明:
    默认什么都不改，只把机器上所有 ssl*.timer 摊开给你看，
    并检查"删掉多余的那些之后，会不会有域名没人续期"。

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    --keep)  shift; if [ $# -eq 0 ]; then echo "✘ --keep 后面要跟 unit 名" >&2; exit 1; fi; KEEP="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; echo "✘ 未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$APPLY" = 1 ] && [ -z "$KEEP" ]; then
  echo "✘ --apply 必须同时用 --keep 指定要保留哪个定时器。" >&2
  echo "  先跑一次不带参数的体检，看清现状再决定。" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
#  探测
# -----------------------------------------------------------------------------

# 所有 ssl*.timer（扫 unit 目录，不用 list-unit-files —— 它的模式匹配
# 在部分 systemd 版本上匹配不到时仍返回 0，会误判成"已安装"）
find_timers() {
  local f
  for f in "$UNIT_DIR"/ssl*.timer; do
    [ -e "$f" ] || continue
    basename "$f"
  done | sort
}

# timer -> 它启动的 service 名（读 Unit=，没有就取同名）
timer_service() {
  local t="$1" s=""
  if [ -f "$UNIT_DIR/$t" ]; then
    s="$(sed -n 's/^[[:space:]]*Unit[[:space:]]*=[[:space:]]*//p' "$UNIT_DIR/$t" 2>/dev/null | head -1)"
  fi
  [ -n "$s" ] || s="${t%.timer}.service"
  printf '%s' "$s"
}

# service -> 它执行的脚本绝对路径（ExecStart 的最后一个字段）
service_script() {
  local s="$1" line=""
  if [ -f "$UNIT_DIR/$s" ]; then
    line="$(sed -n 's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*//p' "$UNIT_DIR/$s" 2>/dev/null | head -1)"
  fi
  line="${line%"${line##*[![:space:]]}"}"     # 去尾部空白
  [ -n "$line" ] || return 0
  printf '%s' "${line##* }"
}

# 脚本目录里的 domains.conf -> 每行第一张证书的主域名
domains_of() {
  local d="$1"
  local f="$d/domains.conf"
  [ -f "$f" ] || return 0
  awk '
    { sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    $0 == "" { next }
    {
      split($0, a, "|")
      d = a[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", d)
      if (d == "") next
      split(d, b, /[[:space:]]+/)
      if (b[1] != "") print b[1]
    }
  ' "$f"
}

# 脚本目录里的 ssl.conf -> SSL_OUTPUT_DIR（只读文本，不 source）
outdir_of() {
  local d="$1"
  local f="$d/ssl.conf"
  local v=""
  [ -f "$f" ] || { printf 'ssl'; return 0; }
  v="$(sed -n 's/^[[:space:]]*SSL_OUTPUT_DIR[[:space:]]*=[[:space:]]*//p' "$f" 2>/dev/null | head -1)"
  v="${v%\"}"; v="${v#\"}"
  v="${v%"${v##*[![:space:]]}"}"
  [ -n "$v" ] || v="ssl"
  printf '%s' "$v"
}

# 脚本目录该装哪个 unit 名 —— 这是判断"某个 timer 是不是这个目录亲手装出来的"
# 权威依据（比猜目录名可靠）。
#
#  ★ 单一事实来源是脚本目录里的 ssl.conf：
#        SSL_UNIT_NAME="ssl-nginx-renew"   ⇒ 本目录该装 ssl-nginx-renew.timer/.service
#    没写 SSL_UNIT_NAME 时退回 lib.sh 的默认值 ssl-renew —— 与 ssl-setup.sh 一致。
#  （老版本曾在 ssl-setup.sh 里写死 TIMER_NAME="..."，现在改成从 ssl.conf 派生；
#    这里保留对旧字面量的回退，方便同一台机器上残留的旧目录也能被正确识别。）
declared_unit_of() {   # declared_unit_of <脚本目录> <TIMER_NAME|SVC_NAME>
  local d="$1" key="$2"
  local f v suffix
  [ -n "$d" ] || return 0
  case "$key" in
    TIMER_NAME) suffix=".timer" ;;
    SVC_NAME)   suffix=".service" ;;
    *)          suffix="" ;;
  esac

  # ① 首选：ssl.conf 里的 SSL_UNIT_NAME
  v="$(unit_name_of "$d")"

  # ② 回退：ssl-setup.sh 里的旧字面量 TIMER_NAME="..."/SVC_NAME="..."
  if [ -z "$v" ]; then
    f="$d/ssl-setup.sh"
    [ -f "$f" ] && v="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$f" 2>/dev/null | head -1)"
    case "$v" in
      *'${'*|*'{'*) v="" ;;   # 是派生表达式（如 ${SSL_UNIT_NAME}.timer），不是字面量
    esac
  fi
  [ -n "$v" ] || v="ssl-renew"
  case "$key" in
    TIMER_NAME|SVC_NAME) printf '%s%s' "${v%$suffix}" "$suffix" ;;
    *)                   printf '%s' "${v%$suffix}" ;;
  esac
}

# 脚本目录里的 ssl.conf -> SSL_UNIT_NAME（只读文本，不 source）
unit_name_of() {
  local d="$1"
  local f="$d/ssl.conf"
  local v=""
  [ -f "$f" ] || return 0
  v="$(sed -n 's/^[[:space:]]*SSL_UNIT_NAME[[:space:]]*=[[:space:]]*//p' "$f" 2>/dev/null | head -1)"
  v="${v%\"}"; v="${v#\"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    ''|*[!A-Za-z0-9_.@-]*) printf '%s' "" ;;   # 非法或空 ⇒ 交给调用方回退
    *)                     printf '%s' "$v" ;;
  esac
}

# 脚本目录 -> 项目根（与 lib.sh 的推导一致：脚本目录的 ../..）
project_root_of() {
  local d="$1"
  ( cd -- "$d/../.." 2>/dev/null && pwd ) || printf '%s' "$d"
}

# 脚本目录 -> renew.log 的实际路径
log_path_of() {
  local d="$1" od
  od="$(outdir_of "$d")"
  case "$od" in
    /*) printf '%s/renew.log' "$od" ;;
    *)  printf '%s/%s/renew.log' "$(project_root_of "$d")" "$od" ;;
  esac
}

is_enabled() { "$SYSTEMCTL" is-enabled --quiet "$1" 2>/dev/null; }
is_active()  { "$SYSTEMCTL" is-active  --quiet "$1" 2>/dev/null; }

# -----------------------------------------------------------------------------
#  体检
# -----------------------------------------------------------------------------
printf '\n  SSL 续期定时器 体检\n'
rule
printf '  %-10s %s\n' "单元目录" "$UNIT_DIR"
printf '  %-10s %s\n' "模式" "$([ "$APPLY" = 1 ] && echo "执行清理（--apply）" || echo "只读体检（不修改任何东西）")"

mapfile -t TIMERS < <(find_timers)
N_TIMERS="${#TIMERS[@]}"

printf '\n  [发现] %s 个续期定时器\n' "$N_TIMERS"

if [ "$N_TIMERS" -eq 0 ]; then
  warn "这台机器上没有安装任何 ssl*.timer —— 续期不会自动跑。"
  info "安装：到对应的脚本目录执行 sudo ./ssl-setup.sh"
  printf '\n'
  exit 0
fi

# 记录每个 timer 的脚本目录与域名，供后续比对
declare -A T_SVC=() T_SCRIPT=() T_SCRIPTDIR=() T_OUTDIR=() T_LOG=() T_DECL=()

for t in "${TIMERS[@]}"; do
  svc="$(timer_service "$t")"
  script="$(service_script "$svc")"
  sdir=""; [ -n "$script" ] && sdir="$(dirname "$script")"

  T_SVC["$t"]="$svc"
  T_SCRIPT["$t"]="$script"
  T_SCRIPTDIR["$t"]="$sdir"
  T_OUTDIR["$t"]="$(outdir_of "$sdir")"
  T_LOG["$t"]="$(log_path_of "$sdir")"
  T_DECL["$t"]="$(declared_unit_of "$sdir" TIMER_NAME)"

  printf '\n  ● %s\n' "$t"
  if is_enabled "$t"; then st="enabled"; else st="disabled"; fi
  if is_active  "$t"; then st="$st / active"; else st="$st / 未运行"; fi
  printf '      状态     %s\n' "$st"
  printf '      服务     %s\n' "$svc"
  if [ -z "$script" ]; then
    bad "服务文件里读不到 ExecStart —— 单元可能已被手改坏，请人工检查 $UNIT_DIR/$svc"
    continue
  fi
  printf '      脚本     %s\n' "$script"
  if [ ! -f "$script" ]; then
    bad "脚本文件不存在！定时任务每次都会失败（ExecStart 指向了不存在的路径）"
  fi
  printf '      输出目录 %s\n' "${T_OUTDIR[$t]}"
  printf '      日志     %s\n' "${T_LOG[$t]}"

  dec="${T_DECL[$t]}"
  if [ -z "$dec" ]; then
    printf '      归属     %s\n' "（脚本目录里没找到可用的 ssl.conf，无法判断本目录该装哪个 unit）"
  elif [ "$t" = "$dec" ]; then
    printf '      归属     %s\n' "✔ 自洽 —— 本目录该装的就是它"
  else
    printf '      归属     %s\n' "✘ 外来户 —— 本目录该装的是 ${dec}，不是这个"
  fi

  mapfile -t dsel < <(domains_of "$sdir")
  if [ "${#dsel[@]}" -eq 0 ]; then
    printf '      管着     %s\n' "（domains.conf 里没有生效的域名）"
  else
    printf '      管着     %s 张证书：%s\n' "${#dsel[@]}" "${dsel[*]}"
  fi

  lp="${T_LOG[$t]}"
  if [ -f "$lp" ]; then
    printf '      最近记录 %s\n' "$(tail -n 1 "$lp")"
  else
    printf '      最近记录 %s\n' "（还没有 renew.log）"
  fi
done

# -----------------------------------------------------------------------------
#  只有一个：没有冲突，但可能"名字不配套"
# -----------------------------------------------------------------------------
if [ "$N_TIMERS" -eq 1 ]; then
  t0="${TIMERS[0]}"
  d0="${T_SCRIPTDIR[$t0]}"
  dec0="${T_DECL[$t0]:-}"

  if [ -n "$dec0" ] && [ "$t0" != "$dec0" ]; then
    printf '\n  [结论] '
    ok "没有冲突 —— 机器上只有这 1 个续期定时器，功能正常，不需要删任何东西。"
    printf '\n  [提示] '
    warn "但它的 unit 名和脚本目录**不配套**，不是这个目录的配置装出来的。"
    info "本目录：${d0}"
    info "  它目录里的 ssl.conf 声明要装：${dec0}"
    info "  实际装着的是：            ${t0}"
    printf '\n'
    info "常见原因：这个目录里的文件是从**另一套**复制过来的（比如把 /opt/ssl/ 的内容"
    info "倒进了 /opt/ssl-old/ 之类的目录），而 unit 是更早、或手工装上去的。"
    info "功能上没影响 —— 脚本本身不看 unit 名，只看 ExecStart 指向谁。只是名字对不上，"
    info "以后排障容易看糊涂。"
    printf '\n'
    info "★ 另外提醒：如果你在这个目录直接跑 ./ssl-setup.sh，它会**再装一个 ${dec0}** ——"
    info "  于是机器上就有两个定时器、指向同一份脚本了（就是另一个变体常见的翻车方式）。"
    printf '\n'
    info "想统一命名的话（把 ${t0} 换成 ${dec0}）："
    printf '       %s disable --now %s\n' "$SYSTEMCTL" "$t0"
    printf '       rm -f %s/%s %s/%s\n' "$UNIT_DIR" "$t0" "$UNIT_DIR" "${T_SVC[$t0]}"
    printf '       %s daemon-reload\n' "$SYSTEMCTL"
    printf '       cd %s && ./ssl-setup.sh\n' "$d0"
    printf '       %s list-timers %s --no-pager\n' "$SYSTEMCTL" "$dec0"
    printf '\n'
    warn "换名前先确认 ${d0}/ssl.conf 的 SSL_OUTPUT_DIR 是对的（当前：${T_OUTDIR[$t0]}）——"
    info "setup 装完会顺带跑一次签发，输出目录写错会把证书签错地方。"
  else
    printf '\n  [结论] '
    ok "只有一套定时器，无需修复。"
    printf '         %s → %s\n' "$t0" "${T_SCRIPT[$t0]}"
  fi
else
  # ---------------------------------------------------------------------------
  #  多个：冲突分析
  # ---------------------------------------------------------------------------
  printf '\n  [冲突] 发现 %s 个定时器同时在管续期\n' "$N_TIMERS"
  info "它们各自续各自 domains.conf 里的证书 —— 不会互相覆盖，但一件事有两套在管，"
  info "排障时很难分清谁是谁（本次就是这样被坑的）。"

  # 需要保留谁
  if [ -z "$KEEP" ]; then
    # 体检模式下给个建议，优先级从高到低：
    #   ① unit 名与本脚本目录"自洽"（= 本目录 ssl.conf 的 SSL_UNIT_NAME）——
    #      最强判据：不自洽的就是从别的套件误装进来的外来户
    #   ② 管的域名最多（尽量不丢东西）
    #   ③ 名字排序（保证结果稳定、可复现）
    cand=()
    for t in "${TIMERS[@]}"; do is_enabled "$t" && cand+=("$t"); done
    [ "${#cand[@]}" -gt 0 ] || cand=("${TIMERS[@]}")

    sug=""; sug_fit=0; sug_n=-1
    for t in "${cand[@]}"; do
      mapfile -t _d < <(domains_of "${T_SCRIPTDIR[$t]}")
      n="${#_d[@]}"
      fit=0
      [ -n "${T_DECL[$t]}" ] && [ "$t" = "${T_DECL[$t]}" ] && fit=1
      if [ "$fit" -gt "$sug_fit" ] || { [ "$fit" -eq "$sug_fit" ] && [ "$n" -gt "$sug_n" ]; }; then
        sug="$t"; sug_n="$n"; sug_fit="$fit"
      fi
    done
    [ -n "$sug" ] || sug="${cand[0]}"

    printf '\n  [建议] 保留 %s，删除其余 %s 个\n' "$sug" "$((N_TIMERS - 1))"
    if [ "$sug_fit" = 1 ]; then
      printf '         依据：unit 名与脚本目录自洽 —— %s 里的 ssl.conf 的 SSL_UNIT_NAME 就是它\n' "${T_SCRIPTDIR[$sug]}"
      printf '               且它管着 %s 张证书，覆盖最全\n' "$sug_n"
    else
      printf '         依据：它管着 %s 张证书\n' "$sug_n"
      warn "候选里没有一个能与脚本目录自洽，请用 --keep 人工指定要留哪个，别照抄上面的命令。"
    fi
    printf '\n  [下一步] 先看下面的域名检查结果，确认不会丢域名后执行：\n'
    printf '         ./ssl-repair.sh --apply --keep %s\n' "$sug"
    printf '\n'
    # 体检模式仍然做域名检查（只读），把风险提前暴露
    KEEP_FOR_CHECK="$sug"
  else
    KEEP_FOR_CHECK="$KEEP"
  fi

  # 校验 --keep 合法性
  keep_ok=0
  for t in "${TIMERS[@]}"; do [ "$t" = "$KEEP_FOR_CHECK" ] && keep_ok=1; done
  if [ "$keep_ok" != 1 ]; then
    printf '\n'
    bad "--keep 的 ${KEEP_FOR_CHECK} 不在本机定时器列表里。可选：${TIMERS[*]}"
    exit 1
  fi

  # 要删的
  REMOVE=()
  for t in "${TIMERS[@]}"; do
    [ "$t" = "$KEEP_FOR_CHECK" ] && continue
    REMOVE+=("$t")
  done

  printf '\n  [检查] 删掉其余 %s 个之后，会不会有域名没人续期？\n' "${#REMOVE[@]}"

  KEEP_DOMAINS="$(for t in "${TIMERS[@]}"; do [ "$t" = "$KEEP_FOR_CHECK" ] || continue; domains_of "${T_SCRIPTDIR[$t]}"; done)"
  LOST=()
  for t in "${REMOVE[@]}"; do
    while IFS= read -r dom; do
      [ -n "$dom" ] || continue
      if ! printf '%s\n' "$KEEP_DOMAINS" | grep -qx -- "$dom"; then
        # 去重
        dup=0
        for x in ${LOST[@]+"${LOST[@]}"}; do [ "$x" = "$dom" ] && dup=1; done
        [ "$dup" = 1 ] || LOST+=("$dom")
      fi
    done < <(domains_of "${T_SCRIPTDIR[$t]}")
  done

  if [ "${#LOST[@]}" -eq 0 ]; then
    ok "不会丢域名 —— 准备删除的那套，它的证书在保留的那套里都有。"
  else
    bad "有 ${#LOST[@]} 个域名只出现在准备删除的那套里，删掉之后将**无人续期**："
    for x in "${LOST[@]}"; do printf '         · %s\n' "$x"; done
    printf '\n'
    info "两个办法（任选）："
    info "  A) 把它们补进保留那套的域名列表，再回来执行清理："
    printf '       %s/domains.conf\n' "${T_SCRIPTDIR[$KEEP_FOR_CHECK]}"
    info "     补完后先签发一次，确认新证书出来了："
    printf '       %s\n' "${T_SCRIPT[$KEEP_FOR_CHECK]}"
    info "  B) 反过来保留另一套（如果那套才是你真正在用的）："
    printf '       ./ssl-repair.sh --apply --keep %s\n' "${REMOVE[0]}"
  fi

  # 被删的那套是否指向了另一个脚本（提示用）
  for t in "${REMOVE[@]}"; do
    if [ "${T_SCRIPTDIR[$t]}" = "${T_SCRIPTDIR[$KEEP_FOR_CHECK]}" ]; then
      info "注：${t} 与要保留的那套指向**同一个脚本目录**（${T_SCRIPTDIR[$t]}），"
      info "    读的是同一份 domains.conf、写的是同一个 renew.log —— 纯属重复安装，删它零风险。"
    fi
  done

  # ---------------------------------------------------------------------------
  #  执行
  # ---------------------------------------------------------------------------
  if [ "$APPLY" != 1 ]; then
    printf '\n  [结论] 这是体检，未做任何修改。\n'
    if [ "${#LOST[@]}" -gt 0 ]; then
      printf '         先按上面 A) 或 B) 处理域名问题，再执行清理。\n'
    else
      printf '         确认无误后执行：\n'
      printf '         ./ssl-repair.sh --apply --keep %s\n' "$KEEP_FOR_CHECK"
    fi
    printf '\n'
    exit 0
  fi

  if [ "${#LOST[@]}" -gt 0 ] && [ "$FORCE" != 1 ]; then
    printf '\n'
    bad "拒绝执行：会造成 ${#LOST[@]} 个域名失去自动续期。"
    info "确认这些域名另有安排（比如已并入别处），再加 --force。"
    printf '\n'
    exit 1
  fi

  printf '\n  [执行] 保留 %s，删除 %s 个\n' "$KEEP_FOR_CHECK" "${#REMOVE[@]}"
  for t in "${REMOVE[@]}"; do
    svc="${T_SVC[$t]}"
    printf '\n     · %s\n' "$t"
    "$SYSTEMCTL" disable --now "$t" >/dev/null 2>&1 && info "已停止并禁用" || info "已停止并禁用（或本来就未启用）"
    "$SYSTEMCTL" reset-failed "$t" >/dev/null 2>&1 || true
    if rm -f "$UNIT_DIR/$t"; then info "已删除 $UNIT_DIR/$t"; else bad "删除失败：$UNIT_DIR/$t"; fi

    # 只有当没有别的 timer 还在引用这个 service 时才删它
    still=0
    for o in "${TIMERS[@]}"; do
      [ "$o" = "$t" ] && continue
      [ "${T_SVC[$o]}" = "$svc" ] && still=1
    done
    if [ "$still" = 0 ] && [ -f "$UNIT_DIR/$svc" ]; then
      "$SYSTEMCTL" reset-failed "$svc" >/dev/null 2>&1 || true
      rm -f "$UNIT_DIR/$svc" && info "已删除 $UNIT_DIR/$svc" || bad "删除失败：$UNIT_DIR/$svc"
    elif [ "$still" = 1 ]; then
      info "保留 $svc（仍有其它定时器在引用它）"
    fi
  done

  "$SYSTEMCTL" daemon-reload >/dev/null 2>&1 && ok "已 daemon-reload" || warn "daemon-reload 失败，请手工执行"

  printf '\n  [复验]\n'
  printf '     剩余定时器：\n'
  mapfile -t LEFT < <(find_timers)
  if [ "${#LEFT[@]}" -eq 0 ]; then
    bad "一个都不剩了！请重新执行 ssl-setup.sh 安装。"
  else
    for t in "${LEFT[@]}"; do printf '       · %s\n' "$t"; done
  fi
  printf '     %s 状态：' "$KEEP_FOR_CHECK"
  if is_enabled "$KEEP_FOR_CHECK" && is_active "$KEEP_FOR_CHECK"; then
    printf 'enabled / active\n'
  else
    printf '异常，请检查\n'
    warn "修复：$SYSTEMCTL enable --now $KEEP_FOR_CHECK"
  fi
  printf '\n'
  "$SYSTEMCTL" list-timers "$KEEP_FOR_CHECK" --no-pager 2>/dev/null | head -n2 | sed 's/^/     /' || true
  printf '\n     建议现在手工跑一次，确认它能正常工作：\n'
  printf '       %s start %s\n' "$SYSTEMCTL" "${T_SVC[$KEEP_FOR_CHECK]}"
  printf '       tail -n 3 %s\n' "${T_LOG[$KEEP_FOR_CHECK]}"
fi

# -----------------------------------------------------------------------------
#  acme.sh 自带 crontab —— 会和本定时器重复续期
# -----------------------------------------------------------------------------
printf '\n  [检查] acme.sh 自带 crontab\n'
if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -qi 'acme'; then
    warn "检测到 acme.sh 的 crontab 还在，它会和本定时器**重复续期**。"
    info "清理：/root/.acme.sh/acme.sh --uninstall-cronjob"
  else
    ok "没有发现 acme.sh 的 crontab，调度只由本定时器负责。"
  fi
else
  info "系统没有 crontab 命令，跳过检查。"
fi
printf '\n'
