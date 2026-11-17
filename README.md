# Let's Encrypt 证书自动签发 / 续期套件

用 **DNS-01 验证**给一批域名签发 Let's Encrypt 证书：**每个域名一张独立证书、各自管理到期时间**，
到期前自动续期，续完自动让你的服务（Traefik / nginx / 任意容器）用上新证书。

- 不需要 80 端口对外，不需要服务器上有 Web 服务在跑
- 全程只用系统自带的 `bash / curl / openssl / tar`，**不装任何 rpm / deb**
- 证书更新后**不重启 Traefik 容器**（热加载，实测 2 秒完成）
- 每次运行往文件里追加一行结果 —— CentOS 8 的 journal 默认不持久化，重启查不到历史

> 本文是仓库入口，讲「怎么用、怎么运维、出问题看哪里」。
> 每个参数的细节、每个坑的成因，在 **[`scripts/README.md`](scripts/README.md)**（十五节，1100+ 行）。

---

## 一、三条核心设计

### 1. 只有一套代码

早期是 `scripts/ssl/`（Traefik 版）和 `scripts/ssl-nginx/`（nginx 版）两份目录，代码 99% 相同。
两份并排维护的代价是**每次改逻辑都要改两遍，而且复制目录时一定会漏改某处**
（真漏过：`ssl-status.sh` 里写死的 unit 名没跟着改，状态检查一直去查另一套的 unit，
报「未安装」，白误导了一轮排查）。

现在收敛成一套：**代码只此一份、目录也只有一层，差异全部外置成配置**。

```
scripts/                        ← 唯一的一套代码，没有 ssl/ 子目录
  │  读 ssl.conf + renewpost.sh 的 RELOAD_MODE
  ├─▶ Traefik 机器   SSL_OUTPUT_DIR=/root/cert        SSL_UNIT_NAME=ssl-renew         MODE=traefik
  └─▶ nginx   机器   SSL_OUTPUT_DIR=/etc/nginx/ssl    SSL_UNIT_NAME=ssl-nginx-renew   MODE=nginx
```

**部署到第二台机器时，只改两行 + 一行**：

```bash
# ① ssl.conf —— 两项
SSL_OUTPUT_DIR="/etc/nginx/ssl"      # 证书落到哪
SSL_UNIT_NAME="ssl-nginx-renew"      # systemd unit 名（同机装两套时必须不同）

# ② renewpost.sh —— 复制唯一模板，再改一行
cp renewpost.sh.example renewpost.sh && chmod +x renewpost.sh
sed -i 's/^RELOAD_MODE="none"/RELOAD_MODE="nginx"/' renewpost.sh
```

> **脚本目录叫什么名字都不影响功能。** 判断「这台机器该装哪个 unit」的唯一依据是
> `ssl.conf` 里的 `SSL_UNIT_NAME`，不是目录名 —— 两台服务器上的目录**可以都叫 `/opt/ssl`**。

### 2. 四个文件分离，别合并

| 文件 | 放什么 | 敏感 | 进 Git |
|---|---|---|---|
| `secrets.env` | **只有** DNS 服务商的 API 凭据（可多服务商 × 多账号） | ★ 是 | ✗ 已 gitignore |
| `domains.conf` | 域名列表，**每行一张证书**，可标 `dns=` / `account=` / `renew=` / `dir=` | 否 | ✓ |
| `ssl.conf` | 全局策略（邮箱、算法、输出目录、unit 名、阈值…） | 否 | ✓ |
| `renewpost.sh` | 证书更新后干什么（重启 nginx / 触发热加载 / 重建容器） | 含服务器路径 | ✗ 已 gitignore |

好处：密钥只放密钥，一眼看出有没有泄露；加域名就是加一行，不用碰任何密钥。

### 3. 重载只做一次，且只在真有证书更新之后

`ssl-issue.sh` 遍历所有证书，**最后统一执行一次** `renewpost.sh`。
绝不给 acme.sh 传 `--reloadcmd` —— 那会让 acme.sh 每装一张证书就跑一次，
加上结尾那次等于重载 N+1 次，对 `docker compose --force-recreate` 这种重活尤其浪费。

全部证书都在有效期内时，`renewpost.sh` **根本不会执行**，不会白重启一次服务。

---

## 二、目录结构

```
<项目根>/
├── README.md                      # 本文件：总览 / 快速上手 / 运维手册
├── .gitattributes                 # ★ 强制 *.sh 为 LF 行尾（Windows 开发必看）
├── .gitignore                     # 排除 secrets.env / renewpost.sh 与所有证书私钥
└── scripts/                       # ★ 全部代码与配置都在这一层，没有 ssl/ 子目录
    ├── README.md                  # 详细文档（十五节，1100+ 行）
    ├── lib.sh                     # 共用函数库（不直接执行）★ 服务商规格表在这里
    ├── ssl-issue.sh               # 批量签发 / 续期
    ├── ssl-status.sh              # 每张证书的到期时间总览
    ├── ssl-setup.sh               # 一次性初始化 + 装 systemd timer
    ├── ssl-repair.sh              # 定时器体检 / 冲突分析 / 收敛成一个
    ├── ssl.conf                   # 全局策略     ← 每台机器改 2 处
    ├── secrets.env.example        # 凭据模板（腾讯云 + GoDaddy 两段）
    ├── secrets.env                # ★ 真实凭据   ← 复制后填，不进 Git
    ├── domains.conf               # ★ 域名列表   ← 加域名改这里
    ├── renewpost.sh.example       # ★ 唯一的续期钩子模板，顶部 RELOAD_MODE 四选一
    ├── renewpost.sh               # ★ 服务器本地钩子 ← 复制后改，不进 Git
    └── dynamic_conf.toml          # Traefik 消费方配置参考（本地留档，防重装丢失）
```

> **没有 `scripts/ssl/` 这一层。** 以前有两台机器就有两个目录（`ssl/` 和 `ssl-nginx/`），
> 后来发现差异只有「输出目录 / unit 名 / 钩子动作」三项 —— 全部能外置成配置，
> 于是所有文件直接铺在 `scripts/` 下，一套代码管所有机器。

证书输出（`flat` 布局，`SSL_OUTPUT_DIR` 下的样子）：

```
/root/cert/                                 # Traefik 机器
├── example.com.fullchain.pem               # ← 消费方引用这个（叶子 + 中间 CA）
├── example.com.privkey.pem                 # ← 权限 600
├── example.com.cert.pem                    # 叶子证书（单独用）
├── example.com.chain.pem                   # 中间 CA
└── renew.log                               # ★ 每次运行一行结果摘要
```

---

## 三、5 分钟跑起来

### 0. 前置条件

- Linux 服务器（CentOS 8 / Rocky / Alma / Ubuntu 都行），**root**
- 域名 DNS 托管在受支持的服务商：**腾讯云 DNSPod** / **GoDaddy**
- 能用 API 写 TXT 记录的凭据（腾讯云子账号 + 仅 DNS 权限最稳）

CentOS 8 已 EOL，官方源下线 —— 本套脚本**不依赖任何包安装**，只用系统自带的二进制。

### 1. 传到服务器

```bash
# 本地
cd scripts
scp lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh \
    ssl.conf secrets.env.example domains.conf renewpost.sh.example README.md \
    root@<服务器IP>:/opt/ssl/

# 服务器
ssh root@<服务器IP>
cd /opt/ssl
sed -i 's/\r$//' *.sh                              # scp 不保证行尾
chmod +x ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh
bash -n *.sh && echo '语法 OK'
```

> **行尾是硬要求。** Windows 上 checkout 出来的 CRLF 脚本在 Linux 执行会报
> `bad interpreter: No such file or directory`。`.gitattributes` 已强制 LF，
> 但 scp 传输和手工编辑仍可能带进来，部署后必须过一遍 `sed -i 's/\r$//'`。

### 2. 填两个文件

**`secrets.env`**（照着 `secrets.env.example` 改，改完 `chmod 600`）：

```bash
# 腾讯云 DNSPod —— 默认账号
Tencent_SecretId="AKIDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
Tencent_SecretKey="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# 第二个账号：变量名加后缀，domains.conf 里用 account=ACC2 指定
# Tencent_SecretId_ACC2="..."
# Tencent_SecretKey_ACC2="..."

# GoDaddy —— 必须是 Production Key（OTE 无效）
# GD_Key="..."
# GD_Secret="..."
```

> ★ **`secrets.env` 里绝不能有同名变量重复定义。** 脚本用 `source` 读它，
> 同名变量后者覆盖前者 —— 文件里若躺着两组凭据，ID 与 KEY 可能来自**不同的组**，
> 表现是腾讯云回 `AuthFailure.SignatureFailure`，而两组 Key 的长度/字符集全合法，
> 从形状上根本查不出来。

**`ssl.conf`**（必改两项）：

```bash
SSL_EMAIL="you@example.com"          # ACME 账号邮箱，必填

SSL_OUTPUT_DIR="/root/cert"          # Traefik 机器；nginx 机器写 /etc/nginx/ssl
SSL_UNIT_NAME="ssl-renew"            # Traefik 机器；nginx 机器写 ssl-nginx-renew

SSL_OUTPUT_LAYOUT="flat"             # flat 布局：<域名>.fullchain.pem
SSL_KEY_LENGTH="ec-256"              # ECDSA P-256，体积小、握手快
SSL_RENEW_DAYS="30"                  # 剩余天数 <= 30 就续（每张可单独覆盖）
SSL_DNS_SLEEP="20"                   # 腾讯云 20 够；GoDaddy 建议 60
SSL_KEEP_GOING="1"                   # 一个失败继续处理后面的
```

**`domains.conf`**（复制一行就是加一张证书）：

```bash
# 每行 = 一张证书，多个域名用空格分隔，第一个是主域名（必须非泛域名）
example.com www.example.com
*.example.com example.com | renew=21

# 跨服务商 / 跨账号必须拆行（DNS-01 一次只能用一套凭据）
api.example.com   | dns=godaddy account=GD2
cn.example.com    | account=ACC2
```

### 3. 首次签发

```bash
./ssl-issue.sh --check-only      # 先看会做什么，不改动任何东西
./ssl-setup.sh --staging        # 走 LE 测试环境演练全流程（可选但推荐）
sudo ./ssl-setup.sh             # 正式：签发 + 装 systemd timer
```

`ssl-setup.sh` 会依次做：

1. 生成 `secrets.env`（如果还没有）并锁死 600
2. 按本机情况生成 `renewpost.sh` 并设好 `RELOAD_MODE`
   （有 nginx → `nginx`；有 `dynamic_conf.toml` → `traefik`；只有 compose 目录 → `compose`）
3. 检查域名列表与邮箱
4. 环境体检（配置 / 网络 / NS 归属）
5. **首次签发**：逐张签发并部署
6. 装配 `systemd` timer（`<SSL_UNIT_NAME>.timer`，每天自动检查）

### 4. 验收

```bash
./ssl-status.sh                  # 到期时间总览（含最近运行日志）
systemctl list-timers 'ssl*'     # 确认定时器已启用
cat /root/cert/renew.log         # 每次运行一行结果
```

---

## 四、证书更新后做什么：一个模板，四种模式

这是整套东西和「消费方」之间唯一的耦合点。仓库里只有 **一个** 模板
`renewpost.sh.example`，顶部的 `RELOAD_MODE` 决定它干什么：

| `RELOAD_MODE` | 动作 | 用在 |
|---|---|---|
| `none` | 什么都不做 | 不需要重载的机器（**干脆不建这个文件更干净**） |
| `nginx` | `nginx -t` → `systemctl restart nginx` → 校验 `is-active` | nginx 机器 |
| `traefik` | 碰动态配置触发热加载 → serial 回连比对 → 没生效再重启容器 | Traefik 机器（**无中断**） |
| `compose` | `docker compose up --force-recreate` → 校验容器 `running` | 其它容器服务 |

### Traefik 为什么不用重启

Traefik 的 file provider **只监听 `dynamic_conf.toml`（配置文件），不监听 `.pem` 证书文件** ——
证书换了它毫无感知。所以钩子干三件事：

```bash
# ① 比对：磁盘证书 serial vs Traefik 实际下发的 serial（openssl s_client -servername）
# ② 碰一下：sed -i 原样重写 dynamic_conf.toml 里的一行注释
#    → 内容零变化（md5 相同），但产生真实写入事件 → file provider 重载 → 重读证书
# ③ 兜底：等 10 秒还是旧证书 → docker restart 容器
```

实测：换 7 张证书，**2 秒完成，容器一次没重启**，日志留下 `✔ 热加载生效，未重启`。

> **只有热加载失灵时才会真重启**，脚本会先打一行 `热加载未生效，退回重启 xxx`。
> 可能原因：`watch = true` 被改掉 / `dynamic_conf.toml` 里锚点注释被删（sed 匹配不到
> 就不产生写入）/ 配置文件语法错误被 Traefik 拒绝加载。

### nginx 为什么用 `restart` 而不是 `reload`

`reload` 有「看起来没生效」的坑：① 旧 worker 要等长连接（keepalive / WebSocket / 长轮询）
处理完才退，`worker_shutdown_timeout` 默认无限等，这些残留 worker 手里还是旧证书；
② `ssl_session_cache` 跨 worker 共享、`reload` 不清它，老客户端复用会话时跳过证书交换。

`restart` 重建 master + 清缓存，中断通常 < 1 秒。验证必须绕开会话复用：

```bash
echo | openssl s_client -connect <域名>:443 -servername <域名> \
  -no_ticket -no_reuse 2>/dev/null | openssl x509 -noout -dates
```

---

## 五、当前这套的两台机器

| | Traefik 机器 | nginx 机器 |
|---|---|---|
| 主机名 | `VM-12-2-centos` | `b919p4` |
| 系统 | CentOS 8.5 | — |
| 证书输出 | `/root/cert` | `/etc/nginx/ssl` |
| unit 名 | `ssl-renew` | `ssl-nginx-renew` |
| 钩子模式 | `traefik`（热加载，无中断） | `nginx`（restart） |
| 引用方式 | `dynamic_conf.toml` 的 `[[tls.certificates]]` | `ssl_certificate=/etc/nginx/ssl/<域名>.fullchain.pem` |

两台机器上的目录**可以都叫 `/opt/ssl`** —— unit 名只看 `SSL_UNIT_NAME`，与目录名无关。
（当前 `VM-12-2-centos` 上实际用的是 `/root/scripts/ssl`，本文其余部分统一用 `/opt/ssl` 举例。）

---

## 六、日常命令

```bash
./ssl-status.sh                              # 到期时间总览（含最近运行日志）
./ssl-status.sh --detail                     # 详情
./ssl-status.sh --quiet                      # 一行汇总（适合监控脚本）
./ssl-issue.sh --check-only                  # 只看会做什么，不改动
./ssl-issue.sh                               # 该续的续，该跳的跳
./ssl-issue.sh --domain api.example.com      # 只处理一张
./ssl-issue.sh --domain api.example.com --force   # 只强制重签一张
./ssl-issue.sh --list                        # 只看解析后的列表（含 dns=/account=）
./ssl-issue.sh --staging --debug             # 测试环境 + 详细日志
bash renewpost.sh --dry-run                  # 空跑一遍后置钩子，不碰服务
sudo ./ssl-repair.sh                         # 定时器体检（只读）
```

### 加一个域名

```bash
vi domains.conf          # 加一行
./ssl-issue.sh           # 新域名会自动签发
```

### 续期是怎么判定的

**不交给 acme.sh 的内部调度**。脚本按 `剩余天数 <= 该证书自己的 renew 阈值` 自己判断，
只有判定需要续期才加 `--force`。所以 `ssl.conf` 里的 `SSL_RENEW_DAYS` 就是你实际生效的阈值，
不会出现「以为设了 30 天，其实 acme.sh 按 60 天自己跑了」。

---

## 七、排障：现象 → 查什么

| 现象 | 第一反应 | 看哪里 |
|---|---|---|
| 某天 `renew.log` **完全没有记录** | 任务压根没跑起来 | `systemctl list-timers 'ssl*'`、`journalctl -u <unit>.service` |
| 有 `FAIL` 行 | 某张证书或钩子失败 | `journalctl -u <unit>.service -n 200 --no-pager` |
| `AuthFailure.SignatureFailure` | **不是密钥过期** | `grep -c '^Tencent_SecretId' secrets.env`（应为 1）；核对 ID/KEY 是否同源抄错 |
| `Error adding TXT record` | 别急着怀疑 CNAME/NS | `./ssl-issue.sh --domain X --debug` 看 `code`/`response` |
| 续期成功但线上还是旧证书 | 钩子没生效 | `journalctl` 搜「热加载」；手工 `bash renewpost.sh` 重跑 |
| 多个站点**同时**变默认证书 | 共同依赖挂了 | `docker exec <容器> ls -l /root/cert` + 容器日志 |
| `Text file busy` | 文件被写占用，**不是内容问题** | 见下方「升级」小节的换 inode 方法 |
| `list-timers` 显示 0 个 | 没装 / 没 enable / unit 名对不上 | `systemctl cat <unit>.timer`（别用 `list-unit-files` 判断存在性） |

> `renew.log` 格式：
> `2026-11-17 03:35:03  OK   处理=10  更新=7  跳过=3  失败=0  模式=定时  后置钩子=成功`
>
> `模式=定时` 由 `JOURNAL_STREAM` / `PPID=1` / `INVOCATION_ID` 三者任一判定 ——
> CentOS 8 的 systemd 239 **不会**把 `INVOCATION_ID` 导出给进程，只看它会误标成「手动」。

---

## 八、安全边界（必须遵守）

- `secrets.env` 是**唯一**的敏感文件：权限 600、已被 gitignore、脚本每次运行都检查权限。
- 日志里只出现 **ID 末 4 位**（如 `尾号 …7f3a`）用于辨认账号，**从不打印 SecretKey**。
- 私钥部署后自动 `chmod 600`；所有证书与私钥都在 `SSL_OUTPUT_DIR` 下且已被 gitignore。
- 建议每个服务商都用**子账号 + 仅 DNS 权限**的凭据，别用主账号密钥。
- 验证凭据没进版本库：
  ```bash
  git check-ignore -v scripts/secrets.env     # 应输出忽略规则
  git check-ignore -v scripts/renewpost.sh   # 应输出忽略规则
  git grep -n 'AKID' $(git rev-list --all) 2>/dev/null   # 应无输出
  ```

---

## 九、升级脚本：只换脚本，配置一律不许覆盖

| 类别 | 文件 | 升级时 |
|---|---|---|
| **脚本** | `lib.sh`、`ssl-issue.sh`、`ssl-status.sh`、`ssl-setup.sh`、`ssl-repair.sh`、`README.md` | ✅ 覆盖 |
| **模板**（可选） | `renewpost.sh.example` | ✅ 覆盖（不影响服务器上已有的 `renewpost.sh`） |
| **配置** | `secrets.env`、`domains.conf`、`ssl.conf`、`renewpost.sh` | ⛔ **绝不能覆盖** |
| 服务器本地 | `/etc/systemd/system/<SSL_UNIT_NAME>.{service,timer}`、证书、`renew.log` | ⛔ 不用管 |

```bash
# ① 先停 timer（一次签发可能跑几十秒，更新时正好被触发会很麻烦）
sudo systemctl stop <SSL_UNIT_NAME>.timer

# ② 传到临时名再原子替换（别 scp 原地覆盖，会 Text file busy）
scp lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh README.md \
    root@<IP>:/opt/ssl/
for f in lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh README.md; do
  cat "/opt/ssl/$f" > "/opt/ssl/$f.__new" && mv -f "/opt/ssl/$f.__new" "/opt/ssl/$f"
done

# ③ 修行尾 + 补执行位 + 语法检查（每次都要，别省）
cd /opt/ssl
sed -i 's/\r$//' *.sh
chmod +x ssl-*.sh
bash -n *.sh renewpost.sh.example && echo '语法 OK'

# ④ 确认配置还在
ls -l secrets.env domains.conf ssl.conf renewpost.sh

# ⑤ 起 timer + 验收
sudo systemctl start <SSL_UNIT_NAME>.timer
./ssl-status.sh
```

> **`Text file busy`（ETXTBSY）不是内容问题**：`execve` 的 `deny_write_access()`
> 在解析 shebang **之前**执行，所以报错里的 `/usr/bin/env` 只是照 shebang 打出的名字。
> 首选解法换 inode：`cat f > f.__new && mv -f f.__new f`。救急用 `bash <脚本>` 绕开 exec。

---

## 十、详细文档

**[`scripts/README.md`](scripts/README.md)** —— 1100+ 行，十五节：

| 节 | 内容 |
|---|---|
| 〇 | 一套代码、两种消费方 |
| 一 | 为什么拆成四个文件（别合并的理由） |
| 二 | 目录结构 |
| 三 | 前置条件 |
| 四 | 快速开始（逐步命令） |
| 五 | DNS 服务商：腾讯云 / GoDaddy（端点、凭据变量、限流差异） |
| 六 | 域名分散在多个服务商 / 多个账号下 |
| 七 | 每张证书的到期时间是怎么自动管理的 |
| 八 | 自动续期（systemd timer 的全部细节） |
| 九 | 证书更新后做什么 + 运行日志 + 三种模式原理 |
| 十 | 常用命令 |
| 十一 | 消费方怎么引用证书（Traefik / nginx 配置片段） |
| 十二 | **Windows 开发 → Linux 部署的行尾陷阱** |
| 十三 | 排障速查表 |
| 十四 | 安全说明 |
| 十五 | 升级脚本 + `Text file busy` 的完整成因与处理 |

---

## 十一、支持范围

| 项 | 支持 |
|---|---|
| DNS 服务商 | 腾讯云 DNSPod、GoDaddy（**同一份列表里可以混用**） |
| 每个服务商的账号数 | 不限（靠变量名后缀区分，如 `Tencent_SecretId_ACC2`） |
| 泛域名 | ✓（`*.example.com`，通常与裸域名写在同一行） |
| 证书算法 | `ec-256`（默认）/ `ec-384` / `2048` |
| 消费方 | Traefik（file provider 热加载）、nginx、任意 docker compose 服务 |
| 系统 | CentOS / Rocky / Alma / Ubuntu / Debian（只用系统自带二进制，不装包） |
| 续期调度 | systemd timer（每天检查，按每张证书自己的阈值决定） |

**已知限制**：一张证书（`domains.conf` 一行）里的所有域名必须同属「同一个 DNS 服务商 + 同一个账号」——
DNS-01 一次调用写完整行 TXT，acme.sh 一次只能用一套凭据。跨服务商/跨账号必须拆行。
