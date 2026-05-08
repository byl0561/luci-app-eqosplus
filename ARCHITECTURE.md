# eqosplus 架构与数据流（含本会话改动）

本文档把 eqosplus 的整体链路画出来，标注：

- `══`（双线）：**原有链路**（本会话之前就有的）
- `──`（单线）：**本会话新增的链路**
- `★`：本会话新增/修改的组件或字段

最后一节是「代码-图对应表」，逐条边列出对应的源码位置，便于 review。

---

## 图例

```
[组件]            ─单线─→ 流向（本会话新增）
{文件/状态}       ═双线═→ 流向（本会话之前已有）
((触发源))        ⇢虚线⇢ 异步背景作业
★前缀             本次会话新增/改造
```

---

## 1. 整体组件架构

```
                                    ┌──────────────────────────┐
                                    │         User             │
                                    │  (LuCI / shell / opkg)   │
                                    └──────────────────────────┘
                                                │
                ┌───────────────────────────────┼─────────────────────────────────────┐
                │                               │                                     │
                ▼                               ▼                                     ▼
   ┌──────────────────────────┐     ┌──────────────────────┐         ┌──────────────────────────┐
   │   LuCI Web UI            │     │  /etc/init.d/        │         │   uci-defaults/          │
   │   (cbi/eqosplus.lua,     │     │  eqosplus            │         │   luci-eqosplus  ★       │
   │    view/index.htm,       │     │  (procd service)     │         │   (postinst trigger)     │
   │    controller/eqosplus)  │     └──────────────────────┘         └──────────────────────────┘
   └──────────────────────────┘                │                                     │
            │                                  │ start/stop/reload                   │ 安装/升级时跑一次：
            │ Save & Apply                     │                                     │  - detect nft / iptables
            │ ★ ip.write 仅清理 legacy mac 字段  │                                     │  - ★ uci set backend=nft|iptables
            │ ★ ip.validate: MAC + conn != 0 报错│                                     │
            │ ★ ip.cfgvalue 解码                │                                     │  - ★ if iptables: 注册 fw3 include
            │ ★ validate(conn_in/out 不全 0)    │                                     │  - migrate conn_limit→conn_out  ★
            ▼                                  │                                     │
   ╔════════════════════════════════════════╗  │                                     │
   ║ /etc/config/eqosplus  ★target ★conn_in  ║◄─┘                                     │
   ║                       ★conn_out         ║◄────────────────────────────────────────┘
   ║                       ★tcp_only         ║
   ║                       ★backend          ║
   ╚════════════════════════════════════════╝
            ║                                  ┌─────────────────────────────────────┐
            ║                                  │   /etc/config/firewall              │
            ║ uci show 缓存                    │   (含 ★fw3-include 注册)             │
            ║                                  └─────────────────────────────────────┘
            ▼                                              │
   ╔════════════════════════════════════════════════════╗  │
   ║         /usr/bin/eqosplus  (CLI dispatcher)        ║  │
   ║                                                    ║  │
   ║   case "$1" in                                     ║  │
   ║     "start") teardown+init conn ★, init_qosplus    ║  │
   ║     "stop")  stop_qos, ★teardown_conn_table        ║  │
   ║     "add")   _add_rule per id                      ║  │
   ║     "del")   del_id per id                         ║  │
   ║     "resync") sync_networks + readd                ║  │
   ║     "conn_reload") ★reapply conn-only rules        ║  │
   ║     "status"|"log") query ops (no lock)            ║  │
   ║   esac                                             ║  │
   ║                                                    ║  │
   ║   ★ Backend 解析: UCI → self-heal → 运行时回退      ║  │
   ║   flock /tmp/eqosplus.op.lock (mutating ops only)  ║  │
   ╚════════════════════════════════════════════════════╝  │
            ║                          ║                   │
            ║ sources                  ║ writes/reads      │
            ║                          ║                   │
            ▼                          ▼                   │
   ╔════════════════════╗      ╔══════════════════════╗   │
   ║ /usr/lib/eqosplus/ ║      ║ State files          ║   │
   ║   core.sh          ║      ║   /var/eqosplus.     ║   │
   ║   sched.sh         ║      ║     idlist           ║   │
   ║   idlist_helpers   ║      ║     networks         ║   │
   ║   uci_helpers      ║      ║     generation       ║   │
   ║   timeout_exec     ║      ║     sched_cache      ║   │
   ╚════════════════════╝      ╚══════════════════════╝   │
            ║                                              │
            ║ effects                                      │
            ▼                                              │
   ╔══════════════════════════════════════════════════════════════════════════╗
   ║                         Kernel state                                      ║
   ║                                                                           ║
   ║   ╔═════════════════════════════════╗   ┌─────────────────────────────┐  ║
   ║   ║ tc qdiscs / classes / filters   ║   │ ★ nft inet eqosplus         │  ║
   ║   ║   - br-lan + br-lan_ifb (HTB)   ║   │   chain forward {           │  ║
   ║   ║   - flower mac/ip filters       ║   │     priority -10            │  ║
   ║   ║   - mirred ingress redirect     ║   │   }                         │  ║
   ║   ╚═════════════════════════════════╝   │   set bypass4_<network>     │  ║
   ║                                          │   set bypass6_<network>     │  ║
   ║                                          └─────────────────────────────┘  ║
   ║                                                ──or──                     ║
   ║                                          ┌─────────────────────────────┐  ║
   ║                                          │ ★ iptables eqos_forward     │  ║
   ║                                          │   chain (filter table)      │  ║
   ║                                          │ ★ FORWARD -j eqos_forward   │  ║
   ║                                          │ ★ ipset eqos_bypass4_<net>  │  ║
   ║                                          │ ★ ipset eqos_bypass6_<net>  │  ║
   ║                                          └─────────────────────────────┘  ║
   ║                                                                           ║
   ║   ╔═════════════════════════════════════╗  ┌──────────────────────────┐   ║
   ║   ║ conntrack table                     ║  │ ★ Used by ct count over  │   ║
   ║   ║                                     ║◄─│    / xt_connlimit        │   ║
   ║   ╚═════════════════════════════════════╝  └──────────────────────────┘   ║
   ╚══════════════════════════════════════════════════════════════════════════╝
            ▲                                              ▲
            ║                                              │
   ╔════════════════════════════════╗            ┌─────────────────────────────┐
   ║ /usr/bin/eqosplusctrl          ║            │ ★ /usr/lib/eqosplus/        │
   ║ (procd-managed daemon)         ║            │     fw3-include.sh          │
   ║                                ║            │   (registered in            │
   ║ 30s loop:                      ║            │    /etc/config/firewall)    │
   ║   ★ sanity probe (chain+jump)  ║            │                             │
   ║   ★ if missing → conn_reload   ║            │   triggered on fw3 reload   │
   ║   rebuild_cache if mtime drift ║            │   → backgrounds eqosplus    │
   ║   check_item per cached rule   ║            │     conn_reload  ★          │
   ║   batch eqosplus add/del       ║            └─────────────────────────────┘
   ╚════════════════════════════════╝
            ▲                                              ▲
            │ procd respawn                                │ fw3 reload include
            │                                              │
            └─── /etc/init.d/eqosplus start_instance       └─── /etc/init.d/firewall reload
                                                               (only fires for iptables backend)

   ╔════════════════════════════════════════╗
   ║ /etc/hotplug.d/iface/10-eqosplus       ║
   ║ (fires on ifup/ifdown of LAN ifaces)   ║
   ║                                        ║
   ║ → eqosplus resync $INTERFACE            ║
   ╚════════════════════════════════════════╝
```

**关键观察**：

1. **三条独立的"激活路径"汇聚到 eqosplus CLI**：daemon poll、hotplug 事件、用户/init 触发。所有都通过同一个 `flock` 序列化。
2. **两条"恢复路径"针对防火墙故障**（本会话新增）：
   - fw3 路径：fw3-include.sh 由 fw3 reload 钩子立即触发（OpenWrt 仍保留 fw3 hotplug 机制）
   - fw4 路径：**无钩子可用**（fw4 显式移除了 hotplug.d/firewall 事件），只能靠 daemon 30s 周期 probe 兜底
3. **Backend 解析有三层防御**：UCI 写死 → 工具丢失自愈 → 运行时探测。

---

## 2. 用户保存配置 → 内核生效（MAC 不支持限连接数）

```
User
  │  填表：target=AA:BB:CC:DD:EE:FF, conn_in=1000, conn_out=200
  │  点 Save & Apply
  ▼
LuCI CBI
  │
  │  ★ ip.validate(value, section)
  │     ├─ 若 conn_in > 0 且 value 是 MAC：
  │     │    ★ 查 mac_to_ipv4[normalize_mac(value)]
  │     │       → 命中：通过
  │     │       → 缺失：return nil, "需要在线的 IPv4..."  → 报错回显
  │     └─ 否则通过
  │
  │  ★ validate_capacity(...)  → download/upload/conn_in/conn_out 不能全 0
  │
  │  ★ ip.write(self, section, value)
  │     ├─ 若 conn_in > 0 且 is_mac(value)：
  │     │    value = "AA:BB:CC:DD:EE:FF#192.168.1.100"
  │     │  ★ self.map:del(section, "mac")  ← 清掉旧字段
  │     └─ Value.write(self, section, value) → 写 target
  │
  ▼
UCI commit                                      ★on_after_commit:
/etc/config/eqosplus 写入：                       清理 enabled_zones 之外的孤儿规则
  option target  'AA:BB:...:FF#192.168.1.100'   uci_cursor:foreach + uci:delete
  option conn_in '1000'
  option conn_out '200'
  option tcp_only '1'
  ...

  │
  │  procd_add_reload_trigger 'eqosplus'
  ▼
/etc/init.d/eqosplus reload  → stop + start

  │
  ▼
eqosplus stop
  ├─ stop_qos                (tc 清理: 现有)
  └─ ★ eqos_teardown_conn_table  (整表 teardown，仅服务级)

eqosplus start
  ├─ cleanup_orphaned_rules
  ├─ ★ eqos_teardown_conn_table  (再次确保起点干净)
  ├─ ★ eqos_init_conn_table      (创建 inet eqosplus / eqos_forward)
  └─ init_qosplus → sync_networks → start_network(每个 enabled 网络)
       │
       │ start_network 内部：
       ├─ eqos_init_dev               (现有：HTB+IFB+ingress)
       ├─ ★ eqos_init_conn_network    (新增：bypass set + iifname-scoped 跳过规则)
       ├─ 收集同区域 v4/v6 子网（现有 ip -o addr show + awk）
       ├─ eqos_add_bypass × N         (现有：tc bypass)
       └─ ★ eqos_update_bypass_set    (新增：把同区域子网灌入 nft set / ipset)

  ▼
procd 重启 daemon (eqosplusctrl)
  │
  │ daemon 第一次 idlistusr:
  ├─ ★ sanity probe → 通过（start 已经建好）
  ├─ rebuild_cache from UCI
  └─ for each cached rule: check_item → batch eqosplus add <ids>
       │
       ▼
eqosplus add <id1>,<id2>,...
  for each id:
    _add_rule(id)
      │
      │  ★ device=$(_get_uci_target ...)        ← target 优先, mac fallback
      │  ★ device_bare="${device%%#*}"          ← 剥 #IP 后缀（任意 shape）
      │  is_macaddr "$device_bare" ?
      │    yes → add_mac
      │    no  → add_ip
      ▼
   add_mac(id):
     ★ _get_uci_rule_fields  → "addr|dl|ul|ci|co|tcp_only"
     ★ 防御性 strip "#..." 后缀（兼容老版本可能的 "MAC#ipv4" 残留）
     ┌─ if dl>0 || ul>0:
     │    eqos_add_mac(dev, uuid, mac, dl, ul)              (现有 tc 调用)
     │  else:
     │    eqos_del_id(dev, uuid)                            (idempotent)
     ├─ ★ eqos_del_conn(rule_id)         ← 清掉可能存在的旧规则（含老版 MAC 装的）
     └─ ★ MAC 不支持限连接数：UI 已禁用 conn_in/out，CBI validate 兜底拦截。
            如果 ci/co > 0 仍漏到这里（直接改 UCI 等），仅记 warning，不装规则。
                                                                          │
                                                                          ▼
                                                              eqos_add_conn 内部：
                                                                ★ 按 EQOS_BACKEND 分发
                                                                ★ comment = "eqos:rule:<rule_id>"
                                                                  e.g. "eqos:rule:lan[0]"
                                                                  - nft 路径: ip/ip6/ether saddr | daddr
                                                                              + meta l4proto tcp (若 tcp_only)
                                                                              + ct count over N reject
                                                                  - iptables 路径: -s/-d + -p tcp + -m connlimit
                                                                              --connlimit-above N
                                                                              --connlimit-mask <CIDR-prefix>
                                                                              --connlimit-saddr 或 --connlimit-daddr
                                                                              -j REJECT
```

---

## 3. Schedule 激活/停用流（daemon 30s 循环）

```
                  ((30s 定时器))
                       │
                       ▼
            eqosplusctrl idlistusr()
                       │
                       │  [ -s /var/eqosplus.networks ] || return
                       │
                       ▼
               ★ Sanity probe (本会话新增)
               ┌──────────────────────────────┐
               │ if cmd -v nft:               │
               │   nft list table inet eqosplus│
               │ elif cmd -v iptables:        │
               │   iptables -nL eqos_forward  │
               │   iptables -C FORWARD -j ... │   ← 同时检 chain + jump
               │   ip6tables -C FORWARD -j ...│
               └──────┬───────────────────────┘
                      │
            state intact?
              yes ─→ 继续                       no ─→ logger; eqosplus conn_reload (异步)
                      │                                       │
                      ▼                                       │
            mtime check → rebuild_cache?                      │
              changed: rebuild from `uci show $NAME`          │
              same: skip                                      │
                      │                                       │
                      ▼                                       │
            读 GENERATION (gen_before)                        │
                      │                                       │
                      ▼                                       │
            扫 IDLIST 形成 idlist_pat="|id1|id2|..."           │
                      │                                       │
                      ▼                                       │
            遍历 CACHE 行: id|timestart|timeend|week           │
              check_item(id, ts, te, wk, h, m, w)             │
                ├─ active && id ∉ idlist  → adds += id        │
                └─ inactive && id ∈ idlist → dels += id        │
                      │                                       │
                      ▼                                       │
            读 GENERATION (gen_after)                         │
              gen_before != gen_after ─→ 丢弃本轮             │
                      │                                       │
                      ▼                                       │
            Apply (timeout 30s):                              │
              eqosplus del $dels  → del_id 逐个               │
              eqosplus add $adds  → _add_rule 逐个             │
                                       │                      │
                                       ▼                      ▼
                            已经汇聚到第 2 节的         conn_reload 重建：
                            "用户保存"流程的           init_conn_table
                            add_mac/add_ip 路径        + 每个 NETWORKS 项 reapply_conn_for_network
                                                       + reapply_conn_for_active_rules
```

**关键不变量**：

- daemon **不直接**写 nft/iptables，全部通过 `eqosplus` CLI（持锁）
- `eqosplus add/del` 之间通过 `bump_generation` 防止 daemon 用旧快照下决策
- Sanity probe 失败时触发 `conn_reload`，本身也走 `eqosplus` CLI（持锁）。两条路径不会并发改内核。

---

## 4. fw3 reload 恢复流（iptables 后端，原有钩子）

```
User: /etc/init.d/firewall reload

  │
  ▼
fw3 重建 FORWARD 链 (rule 清空 + 重新生成)
  │
  ├─ 自定义链 eqos_forward 的内容仍在（fw3 不知道）
  └─ FORWARD → eqos_forward 的跳转 没了 ★（fw3 重建 FORWARD 时连带删除）
  │
  ▼
fw3 跑所有 includes（option reload='1' 让我们也跑）
  │
  ▼
/usr/lib/eqosplus/fw3-include.sh
  │
  ├─ 检查 backend == iptables（nft 后端无需此 hook）
  ├─ 检查 service_enable == 1
  ├─ 检查 /var/eqosplus.networks 非空
  │
  ▼
  ( eqosplus conn_reload ) &       ← 异步背景执行，避免阻塞 fw3 reload
  │
  ▼
eqosplus conn_reload (持 flock)
  │
  ├─ ★ eqos_init_conn_table         (idempotent；重新插 -j eqos_forward 跳转)
  ├─ for each net in NETWORKS:
  │     ★ _reapply_conn_for_network(net)
  │        └─ eqos_init_conn_network + 重采子网 + eqos_update_bypass_set
  └─ ★ _reapply_conn_for_active_rules
        └─ 遍历 IDLIST 每条:
             MAC 标识符：sweep 任何残留 conn 规则（不再装新规则）
             IP/CIDR 标识符：eqos_del_conn + eqos_add_conn(out, in)
```

---

## 5. fw4 stop+start 恢复流（nft 后端，无钩子，daemon 兜底）

```
User: /etc/init.d/firewall stop
  │
  ▼
fw4 (ucode) 执行 `nft flush ruleset`
  │
  └─ ★ 整个 nft 规则集被清空，包括我们的 inet eqosplus
     （OpenWrt issue #11620；fw4 没有像 fw3 那种 hotplug 事件）

User: /etc/init.d/firewall start
  │
  ▼
fw4 重新构建 fw4 自己的表 + nftables.d 静态 include
  │
  └─ ★ 我们的 inet eqosplus 表 不会自动重建
     （我们没用 nftables.d 静态骨架，详见决策说明）

  ⇢⇢⇢⇢⇢ 此时 conn_limit 静默失效，但 daemon 还活着 ⇢⇢⇢⇢⇢

  ⇢ 30 秒之内 ⇢

eqosplusctrl idlistusr (next poll)
  │
  ▼
★ Sanity probe:
    nft list table inet eqosplus  → 失败（表没了）
  │
  ▼
logger -t eqosplusctrl "conn state missing, triggering conn_reload"
  │
  ▼
$EQOS_TIMEOUT 30 eqosplus conn_reload
  │
  ▼
eqosplus conn_reload (持 flock；与第 4 节同一逻辑)
  │
  ├─ eqos_init_conn_table         → 重建 inet eqosplus 表 + chain
  ├─ _reapply_conn_for_network(每个 network)
  │     → 重建 bypass set + 重新填充
  └─ _reapply_conn_for_active_rules
        → 按 IDLIST 重建 per-rule conn 规则
```

**最长恢复窗口：30 秒**。这是在没有 fw4 钩子的现实下，daemon 驱动恢复能做到的最优。

---

## 6. 接口热插拔流（原有，未改）

```
((ifup INTERFACE))                    ((ifdown INTERFACE))
       │                                      │
       ▼                                      ▼
/etc/hotplug.d/iface/10-eqosplus
  │
  ├─ pgrep eqosplusctrl ?  否则 exit 0
  ├─ INTERFACE 在 /var/eqosplus.networks ?  否则 exit 0
  │
  ├─ ifup:    ( sleep 3; eqosplus resync "$INTERFACE" ) &
  └─ ifdown:  ( eqosplus resync "$INTERFACE" ) &
                            │
                            ▼
              eqosplus resync <network>
                ├─ 从 NETWORKS / IDLIST 摘除该网络
                ├─ sync_networks（停止旧、启动新）
                └─ _readd_network_rules（重放该网络的 active 规则）
                       │
                       │ 走第 2 节的 add_mac/add_ip 路径
                       │ 自动连带把 conn 规则也重建（★ add_mac 内部新增了 conn 调用）
                       ▼
                    Kernel state 更新
```

**与本会话改动的关系**：未改 hotplug 脚本本身，但 `_readd_network_rules → _add_rule → add_mac/add_ip` 的下游已经新增了 conn 规则的安装。所以接口闪断后自动恢复 tc + conn 两套规则。

---

## 7. 测试拓扑（结构 + 单/双臂 traffic）

```
─── eqosplus_test (结构测试) ───────────────────────────────────

[host kernel]
  ├─ 创建假 dummy 设备 eqos_test0
  └─ 在 inet eqosplus 表里 创建测试网络  ★ eqotest_a, eqotest_b
       └─ 测试规则 comment: "eqos:rule:eqotest_a[0]" 等
       └─ ★ cleanup 只 teardown_conn_network "eqotest_a/b"
            而不是 teardown_conn_table —— 生产规则共表保留

─── eqosplus_traffic_test (流量测试) ─────────────────────────────

第一段：原 tc 限速测试
  ┌─ ns(eqos_test_ns) ── veth ── host(eqos_vhost) ──┐
  │      CLIENT_IP ──────────────────  HOST_IP      │
  │                                                  │
  │  注：流量从 ns 到 host_IP，走 INPUT 链            │
  │      conn_limit 在 FORWARD，看不到 ★             │
  └──────────────────────────────────────────────────┘

第二段：双臂转发 conn_limit 测试  ★ 本会话新增
  ┌─ ns_a(eqfwd_a) ── veth_eqfwd_vha ─┐
  │  10.66.66.2                       │
  │                                   ├─ host (ip_forward=1)
  │  ns_b(eqfwd_b) ── veth_eqfwd_vhb ─┤  10.66.66.1 + 10.66.77.1
  │  10.66.77.2                       │
  └────────── ns_a → host → ns_b ─────┘
              FORWARD: iifname=eqfwd_vha, oifname=eqfwd_vhb

  在 forward chain 临时穿透 fw4/fw3 主防火墙：
    nft -a -e insert rule inet fw4 forward iifname X oifname Y accept  (handle 抓回)
    iptables -I FORWARD -i X -o Y -j ACCEPT
  cleanup: 按 handle / 反向 -D 精确移除

  conn_limit 测试网络名: ★ eqotest_fwd
  cleanup: ★ eqos_teardown_conn_network "eqotest_fwd" (不动生产)

第三段：单臂 hairpin conn_limit 测试  ★ 本会话新增
  ┌─ ns_a(eqsa_a) ── veth_eqsa_vha ─┐
  │  10.66.88.2                     │
  │                                 ├─ br_eqsa (10.66.88.1 + 10.66.77.1)
  │  ns_b(eqsa_b) ── veth_eqsa_vhb ─┤  iifname == oifname == br_eqsa
  │  10.66.99.2                     │
  └─── ns_a → br_eqsa → ns_b ──────┘
       FORWARD: iifname=oifname=br_eqsa  (hairpin)

  conn_limit 测试网络名: ★ eqotest_sa
  cleanup: ★ eqos_teardown_conn_network "eqotest_sa" (不动生产)

  trap: cleanup; cleanup_fwd; cleanup_sa  (三段链式幂等清理)
        - ip_forward 还原
        - 主防火墙临时钉子按 handle/match 删除
        - 所有 ns/veth/bridge 删除
        - 仅清测试 network 的 conn 状态
```

**测试隔离的关键设计**（本会话）：

1. 所有测试网络名以 `eqotest_` 前缀，不与真实 OpenWrt 网络名冲突
2. cleanup 只用 `eqos_teardown_conn_network "<test_net>"`（按 comment 前缀扫除）
3. **绝不调用 `eqos_teardown_conn_table`**——那会清掉用户生产环境的所有 conn_limit 规则

---

## 8. 内核层数据结构（本会话新增标注）

### nft 后端

```
table inet eqosplus {                                ★ 新建表
    set bypass4_<network>  { type ipv4_addr; flags interval; }   ★
    set bypass6_<network>  { type ipv6_addr; flags interval; }   ★
    chain forward {                                  ★ priority -10, hook filter forward
        # 同区域 bypass（每网络一对）                ★
        iifname "<dev>" ip  daddr @bypass4_<network> return  comment "eqos:bypass:<network>:"
        iifname "<dev>" ip6 daddr @bypass6_<network> return  comment "eqos:bypass:<network>:"
        # 每条规则的 connlimit（按方向 0/1/2 条）    ★
        ip saddr <addr>  meta l4proto tcp  ct count over N  reject  comment "eqos:rule:<network>[<idx>]"
        ip daddr <addr>  meta l4proto tcp  ct count over N  reject  comment "eqos:rule:<network>[<idx>]"
        ...
    }
}
```

### iptables 后端

```
chain eqos_forward (filter table)                    ★ 新建链
  ↑ -j 自 FORWARD 链                                  ★

  per-network bypass:
    -i <dev> -m set --match-set eqos_bypass4_<network> dst -j RETURN  ★
            -m comment --comment "eqos:bypass:<network>:"
    (ip6tables 同样)

  per-rule connlimit:
    -s <addr> -p tcp -m connlimit --connlimit-above N
              --connlimit-mask <prefix>                ★ (来自 CIDR 的前缀长度)
              --connlimit-saddr 或 --connlimit-daddr   ★ (按方向)
              -m comment --comment "eqos:rule:<network>[<idx>]"
              -j REJECT
```

**Comment 命名空间设计**（本会话）：

| 类别 | 格式 | 锚定方式 | 示例 |
|------|------|---------|------|
| 同区域 bypass | `eqos:bypass:<network>:` | 末尾冒号 | `eqos:bypass:lan:` |
| Per-rule | `eqos:rule:<network>[<idx>]` | `[` 是网络名后的天然分隔 | `eqos:rule:lan[0]` |

**精确 vs 前缀匹配**：

- 删单条：搜索 `eqos:rule:lan[0]`（nft 输出 `"..."` 闭合引号 / iptables 输出 `/* ... */` 闭合 `*/`）
- 按网络扫除：搜索 `eqos:rule:lan[`（前缀；`[` 阻止 `lan2[` 误命中）

---

## 9. 代码-图对应表（review 用）

下表把图里每条**新增**边/组件对应到具体源码位置，便于核对图与实现是否一致。

下面所有行号都用 `grep -n` 实测得到，准确反映本会话改动后的代码位置（路径相对 `luci-app-eqosplus/` 包目录）：

| 图中元素 | 文件:行 | 关键标识 |
|---------|--------|---------|
| `★ is_mac_string helper` | `luasrc/model/cbi/eqosplus.lua:51` | `local function is_mac_string(v)` |
| `★ ip.cfgvalue` (仅 strip legacy `#` 后缀) | `luasrc/model/cbi/eqosplus.lua:162` | `ip.cfgvalue = function(self, section)` |
| `★ ip.validate 拒绝 MAC + 非零 conn` | `luasrc/model/cbi/eqosplus.lua:175` | `if is_mac_string(value) ... n("conn_in") > 0 or n("conn_out") > 0` |
| `★ ip.write 仅清理 legacy mac 字段` | `luasrc/model/cbi/eqosplus.lua:188` | 不再做编码；只 `self.map:del(section, "mac")` 后 `Value.write(...)` |
| `★ validate_capacity (4 字段)` | `luasrc/model/cbi/eqosplus.lua:259` | `local function validate_capacity` (download/upload/conn_in/conn_out 不能全 0) |
| `★ index.htm 禁用 conn 输入` | `luasrc/view/eqosplus/index.htm:433` 起 IIFE | 检测 target 选了 MAC → conn_in/out **`readOnly` + 值置 0**（不能用 `disabled`，否则字段不会随表单提交，UCI 留旧值）|
| `★ daemon probe v4+v6 双链` | `root/usr/bin/eqosplusctrl:73-83` | iptables 后端 4 项探测：v4 chain、v6 chain、v4 jump、v6 jump，任一缺失即触发 conn_reload |
| `★ nft init 失败 stderr 日志` | `root/usr/lib/eqosplus/core.sh:241-258` | `nft -f -` 返回非 0 时写 stderr，避免 kmod-nft-core 缺失时整个功能静默挂掉 |
| `★ _reapply 空 addr 防御` | `root/usr/bin/eqosplus:746` | UCI section 在 IDLIST 写入和 conn_reload 之间被删 → addr 空 → 跳过并 sweep 该 rule_id |
| `★ validate_capacity (4 字段)` | `luasrc/model/cbi/eqosplus.lua:273` | `local function validate_capacity` |
| `★ mac_to_ipv4 lookup 构建` | `luasrc/model/cbi/eqosplus.lua:27` 起 | `local mac_to_ipv4 = {}` |
| `on_after_commit` (原有) | `luasrc/model/cbi/eqosplus.lua` 文件末尾 | `function a.on_after_commit` |
| UCI `★target/conn_in/conn_out/tcp_only/backend` | `/etc/config/eqosplus` 运行时 | 字段名 |
| `★ uci-defaults backend 探测` | `root/etc/uci-defaults/luci-eqosplus:20-21` | `if command -v nft` / `command -v iptables` |
| `★ uci-defaults fw3-include 注册` | `root/etc/uci-defaults/luci-eqosplus:49-55` | `option path` / `option type 'script'` / `option reload '1'` |
| `★ uci-defaults conn_limit→conn_out 迁移` | `root/etc/uci-defaults/luci-eqosplus` 内的 for 循环 | `grep "\.conn_limit="` |
| `★ Backend 解析 + 自愈 (主脚本入口)` | `root/usr/bin/eqosplus:20` 起 | `case "$EQOS_BACKEND" in` |
| `★ _get_uci_target (双读 helper)` | `root/usr/bin/eqosplus:149` | `_get_uci_target() {` |
| `★ _get_uci_rule_fields awk 双取` | `root/usr/bin/eqosplus:163` | `_get_uci_rule_fields() {` |
| `★ start_network: init_conn_network` | `root/usr/bin/eqosplus:295` | `eqos_init_conn_network "$network" "$dev"` |
| `★ start_network: update_bypass_set` | `root/usr/bin/eqosplus:347` | `eqos_update_bypass_set "$network" "$_conn_bypass_v4" "$_conn_bypass_v6"` |
| `★ stop_network: teardown_conn_network` | `root/usr/bin/eqosplus:405` | `eqos_teardown_conn_network "$network"` |
| `★ del_id: conn 调用` | `root/usr/bin/eqosplus:533` | `eqos_del_conn "$1"` |
| `★ add_mac: 仅 sweep，不装 conn` | `root/usr/bin/eqosplus:594` | `eqos_del_conn "$1"`（MAC 不支持限连接数；CI/CO>0 仅记 warning）|
| `★ add_ip: conn 调用 (del + out + in)` | `root/usr/bin/eqosplus:648-654` | `eqos_del_conn` + `eqos_add_conn ... out` + `eqos_add_conn ... in` |
| `★ _add_rule: device_bare 解码` | `root/usr/bin/eqosplus:675` | `case "$device" in *#*) device_bare="${device%%#*}"` |
| `★ _reapply_conn_for_network` | `root/usr/bin/eqosplus:686` 起 | `_reapply_conn_for_network() {` |
| `★ _reapply_conn_for_active_rules` | `root/usr/bin/eqosplus:726` 起 | `_reapply_conn_for_active_rules() {` （含空 addr 防御）|
| `★ stop case: teardown_conn_table` | `root/usr/bin/eqosplus:816` | `eqos_teardown_conn_table` |
| `★ start case: teardown+init conn` | `root/usr/bin/eqosplus:834-835` | 两连调 |
| `★ conn_reload case` | `root/usr/bin/eqosplus:861` 起 | `"conn_reload")` |
| `★ daemon sanity probe (整段)` | `root/usr/bin/eqosplusctrl:52-91` | 从 `idlistusr() {` 到 sanity if 块结束 |
| `★ daemon: probe 触发 conn_reload` | `root/usr/bin/eqosplusctrl:88` | `$EQOS_TIMEOUT 30 eqosplus conn_reload` |
| `★ daemon: v4+v6 双探测` | `root/usr/bin/eqosplusctrl:80-83` | `iptables -nL eqos_forward` + `ip6tables -nL eqos_forward` + 双 `-C FORWARD -j` |
| `★ fw3-include.sh` | `root/usr/lib/eqosplus/fw3-include.sh` | 整个文件 |
| `★ core.sh nft path 起点` | `root/usr/lib/eqosplus/core.sh:249` 起 | `# ---- nft backend ----` |
| `★ core.sh iptables path 起点` | `root/usr/lib/eqosplus/core.sh:415` 起 | `# ---- iptables backend ----` |
| `★ core.sh Backend dispatch` | `root/usr/lib/eqosplus/core.sh:602` 起 | `# ---- Backend dispatch ----` |
| `★ core.sh nft init 失败日志` | `root/usr/lib/eqosplus/core.sh:241-258` | `nft -f -` 返回非 0 时 stderr 报错，避免缺 kmod-nft-core 时静默挂掉 |
| `★ core.sh CIDR → connlimit-mask` | `root/usr/lib/eqosplus/core.sh:531-546` | `prefix="${addr##*/}"`、`--connlimit-mask "$prefix"` |
| `★ nft delete by comment (anchored)` | `root/usr/lib/eqosplus/core.sh:386` | `_eqos_nft_delete_by_comment() {` |
| `★ nft purge by prefix` | `root/usr/lib/eqosplus/core.sh:402` | `_eqos_nft_purge_by_prefix() {` |
| `★ iptables delete by comment` (`/* */` anchored) | `root/usr/lib/eqosplus/core.sh:569` | `_eqos_ipt_delete_by_comment() {` |
| `★ iptables purge by prefix` | `root/usr/lib/eqosplus/core.sh:587` | `_eqos_ipt_purge_by_prefix() {` |
| `★ Makefile 依赖声明` | `Makefile:21-23` | `LUCI_DEPENDS:=...+iptables-mod-conntrack-extra +kmod-ipt-conntrack-extra +ipset +kmod-ipt-ipset` |
| `★ index.htm 12 列布局` | `luasrc/view/eqosplus/index.htm:9-32` | `nth-child(1..12)` 的宽度声明 |
| `★ index.htm placeholder colspan=12` | `luasrc/view/eqosplus/index.htm:398` | `td.setAttribute('colspan', '12')` |
| `★ index.htm schedule nth-child(10)` | `luasrc/view/eqosplus/index.htm:407-408` | 注释 `Schedule is column 10` + querySelector |
| `★ index.htm MAC→conn input readOnly` | `luasrc/view/eqosplus/index.htm:433` 起 | 整段 IIFE：`MAC_RE.test(...) → inp.readOnly = true; inp.value = '0'` |
| `★ po 翻译条目` | `po/zh_Hans/eqosplus.po`, `po/zh-cn/eqosplus.po` | `Conn In`, `Conn Out`, `TCP only` 等 |
| `★ eqosplus_test conn 段开头` | `root/usr/bin/eqosplus_test` 末尾 `Connection limit (...)` 段 | `for _net in eqotest_a eqotest_b` (起末两个清理循环) |
| `★ eqosplus_traffic_test 双臂段` | `root/usr/bin/eqosplus_traffic_test` 中段 | `Connection limit (real TCP via FORWARD chain)` |
| `★ eqosplus_traffic_test 单臂段` | `root/usr/bin/eqosplus_traffic_test` 末段 | `Connection limit (single-arm / bridge hairpin)` |

---

## 10. 关键设计决策记录

| 决策 | 取舍 | 选择 |
|------|------|------|
| 后端识别时机 | postinst / 首次 start / 每次运行时 | postinst 写 UCI + 自愈兜底 |
| 后端隔离 | nft 独立表 / iptables 独立链 | 都用独立命名空间，便于清理 |
| comment 命名空间 | uuid / rule_id_str | rule_id_str（支持网络级前缀扫除）|
| 同区域 bypass 实现 | 一条规则匹配多子网 / set | nft set + ipset（O(1)，零 N²）|
| MAC + 限连接数 | 解析存 IPv4 / 解析存 v4+v6 / 完全不支持 | **完全不支持**（UI 禁用 + CBI validate 拒绝），简化大于功能 |
| CIDR + connlimit 语义 | per-host / 子网级共享 | 统一为子网级共享（iptables 拿 CIDR 前缀做 `--connlimit-mask`） |
| 仅出站 vs 双向 | 单向 / 双 / 用户选 | 拆 `conn_in` + `conn_out` 两个独立字段 |
| TCP 过滤 | 强制 TCP / 配置项 | `tcp_only` Flag，默认 1 |
| fw4 stop 自愈 | nftables.d 静态骨架 / hotplug / daemon probe | daemon probe（nftables.d 会让"表存在但内容缺失"假阳性）|
| 测试隔离 | 单独测试表 / 共表 + 命名前缀 | 共表 + `eqotest_*` 前缀 + per-network teardown |
| Backend 字段名 | mac / target | `target`，旧 `mac` 通过双读兼容 |

---

## 11. Review 检查清单

跑一遍以下检查可发现图与代码的不一致：

- [ ] **每条 ★ 标注**在第 9 节代码对应表里能找到行号
- [ ] **add_mac** 调用了 `eqos_del_conn "$1"` 但**绝不**调用 `eqos_add_conn`（MAC 不支持限连接数）
- [ ] **add_ip** 调用了 `eqos_del_conn "$1"` + 按方向的 `eqos_add_conn out / in`
- [ ] **start_network** 在 `eqos_init_dev` 之后立即 `eqos_init_conn_network`
- [ ] **stop_network** 在 `eqos_teardown_dev` 之后调 `eqos_teardown_conn_network`（而非 table 级 teardown）
- [ ] **eqosplus start** case 同时有 `eqos_teardown_conn_table` + `eqos_init_conn_table`
- [ ] **eqosplus stop** case 调 `eqos_teardown_conn_table`
- [ ] **eqosplusctrl idlistusr** 第一行 `[ -s networks ] || return` 之后立即是 sanity probe
- [ ] **daemon probe** iptables 路径同时检 v4 chain + v6 chain + v4 jump + v6 jump（4 项探测）
- [ ] **fw3-include.sh** 仅在 `backend=iptables` 时由 uci-defaults 注册（fw4 不需要）
- [ ] **JS** 用 `inp.readOnly = true`（绝不是 `inp.disabled = true` —— 后者会让字段不提交，UCI 留旧值）
- [ ] **测试脚本**未出现 `eqos_teardown_conn_table`（只用 `eqos_teardown_conn_network`）
- [ ] **测试网络名**全部以 `eqotest_` 前缀
- [ ] **comment 格式**：`eqos:rule:<rule_id>` 和 `eqos:bypass:<network>:` 在 nft 和 iptables 两边一致
- [ ] **CIDR 前缀**真的传到了 `--connlimit-mask`（iptables 路径）
- [ ] **4 处防御性 `#` strip**：`add_mac`、`add_ip`、`_add_rule`、`_reapply_conn_for_active_rules`

可用 `grep` 快速验证：

```bash
# 验测试隔离
grep -n 'eqos_teardown_conn_table' root/usr/bin/eqosplus_test root/usr/bin/eqosplus_traffic_test
# 应该没输出（只有注释或 trap 里 cleanup_fwd 用，但 cleanup_fwd 自己只调 teardown_conn_network）

# 验测试网络名前缀
grep -nE '"(qatest|fwdtest|trafficq|saone|qatest2)"' root/usr/bin/eqosplus_test root/usr/bin/eqosplus_traffic_test
# 应该没输出

# 验 comment 格式一致
grep -n 'eqos:rule:' root/usr/lib/eqosplus/core.sh root/usr/bin/eqosplus_test
grep -n 'eqos:bypass:' root/usr/lib/eqosplus/core.sh root/usr/bin/eqosplus_test
```
