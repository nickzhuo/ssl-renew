# scripts/ssl-nginx —— 只放「nginx 这台机器自己的配置」

**这里没有代码。** 全部代码只有一份，在 [`../ssl/`](../ssl/README.md)。

```
scripts/
├── ssl/            ← ★ 唯一的代码 + 唯一的 README（所有文档看这里）
│   ├── README.md
│   ├── lib.sh  ssl-issue.sh  ssl-status.sh  ssl-setup.sh  ssl-repair.sh
│   ├── ssl.conf  secrets.env.example  domains.conf
│   └── renewpost.sh.example.nginx / .example.docker
└── ssl-nginx/      ← 本目录：nginx 机器的 ssl.conf
    ├── ssl.conf    ★ 本机配置（SSL_OUTPUT_DIR=/etc/nginx/ssl，SSL_UNIT_NAME=ssl-nginx-renew）
    └── README.md
```

## 为什么要这样拆

以前 `scripts/ssl/`（Traefik 版）和 `scripts/ssl-nginx/`（nginx 版）是**两份代码**，
99% 相同、只有三处不同（输出目录 / unit 名 / 后置钩子）。两份并排维护的代价是：
每次改逻辑都要改两遍，而且**复制目录时一定会漏改某处** ——
真漏过一次：`ssl-status.sh` 里写死的 unit 名没跟着改，状态检查一直去查另一套的 unit，
报「未安装」，白误导了一轮排查。

现在收敛成"**一套代码 + 每台机器一份配置**"：

| 差异项 | Traefik 机器 | nginx 机器 | 写在哪 |
|---|---|---|---|
| 证书输出目录 | `/root/cert` | `/etc/nginx/ssl` | `ssl.conf` → `SSL_OUTPUT_DIR` |
| systemd unit 名 | `ssl-renew` | `ssl-nginx-renew` | `ssl.conf` → `SSL_UNIT_NAME` |
| 续期后置动作 | `renewpost.sh.example.docker` | `renewpost.sh.example.nginx` | 复制成 `renewpost.sh` |

## 服务器上怎么用

服务器上这个目录（`/opt/ssl-nginx/` 之类）里，**放一份 `../ssl/` 的脚本副本 + 本目录的配置**：

```bash
# 升级：只覆盖脚本，配置一律不动
cd /opt/ssl-nginx
# ① 先停 timer
sudo systemctl stop ssl-nginx-renew.timer
# ② 从仓库 scripts/ssl/ 逐文件传过来（或直接把本节目录里的脚本覆盖过去）
# ③ 修行尾 + 补执行位 + 语法检查
sed -i 's/\r$//' *.sh
chmod +x ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh
bash -n lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh && echo '语法 OK'
# ④ 确认配置还在
ls -l secrets.env domains.conf ssl.conf renewpost.sh
# ⑤ 起 timer + 验收
sudo systemctl start ssl-nginx-renew.timer
./ssl-status.sh
```

> **脚本目录叫什么名字不影响功能。** 判断"这台机器该装哪个 unit"的唯一依据是
> `ssl.conf` 里的 `SSL_UNIT_NAME`，不是目录名 —— 所以本目录叫 `ssl-nginx` 完全没问题。

## 完整文档

安装、多服务商（腾讯云 / GoDaddy）、多账号、定时器、排障、
`Text file busy` 的成因与处理 —— **全部在 [`../ssl/README.md`](../ssl/README.md)**。
