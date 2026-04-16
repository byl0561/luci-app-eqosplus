# luci-app-eqosplus

OpenWrt 定时网速限制插件。

Fork 自 [sirpdboy/luci-app-eqosplus](https://github.com/sirpdboy/luci-app-eqosplus)，重构了底层架构，更适合低版本 OpenWrt。

## 功能

- 按 **MAC / IP / IPv6 / 子网** 限速，支持 IPv4 和 IPv6
- **定时调度**：按时间段 + 星期（多选）生效，支持跨午夜
- **多网络管理**：按防火墙区域自动分组（LAN / Guest / IoT …）
- **同区域免限速**：同一区域内设备互访不受限速影响
- 内置日志、诊断、结构测试和流量测试工具
- 兼容 OpenWrt 19.07 ~ 24.10

## 安装

```bash
# 从源码编译（在 OpenWrt SDK 目录下）
git clone https://github.com/byl0561/luci-app-eqosplus.git package/luci-app-eqosplus
make package/luci-app-eqosplus/compile V=s

# 或直接安装 ipk
opkg install luci-app-eqosplus_*.ipk
```

依赖自动安装。测试功能所需的可选包（`kmod-dummy`、`ip-full`、`kmod-veth`）会在点击测试按钮时自动检测并安装。

## 使用

1. 进入 **网络 → 定时限速**，勾选 **启用**
2. 在 **配置** 标签页选择要管理的防火墙区域（默认 LAN）
3. 添加限速规则

### 规则示例

| 场景 | IP/MAC | 下载(MB/s) | 上传(MB/s) | 开始 | 结束 | 周期 |
|------|--------|-----------|-----------|------|------|------|
| 限制单个设备 | `AA:BB:CC:DD:EE:FF` | 10 | 5 | 00:00 | 00:00 | 一~日 |
| 限制单个 IP | `192.168.1.100` | 5 | 2 | 08:00 | 22:00 | 一~五 |
| 限制子网(共享带宽) | `192.168.10.0/24` | 20 | 10 | 00:00 | 00:00 | 一~日 |
| 夜间限速 | `AA:BB:CC:DD:EE:FF` | 1 | 0.5 | 23:00 | 07:00 | 一~日 |

- 开始/结束均为 `00:00` = 全天生效
- 跨午夜时间（如 23:00→07:00）自动处理
- 速度单位为 **MB/秒**，每个网络最多 50 条规则
- MAC 规则同时覆盖 IPv4/IPv6；IP 规则仅针对对应协议

> ⚠️ 与 TurboACC 软件流量卸载（sw_flow / sfe_flow）冲突，需先关闭。

### 命令行

```bash
/etc/init.d/eqosplus start|stop|restart
eqosplus status    # 查看当前规则
eqosplus log       # 查看日志
```

## 许可证

GPL v2

## 致谢

- [sirpdboy](https://github.com/sirpdboy/luci-app-eqosplus) — 原始项目作者
