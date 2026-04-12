# luci-app-eqosplus

OpenWrt 定时网速限制插件。支持按 MAC/IP/子网 限速，支持定时调度。

Fork 自 [sirpdboy/luci-app-eqosplus](https://github.com/sirpdboy/luci-app-eqosplus)，重构了底层架构，更适合低版本 OpenWrt。

## 与上游的区别

| | 上游 (sirpdboy) | 本项目 |
|--|----------------|--------|
| 流量分类 | nftables mark + tc u32 | **tc flower**（无防火墙依赖） |
| 队列管理 | SFQ | **fq_codel**（自带 AQM，降低延迟） |
| 网络支持 | 单网络 | 多网络（按接口自动分区） |
| VLAN 兼容 | u32 偏移受 VLAN 标签影响 | flower 不受影响 |
| 不受控设备 | 所有流量经 IFB | 仅受控设备经 IFB，其余零开销 |
| 跨 VLAN 旁路 | 无 | 自动检测 bridge 子网，跨 VLAN 不限速 |
| 跨午夜定时 | 不支持 | 支持（如 23:00-06:00） |
| 并发保护 | 文件锁（有竞态） | mkdir 原子锁 |
| 调试工具 | 无 | 日志系统 + 诊断 + 结构/流量测试 |
| 最低要求 | nftables (OpenWrt 22.03+) | **tc flower (OpenWrt 19.07+)** |

## 兼容性

| OpenWrt 版本 | 内核 | tc flower | 兼容性 |
|-------------|------|-----------|--------|
| 19.07 | 4.14 | cls_flower 可用 | 理论兼容 |
| 21.02 | 5.4 | cls_flower 可用 | **已测试** |
| 22.03 | 5.10 | cls_flower 可用 | 兼容 |
| 23.05 | 5.15 | cls_flower 可用 | 兼容 |
| 24.10 | 6.6 | cls_flower 可用 | 兼容 |

## 安装

### 从源码编译

```bash
# 在 OpenWrt SDK 目录下
git clone https://github.com/byl0561/luci-app-eqosplus.git package/luci-app-eqosplus
make package/luci-app-eqosplus/compile V=s
```

### 安装 ipk

```bash
opkg install luci-app-eqosplus_*.ipk
```

### 依赖

自动安装：`bash` `tc` `kmod-sched-core` `kmod-ifb` `kmod-sched` `kmod-sched-flower` `luci` `luci-base` `luci-compat`

## 使用

### 基本操作

1. 进入 **服务 → 定时限速**
2. 勾选 **启用**
3. 在对应网络接口下添加规则

### 规则示例

| 场景 | IP/MAC 填写 | 下载(MB/s) | 上传(MB/s) | 时间 | 星期 |
|------|------------|-----------|-----------|------|------|
| 限制单个设备 | `AA:BB:CC:DD:EE:FF` | 10 | 5 | 00:00-00:00 | 每天 |
| 限制单个 IP | `192.168.1.100` | 5 | 2 | 08:00-22:00 | 工作日 |
| 限制子网(共享) | `192.168.10.0/24` | 20 | 10 | 00:00-00:00 | 每天 |
| 夜间限速 | `AA:BB:CC:DD:EE:FF` | 1 | 0.5 | 23:00-07:00 | 每天 |

- 时间 `00:00-00:00` 表示全天生效
- 下载/上传单位为 **MB/秒**（非 Mbit/秒）
- 子网规则下所有设备共享带宽

### 调试

在设置中将 **日志级别** 调为 Info 或 Debug，页面底部会实时显示日志。

点击 **运行诊断** 查看当前 tc 规则状态。

点击 **结构测试** / **流量测试** 验证 tc 功能是否正常。

### 命令行

```bash
/etc/init.d/eqosplus start|stop|restart   # 服务控制
eqosplus status                            # 查看 tc 规则
eqosplus log                               # 查看日志
```

## 技术说明

### 限速原理

```
下载: 互联网 → 路由 → FORWARD → br-lan egress → HTB(flower dst_mac/dst_ip 分类) → 设备
上传: 设备 → br-lan ingress → mirred → IFB egress → HTB(flower src_mac/src_ip 分类) → 路由 → 互联网
```

- 下载方向：tc 挂在 br-lan 出口，flower 匹配目标 MAC/IP
- 上传方向：仅受控设备的流量被 mirred 到 IFB，flower 匹配源 MAC/IP
- 不受控设备：下载走 default class (fq_codel)，上传不经过 IFB

### 跨 VLAN 旁路

启动时自动扫描所有 bridge 设备的子网，对源/目标在 LAN 子网内的流量放行（不限速）。CGNAT 环境安全（不依赖 RFC1918 段，只匹配实际 bridge 子网）。

### 文件结构

```
/usr/bin/eqosplus              主脚本（tc 规则管理）
/usr/bin/eqosplusctrl          定时守护进程（30秒轮询）
/usr/bin/eqosplus_test         结构测试（dummy 设备）
/usr/bin/eqosplus_traffic_test 流量测试（veth + namespace）
/etc/init.d/eqosplus           服务管理
/etc/hotplug.d/iface/10-eqosplus  接口变化自动重启
/etc/config/eqosplus           配置文件
/tmp/eqosplus.log              运行日志
```

## 许可证

GPL v2

## 致谢

- [sirpdboy](https://github.com/sirpdboy/luci-app-eqosplus) — 原始项目作者
