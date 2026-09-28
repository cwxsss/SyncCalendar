# SyncCalendar（同步日历）

一款以**同步为核心**的鸿蒙原生日历应用，基于 HarmonyOS NEXT（ArkTS / Stage 模型）开发。对接标准 CalDAV 服务器（群晖、Nextcloud、Radicale、Baikal 等），让你的日程真正掌握在自己手里——不经过第三方云服务，数据始终同步在你自己的 NAS 上。

- 应用市场送审版本：**0.0.2** ｜ 仓库当前：**0.0.3**（versionCode 300）
- 官网：<https://synccalendar.yangyq.net> ｜ 问题反馈：<https://synccalendar.yangyq.net/feedback/>
- 开源协议：Apache License 2.0

---

## ✨ 功能特性

### CalDAV 同步

- 完整协议链路：**PROPFIND** 发现日历本 → **REPORT** 全量拉取 → **ETag** 增量比对 → **PUT / DELETE** 双向推送
- 一个账号可挂载多个日历本，按需勾选同步范围；支持在线编辑账号、重选日历本、删除账号
- 解析 **VEVENT / VTODO / VALARM / RRULE / EXDATE / RECURRENCE-ID**，重复日程的**单次覆盖实例**也能正确还原
- 支持 VTODO 待办同步（只读展示，不参与推送）
- 「重建日程数据」可强制整表重拉，用于修复提醒丢失等本地数据问题

### 日历视图与交互

- **月 / 周 / 列表** 三种视图（顶部标签切换，也支持左右滑动手势）；默认视图可在设置里指定
- 月视图三页 Swiper 左右翻月、显示**农历**（初一显示月名），点击查看当日日程
- 周视图支持按天左右滑动切换日期，跨月自动重载
- 列表视图按天分组、今日置顶，配合 List 虚拟化保证长列表流畅
- 日程显示方式两种：**竖向时间轴**（按时间刻度看一天的占用与冲突，带当前时间红线）／**列表**（快速扫读，适合长标题）
- 重复日程（RRULE）按规则完整展开：DAILY / WEEKLY / MONTHLY / YEARLY 及 INTERVAL、BYDAY、UNTIL、EXDATE 等
- 可选**混合显示系统日历**，并与 DAV 数据自动去重
- 点击日程里的「地点」可**拉起高德 App 路线规划**（系统地理编码 + WGS84→GCJ02 坐标转换，地址文本不落日志）

### 日程编辑与提醒

- 新建 / 编辑 / 删除日程并推送回服务器，支持全天日程、地点、描述、重复规则、多级提前提醒
- 自动读取服务器端 **VALARM** 提醒（如"开始前 10 分钟"）
- 基于**系统级代理提醒**（`reminderAgentManager`）发送通知，App 被杀、手机重启后依然生效，通知可右滑删除
- 保存带提醒的日程时会**在那一刻**申请通知权限；被拒绝也不影响日程保存，之后可在设置页再开启

### 系统日历镜像（可选增强，默认关闭）

镜像是**可选项**，App 本体不依赖它也能完整使用。开启后：

- **镜像到系统日历**：把选中的 CalDAV 日历本写入系统日历，这样**小艺语音、桌面日历卡片和手表**也能看到你的日程。每个日历本在系统日历里是**独立账户**，可单独设色与隐藏
- **把系统日历的改动回写**：你在系统日历里新建、修改、删除的日程，同步回指定的 CalDAV 日历本（相当于把本机日程备份到服务器）
- 采用**星型架构**：服务器 ↔ 本地库、本地库 ↔ 系统日历各做一次两方同步，不会互相污染
- 日历本用**稳定的 bookId**（`账号ID-资源路径哈希`）标识，不随勾选顺序变化；取消勾选、目标失效时会自动关闭备份并把相关账户清理干净，绝不把日程写进你没选过的日历本
- 重复日程不写入系统 `recurrenceRule`，而是按时间窗口自行展开（过去 1 年 ~ 未来 2 年），保证 `RECURRENCE-ID` 覆盖与 `EXDATE` 排除精确对应

### 桌面服务卡片

- 四种规格：**2×2 / 2×4 / 4×4 / 6×4**，时间轴样式设计
- 按天分组展示未来日程，组内全天事件置顶；跨天日程智能归入"今天"，标注"全天"
- 每条日程左侧竖条颜色与日历本一致，右侧显示所属日历本名
- 同步完成后自动刷新，`formId` 持久化保证 App 重启后推送不丢

### 后台同步与数据备份

- **自动同步间隔**：App 在前台时按设定间隔自动同步
- **后台持续同步**：申请后台长时任务（`dataTransfer`），退到后台也按间隔继续同步，通知栏显示常驻通知
- **系统级定时同步**：通过 WorkScheduler 扩展能力在条件满足时触发一轮同步
- **应用数据备份/恢复**：接入 Backup 扩展能力，换机时可恢复账号与本地数据

### 界面与适配

- **深色模式**：全程使用资源引用（`$r('app.color.*')`），深浅两套色板一一对应，跟随系统自动切换
- **沉浸式**：系统状态栏与导航栏全透明，每页（含内置文档页）都做了安全区扩展
- **大屏与横竖屏**：以**窗口短边是否达到 840vp** 作为大屏判据（而非屏幕方向），因此折叠屏展开态、平板可自由横竖屏切换，而在屏幕比例接近 1:1 的设备上旋转时布局保持一致
- **转场动效**：所有页面使用系统转场，淡入淡出 + 弹簧曲线（`curves.springMotion`），不做单帧直切、左右平移或上下位移

### 设置项一览

系统日历处理方式（仅显示 / 备份到 CalDAV）· 镜像到系统日历 · 选择要镜像的日历本 · 回写开关 · 默认视图 · 日程显示方式 · 自动同步间隔 · 后台持续同步 · 通知权限 · 混合显示系统日历 · 日历本只读 / 静音 · 重建日程数据 · 重置账号库 · 软件特性 · 使用帮助 · 隐私政策与用户协议

---

## 🔒 隐私

我们遵循"**数据自持、最小必要**"原则：

- 开发者**不保存**你的日程与账号数据（账号密码只存在本机）
- **不收集**通讯录、相册、剪贴板等信息，**不含**任何第三方统计或广告 SDK
- 页面从不展示他人邮箱；日志对日程标题、地点等敏感字段做**脱敏**处理
- 权限**按需申请**：只有当你主动使用某个功能（如开启镜像、设置提醒、点击地点导航）时才弹窗申请，启动、首启、同意隐私政策时都**不会**提前申请
- 权限被拒绝后，对应功能默认关闭，可随时在系统设置或本应用设置页重新开启

---

## 🛠 技术要点

- **架构**：`SyncEngine` 同步引擎 + `DavClient`（HTTP / WebDAV）+ `EventDb`（relationalStore 本地库）+ `CalendarDataService`（多源合并展示）
- **镜像**：`SystemCalendarMirror`（出站写入）+ `MirrorInbound`（入站回写）+ `MirrorSnapshot`（变更快照）
- **卡片**：FormExtensionAbility + FormBindingData，JSON 数据驱动渲染
- **农历**：`LunarUtil`，1901–2099 压缩表推算
- **提醒**：`ReminderService` 基于 `reminderAgentManager` 代理提醒
- **权限**：INTERNET / READ_CALENDAR / READ_WHOLE_CALENDAR / WRITE_CALENDAR（仅镜像）/ PUBLISH_AGENT_REMINDER / KEEP_BACKGROUND_RUNNING / LOCATION（仅地点导航时）

### 目录结构

```
SyncCalendar/
├─ AppScope/                    应用级配置（包名、版本号）
└─ entry/src/main/
   ├─ ets/
   │  ├─ common/                核心能力
   │  │  ├─ SyncEngine.ets          同步引擎（拉取 → 解析 → 落库 → 推送）
   │  │  ├─ DavClient.ets           CalDAV / WebDAV 协议客户端
   │  │  ├─ EventDb.ets             relationalStore 本地库
   │  │  ├─ IcsUtil.ets             ICS 解析与生成
   │  │  ├─ RruleUtil.ets           重复规则展开
   │  │  ├─ CalendarDataService.ets 多源合并、系统日历读取
   │  │  ├─ SystemCalendarMirror.ets / MirrorInbound.ets / MirrorSnapshot.ets
   │  │  ├─ ReminderService.ets     代理提醒
   │  │  ├─ CardDataService.ets     卡片数据
   │  │  ├─ AppSettings.ets / AccountStore.ets
   │  │  └─ LunarUtil.ets / TimelineUtil.ets / DocViewer.ets / TipsPanel.ets …
   │  ├─ pages/                 Index / Accounts / AddAccount / CalendarList /
   │  │                         EditAccount / EventEdit / Settings + widget/*
   │  ├─ entryability/          主能力
   │  ├─ entrybackupability/    应用数据备份恢复
   │  ├─ entryformability/      桌面卡片
   │  └─ syncwork/              后台定时同步（WorkScheduler）
   └─ resources/                base / dark 两套资源与颜色
```

---

## 📦 构建与运行

1. 使用 **DevEco Studio** 打开工程根目录
2. 连接鸿蒙真机（需 HarmonyOS NEXT）或模拟器
3. 编译安装后进入「≡ → 账号管理」，添加 CalDAV 服务器地址、用户名和密码
4. 选择要同步的日历本，等待首次同步完成
5. 长按桌面空白处 → 添加服务卡片，选择 SyncCalendar 的卡片规格

> 上架包构建：`hvigorw assembleApp --mode project -p product=default -p buildMode=release`
> （需要在 `build-profile.json5` 里配置自己的签名，该文件不入库）

---

## 📷 截图

| 月视图 | 周视图 |
|---|---|
| ![月视图](截图/微信图片_20260915083446_376_241.jpg) | ![周视图](截图/微信图片_20260915083448_379_241.jpg) |

| 列表 / 时间轴 | 日程详情 |
|---|---|
| ![列表](截图/微信图片_20260915083449_380_241.jpg) | ![详情](截图/微信图片_20260915083450_381_241.jpg) |

| 设置 | 账号管理 |
|---|---|
| ![设置](截图/微信图片_20260915083450_382_241.jpg) | ![账号](截图/微信图片_20260915083451_383_241.jpg) |

| 桌面卡片 | 深色模式 |
|---|---|
| ![卡片](截图/微信图片_20260915083452_384_241.jpg) | ![深色](截图/微信图片_20260915083452_385_241.jpg) |

---

## 🔗 相关链接

| | |
|---|---|
| 官方网站 | <https://synccalendar.yangyq.net> |
| 使用帮助 | <https://synccalendar.yangyq.net/uh.html> |
| 软件特性 | <https://synccalendar.yangyq.net/sf.html> |
| 隐私政策 | <https://synccalendar.yangyq.net/upa.html> |
| 用户服务协议 | <https://synccalendar.yangyq.net/usa.html> |
| 问题反馈 | <https://synccalendar.yangyq.net/feedback/> |

网站备案：**鲁ICP备17014997号-6A**

---

## 📄 开源说明

本项目仅供学习交流使用，采用 **Apache License 2.0** 协议，详见 [LICENSE](LICENSE)。

该项目使用人工智能辅助完成。
