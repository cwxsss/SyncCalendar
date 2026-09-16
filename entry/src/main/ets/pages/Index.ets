// entry/src/main/ets/pages/Index.ets
// 同步日历主界面：月视图（左右滑动翻月）/ 周视图 / 日视图 / 日程列表
// 混合展示 DAV 与系统日历；每分钟自动同步；可"回到今天"
import { mediaquery, router } from '@kit.ArkUI';
import { common, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { DavAccount, AccountStore, CalSource, TYPE_CALDAV } from '../common/AccountStore';
import { DisplayEvent, CalendarDataService } from '../common/CalendarDataService';
import { SyncEngine } from '../common/SyncEngine';
import { LogUtil } from '../common/LogUtil';
import { LunarUtil } from '../common/LunarUtil';
import { CardDataService } from '../common/CardDataService';
import { ReminderService } from '../common/ReminderService';
import { AppSettings } from '../common/AppSettings';
import { TipsPanel } from '../common/TipsPanel';
import { DocViewer } from '../common/DocViewer';
import { EventDb, LocalEvent, RemoteEvent } from '../common/EventDb';
import { RruleUtil } from '../common/RruleUtil';
import { IcsUtil } from '../common/IcsUtil';
import { DavClient, RemoteItem } from '../common/DavClient';
import { SystemCalendarImport } from '../common/SystemCalendarImport';
import { ScreenKeeper } from '../common/ScreenKeeper';
import { TimelineUtil, TimelineBlock, TimelineGroup, DayTimeline, ViewRange } from '../common/TimelineUtil';

/** 月视图单元格 */
class MonthCell {
  dateMs: number = 0;
  day: number = 0;
  inMonth: boolean = false;
  isToday: boolean = false;
  lunar: string = ''; // 农历（初一时显示月名）
}

const WEEK_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/** 视图前后顺序（决定手势/标签切换时的转场方向）：月 → 周 → 列表 */
const VIEW_ORDER: string[] = ['month', 'week', 'agenda'];

@Entry
@Component
struct Index {
  @State mode: string = 'month'; // month | week | agenda | todo
  @State displayYear: number = 2026;
  @State displayMonth: number = 0; // 0-11
  @Watch('onSelectedDateChange') @State selectedDate: number = 0; // 当天 0 点毫秒
  @State events: DisplayEvent[] = [];
  @State todos: DisplayEvent[] = []; // 待办（VTODO，单独展示）
  @State agendaEvents: DisplayEvent[] = []; // 列表视图全量数据（今天 ~ 未来2年）
  private agendaStale: boolean = true; // 全量数据是否需要重新加载
  @State monthPages: MonthCell[][] = [[], [], []]; // 上月/本月/下月
  @State syncing: boolean = false;
  @State loading: boolean = true;
  @State menuOpen: boolean = false; // 顶部 ≡ 下拉菜单
  @State isLandscape: boolean = false; // 横屏：月视图切左右双栏（左月历/右当日日程）
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  private accounts: DavAccount[] = [];
  private sources: CalSource[] = [];
  private swiperController: SwiperController = new SwiperController();
  private swiperGuard: boolean = false;
  private navDir: number = 1; // 视图切换方向：1 前进（向下钻取），-1 后退（向上回退）
  private autoSyncTimer: number = -1;
  private nowTimer: number = -1; // 红线位置"播放"计时器（每 30s 刷新 nowMs）
  private agendaScroller: Scroller = new Scroller(); // 列表视图滚动控制器：加载后定位到"当前时刻（红线）"
  @State private agendaViewportH: number = 0;        // 列表视口高度（实测，用于把红线滚到屏幕中间）
  private agendaScrollPending: boolean = false;      // 还未拿到真实视口高度 → 等实测后再校正一次
  private lastSyncTime: number = 0;
  private permissionAsked: boolean = false;
  @State detailShow: boolean = false; // 只读日程详情半屏弹层
  @State detailEvent: DisplayEvent | null = null;
  // 服务卡片"添加"按钮深链：EntryAbility 写入，本页读取后拉起新建日程页
  @Watch('onWidgetActionChange') @StorageLink('widgetAction') widgetAction: string = '';
  @State nowMs: number = Date.now(); // 当前时刻毫秒（驱动红线"播放"位置，每 30s 更新）
  // 时间轴视图（月/周/列表共用）：按天预计算好色块布局，避免 build 中重算
  @State dayTimeline: DayTimeline = new DayTimeline();            // 选中日（月/周视图用）
  @State agendaTimelines: AgendaTimelineGroup[] = [];             // 列表视图：每天一条时间轴
  // 日程显示方式：'timeline'（竖向时间轴，默认） | 'list'（列表）。
  // 列表模式无时间刻度 → 不绘制"当前时间红线"，改用"进行中"文字标记。
  @State displayStyle: string = 'timeline';

  // ---- 隐私政策与用户协议首启同意（未同意前不申请任何权限、不加载数据） ----
  @State policyChecked: boolean = false;  // 是否已读取过同意状态（避免首帧闪烁）
  @State policyAgreed: boolean = false;   // 是否已同意《隐私政策》与《用户协议》
  private notifAsked: boolean = false;    // 通知权限是否已申请（同意后才申请）
  @State showTips: boolean = false;       // 首启功能引导（整页覆盖层：遮罩 + 底部卡片 + Swiper 三页）
  // ---- 内置文档浏览器（《隐私政策》/《用户服务协议》，整页 Web 覆盖层，不跳出应用） ----
  @State showDoc: boolean = false;
  @State docTitle: string = '';
  @State docUrl: string = '';

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      LogUtil.init(ctx);
    }
    LogUtil.write('---- App 启动：主界面初始化 ----');
    const now = new Date();
    this.displayYear = now.getFullYear();
    this.displayMonth = now.getMonth();
    this.selectedDate = this.startOfDay(now.getTime());
    this.rebuildPages();
    this.initLandscapeListener();
    // 首启同意门禁：未同意《隐私政策》与《用户协议》前，不申请任何系统权限、不加载/同步数据（AGC 硬性要求）
    if (ctx === undefined) {
      this.policyChecked = true;
      this.startApp(ctx);
    } else {
      AppSettings.getPolicyAgreed(ctx).then((ok: boolean): void => {
        this.policyChecked = true;
        if (ok) {
          this.startApp(ctx);
        }
        // 未同意：仅显示整页同意门禁（consentGate），不申请权限、不加载数据
      });
    }
    // 红线"播放"效果：每 30s 更新 nowMs，让当前时间红线随真实时间推进（同时刷新色块"进行中"标记）
    this.nowTimer = setInterval((): void => {
      this.nowMs = Date.now();
      this.refreshNowMarks();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.autoSyncTimer !== -1) {
      clearInterval(this.autoSyncTimer);
      this.autoSyncTimer = -1;
    }
    if (this.nowTimer !== -1) {
      clearInterval(this.nowTimer);
      this.nowTimer = -1;
    }
    if (this.landscapeListener !== null) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  /** 监听横竖屏：旋转后 isLandscape 驱动月视图在上下/左右布局间切换 */
  private initLandscapeListener(): void {
    this.landscapeListener =
      this.getUIContext().getMediaQuery().matchMediaSync('(orientation: landscape)');
    this.isLandscape = this.landscapeListener.matches;
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isLandscape = result.matches;
    });
  }

  /** 从设置页/账号页返回时刷新（同步间隔、系统日历开关立即生效），并处理编辑账号后的待同步 */
  onPageShow(): void {
    // 未同意《隐私政策》前不加载、不同步任何数据
    if (!this.policyAgreed) {
      return;
    }
    // 首启功能引导兜底：已同意用户若在 aboutToAppear 阶段漏触发，这里再补一次（幂等：已展示过会直接跳过）
    const tipCtx = this.getUIContext().getHostContext();
    if (tipCtx !== undefined) {
      this.maybeShowTips(tipCtx);
    }
    // 卡片"添加"按钮深链：首次冷启动经 onCreate→AppStorage 落到这里消费
    this.consumeWidgetAction();
    // 无条件刷新：之前"列表为空就跳过"的条件会导致账号列表卡死在空状态，
    // 同步时误报"没有可同步的账号"
    this.reloadAll().then((): Promise<void> => this.handlePendingSync());
  }

  /** 卡片深链监听（App 已在后台运行时，onNewWant 改写 AppStorage 触发） */
  private onWidgetActionChange(): void {
    this.consumeWidgetAction();
  }

  /** 消费卡片"添加"深链：拉起新建日程页并立即清除标记，避免重复触发 */
  private consumeWidgetAction(): void {
    const action: string = AppStorage.get<string>('widgetAction') ?? '';
    if (action === 'add') {
      AppStorage.setOrCreate<string>('widgetAction', '');
      this.addEvent();
    }
  }

  private async handlePendingSync(): Promise<void> {
    const pendingId: string | undefined = AppStorage.get<string>('pendingSyncAccountId');
    if (pendingId !== undefined && pendingId !== '') {
      AppStorage.setOrCreate<string>('pendingSyncAccountId', '');
      await this.syncSingle(pendingId);
    }
  }

  private initPermissionAndLoad(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.reloadAll();
    this.ensureNotificationPermission(context as common.UIAbilityContext);
    if (!this.permissionAsked) {
      this.permissionAsked = true;
      // 申请读取全部日历权限（用于混合展示系统日程）
      CalendarDataService.ensureSystemCalendarPermission(context as common.UIAbilityContext)
        .then((): void => {
          this.reloadAll();
        });
    }
  }

  /**
   * 申请通知权限（日程提醒、后台同步常驻通知都依赖它）。
   * 必须在用户同意《隐私政策》之后才调用 —— 同意前不得申请任何权限。
   */
  private ensureNotificationPermission(context: common.UIAbilityContext): void {
    if (this.notifAsked) {
      return;
    }
    this.notifAsked = true;
    notificationManager.isNotificationEnabled()
      .then((enabled: boolean): Promise<void> => {
        if (!enabled) {
          return notificationManager.requestEnableNotification(context).catch((): void => {});
        }
        return Promise.resolve();
      })
      .catch((): void => {});
  }

  /**
   * 同意之后（或"已同意用户"启动时）的正式初始化：
   * 申请权限、加载数据、读取默认视图，并首启弹一次功能引导卡片。
   * 首次同意（acceptPolicy）与已同意直接启动（aboutToAppear）都走这里，保证两条路径都能弹出引导。
   */
  private startApp(ctx: common.Context | undefined): void {
    this.policyAgreed = true;
    this.initPermissionAndLoad();
    if (ctx !== undefined) {
      // 读取"默认视图"设置：打开 App 后按用户选择展示（月/周/列表，默认月）
      AppSettings.getDefaultView(ctx).then((v: string): void => {
        this.mode = v;
        if (v === 'agenda') {
          this.ensureAgendaData();
        }
      });
      this.maybeShowTips(ctx);
    }
  }

  /**
   * 首启功能引导：仅在用户从未看过时显示一次（整页覆盖层），之后不再出现。
   * 注意：这里**不写"已看过"标记** —— 标记由 hideTips() 在用户主动关闭时写入。
   * 若在此处提前写标记，一旦显示环节出问题就会把引导永久锁死（历史踩过坑）。
   */
  private maybeShowTips(ctx: common.Context): void {
    AppSettings.getTipsShown(ctx).then((seen: boolean): void => {
      if (seen) {
        return;
      }
      // 略延迟：先让主页面完成首帧布局，并尽量错开紧随其后的权限申请系统弹窗
      setTimeout((): void => {
        this.showTips = true;
      }, 600);
    });
  }

  /** 关闭功能引导覆盖层（"开始使用" / ✕ / 点遮罩 均走这里），此刻才标记"已看过" */
  private hideTips(): void {
    this.showTips = false;
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      AppSettings.setTipsShown(ctx, true);
    }
  }

  /** 用户点击"同意并继续"：持久化同意标记，之后才申请权限、加载数据 */
  private acceptPolicy(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      AppSettings.setPolicyAgreed(ctx, true);
    }
    this.startApp(ctx);
  }

  /** 用户点击"不同意并退出"：不申请任何权限、不处理任何数据，直接退出应用 */
  private rejectPolicy(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      (ctx as common.UIAbilityContext).terminateSelf();
    }
  }

  /**
   * 用内置浏览器（整页 Web 覆盖层）打开法律文档 —— 不跳出应用、随时可关闭。
   * 仅放行 http(s)：避免 URL 被误传为 file://、自定义 scheme 等而拉起本地文件或任意第三方应用。
   */
  private openDoc(title: string, url: string): void {
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      this.getUIContext().getPromptAction().showToast({ message: '仅支持打开 http(s) 链接' });
      return;
    }
    this.docTitle = title;
    this.docUrl = url;
    this.showDoc = true;
  }

  // ---------- 工具 ----------
  private startOfDay(ms: number): number {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  }

  private fmtTime(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private fmtDateCn(ms: number): string {
    const d = new Date(ms);
    return `${d.getMonth() + 1}月${d.getDate()}日 ${WEEK_LABELS[(d.getDay() + 6) % 7]}`;
  }

  private fmtMonthTitle(): string {
    return `${this.displayYear}年${this.displayMonth + 1}月`;
  }

  private addMonths(y: number, m: number, delta: number): number[] {
    let mm: number = m + delta;
    let yy: number = y;
    while (mm < 0) {
      mm += 12;
      yy--;
    }
    while (mm > 11) {
      mm -= 12;
      yy++;
    }
    return [yy, mm];
  }

  // ---------- 数据 ----------
  private async reloadAll(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.accounts = await AccountStore.loadAll(context);
    this.sources = await CalendarDataService.loadSources(context);
    // 显示方式（时间轴 / 列表）可能在设置页被改过，每次回到前台都重新读一次
    this.displayStyle = await AppSettings.getDisplayStyle(context);
    await this.reloadEvents();
    this.startAutoSync();
  }

  /** 自动同步：每 15 秒检查一次，到达设置的间隔（AppStorage.syncIntervalMinutes）才真正同步 */
  private startAutoSync(): void {
    if (this.autoSyncTimer === -1) {
      AppStorage.setOrCreate('syncIntervalMinutes', 1);
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        AppSettings.getSyncIntervalMinutes(ctx).then((v: number): void => {
          AppStorage.setOrCreate('syncIntervalMinutes', v);
        });
      }
      this.autoSyncTimer = setInterval((): void => {
        // 应用内提醒模式（代理提醒配额为 0 的降级）：每 15 秒检查到点的提醒
        const tickCtx = this.getUIContext().getHostContext();
        if (tickCtx !== undefined && !this.syncing) {
          ReminderService.tickReminders(tickCtx as common.UIAbilityContext);
        }
        const minutes: number = AppStorage.get<number>('syncIntervalMinutes') ?? 1;
        if (Date.now() - this.lastSyncTime < minutes * 60000) {
          return; // 未到设置的同步间隔
        }
        if (!this.syncing && this.accounts.length > 0) {
          this.lastSyncTime = Date.now();
          LogUtil.write(`自动同步触发（间隔 ${minutes} 分钟，账号 ${this.accounts.length} 个）`);
          this.syncAll(false);
        }
      }, 15000);
    }
  }

  private async reloadEvents(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.loading = true;
    this.agendaStale = true; // 数据可能变化，列表视图需要重新加载
    const monthStart: number = new Date(this.displayYear, this.displayMonth, 1).getTime();
    // 覆盖：上月尾 7 天 + 本月 + 下月，并确保选中日始终在区间内（跨月点选不漏数据）
    const rangeStart: number = Math.min(monthStart - 7 * 86400000, this.selectedDate - 7 * 86400000);
    const rangeEnd: number = Math.max(monthStart + 62 * 86400000, this.selectedDate + 8 * 86400000);
    this.events = await CalendarDataService.loadEvents(context, rangeStart, rangeEnd, this.sources);
    this.todos = await CalendarDataService.loadTodos(context, this.sources);
    LogUtil.write(`界面刷新完成：日程 ${this.events.length} 条（显示区间内），待办 ${this.todos.length} 条`);
    this.rebuildPages();
    // 当前正处于列表视图时立即重载，避免同步后列表空白
    if (this.mode === 'agenda') {
      await this.ensureAgendaData();
    }
    this.loading = false;
  }

  /** 构建某年某月的 42 格 */
  private buildMonthCells(year: number, month: number): MonthCell[] {
    const first: number = new Date(year, month, 1).getTime();
    const firstDay = new Date(first).getDay();
    const offset: number = (firstDay + 6) % 7; // 周一为一周开始
    const gridStart: number = first - offset * 86400000;
    const todayStart: number = this.startOfDay(Date.now());
    const cells: MonthCell[] = [];
    for (let i = 0; i < 42; i++) {
      const dateMs: number = gridStart + i * 86400000;
      const d = new Date(dateMs);
      const cell = new MonthCell();
      cell.dateMs = dateMs;
      cell.day = d.getDate();
      cell.inMonth = d.getMonth() === month;
      cell.isToday = dateMs === todayStart;
      cell.lunar = LunarUtil.lunarDayText(dateMs);
      cells.push(cell);
    }
    return cells;
  }

  /** 重建三页（上月/本月/下月） */
  private rebuildPages(): void {
    const prev = this.addMonths(this.displayYear, this.displayMonth, -1);
    const next = this.addMonths(this.displayYear, this.displayMonth, 1);
    this.monthPages = [
      this.buildMonthCells(prev[0], prev[1]),
      this.buildMonthCells(this.displayYear, this.displayMonth),
      this.buildMonthCells(next[0], next[1])
    ];
    this.rebuildDayTimeline();
  }

  /** 重建"选中日"的时间轴布局（月/周视图下方那条） */
  private rebuildDayTimeline(): void {
    const dayEvents: DisplayEvent[] = this.eventsOfDate(this.selectedDate);
    const tl: DayTimeline = TimelineUtil.build(dayEvents, this.selectedDate);
    TimelineUtil.markNow(tl.blocks, this.nowMs);
    this.dayTimeline = tl;
    LogUtil.write(`时间轴(${this.fmtDateCn(this.selectedDate)})：输入 ${dayEvents.length} 条 → 色块 ${tl.blocks.length} 块，全天/跨天 ${tl.allDay.length} 条`);
  }

  /** 选中日期变化（点月格/周条）→ 重算该日时间轴 */
  private onSelectedDateChange(): void {
    this.rebuildDayTimeline();
  }

  /** 心跳刷新"进行中"标记（每 30s）：只重算标记，不重建布局，避免整页重绘 */
  private refreshNowMarks(): void {
    TimelineUtil.markNow(this.dayTimeline.blocks, this.nowMs);
    for (const day of this.agendaTimelines) {
      TimelineUtil.markNow(day.timeline.blocks, this.nowMs);
    }
    // 触发 @State 更新（TimelineBlock 非 @Observed，需整体重新赋值）
    const d = new DayTimeline();
    d.dateKey = this.dayTimeline.dateKey;
    d.allDay = this.dayTimeline.allDay;
    d.blocks = this.dayTimeline.blocks;
    d.hasTimed = this.dayTimeline.hasTimed;
    this.dayTimeline = d;
    this.agendaTimelines = this.agendaTimelines.slice();
  }

  private eventsOfDate(dateMs: number): DisplayEvent[] {
    return this.events.filter((e: DisplayEvent): boolean =>
      this.startOfDay(e.startTime) <= dateMs && e.endTime >= dateMs);
  }

  /** 红线日程唯一 key（与时间轴色块 key 保持一致） */
  private nowLineKey(e: DisplayEvent): string {
    return TimelineUtil.keyOf(e);
  }

  private switchMonth(delta: number): void {
    const nm = this.addMonths(this.displayYear, this.displayMonth, delta);
    this.displayYear = nm[0];
    this.displayMonth = nm[1];
    this.reloadEvents();
  }

  /** 回到今天：切回本月并选中今天 */
  private goToday(): void {
    const now = new Date();
    this.displayYear = now.getFullYear();
    this.displayMonth = now.getMonth();
    this.selectedDate = this.startOfDay(now.getTime());
    this.rebuildPages();
    this.reloadEvents();
  }

  /** Swiper 翻页后回正到中间页并切换基准月份 */
  private handleSwiperChange(index: number): void {
    if (this.swiperGuard) {
      this.swiperGuard = false;
      return;
    }
    if (index === 1) {
      return;
    }
    const delta: number = index === 2 ? 1 : -1;
    const nm = this.addMonths(this.displayYear, this.displayMonth, delta);
    this.displayYear = nm[0];
    this.displayMonth = nm[1];
    this.reloadEvents();
    this.swiperGuard = true;
    this.swiperController.changeIndex(1, false);
  }

  // ---------- 同步 ----------
  private async syncSingle(accId: string): Promise<void> {
    const acc = this.accounts.find((a: DavAccount): boolean => a.id === accId);
    if (acc === undefined) {
      return;
    }
    if (acc.type !== TYPE_CALDAV) {
      this.getUIContext().getPromptAction().showToast({ message: '该账号类型暂不支持日程同步' });
      return;
    }
    this.syncing = true;
    // 同步期间保持屏幕常亮：熄屏会挂起进程导致请求停摆、同步超时
    const uiCtx = this.getUIContext().getHostContext();
    if (uiCtx !== undefined) {
      await ScreenKeeper.acquire(uiCtx as common.UIAbilityContext);
    }
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      await SyncEngine.syncAccount(context as common.UIAbilityContext, acc);
      await SyncEngine.pruneOrphanRows(context, this.accounts);
      acc.lastSyncTime = this.formatNow();
      await AccountStore.saveAll(context, this.accounts);
      this.getUIContext().getPromptAction()
        .showToast({ message: `「${acc.name}」同步完成` });
    } catch (err) {
      const e = err as BusinessError;
      this.getUIContext().getPromptAction()
        .showToast({ message: `同步失败：${e.message}` });
    } finally {
      this.syncing = false;
      if (uiCtx !== undefined) {
        await ScreenKeeper.release(uiCtx as common.UIAbilityContext);
      }
      await this.reloadAll();
      // 同步后刷新服务卡片
      try {
        const ctx = this.getUIContext().getHostContext();
        if (ctx !== undefined) {
          await CardDataService.pushToAllForms(ctx);
        }
      } catch (err) {
        // 卡片刷新失败不影响主流程
      }
    }
  }

  private formatNow(): string {
    const d = new Date();
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private async syncAll(manual: boolean): Promise<void> {
    if (this.syncing) {
      return;
    }
    // 防御：账号列表为空时不执行同步、不清理孤儿行、不回写账号存储，
    // 防止异常状态下把所有 CalDAV 日程和账号配置抹掉
    if (this.accounts.length === 0) {
      if (manual) {
        this.getUIContext().getPromptAction().showToast({ message: '没有可同步的账号' });
      }
      return;
    }
    this.syncing = true;
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.syncing = false;
      return;
    }
    // 同步期间保持屏幕常亮：熄屏会挂起进程导致请求停摆、同步超时
    await ScreenKeeper.acquire(context as common.UIAbilityContext);
    let ok: number = 0;
    let failMsg: string = '';
    // 备份模式：先把系统本地日历导入目标日历本（幂等），再随正常同步推送上服务器
    try {
      await SystemCalendarImport.importIfNeeded(context);
    } catch (err) {
      // 导入失败不影响正常同步
    }
    for (const acc of this.accounts) {
      if (acc.type !== TYPE_CALDAV) {
        continue;
      }
      try {
        await SyncEngine.syncAccount(context as common.UIAbilityContext, acc);
        acc.lastSyncTime = this.formatNow();
        ok++;
      } catch (err) {
        const e = err as BusinessError;
        failMsg = e.message;
      }
    }
    try {
      await SyncEngine.settleLocalEvents(context);
      await SyncEngine.pruneOrphanRows(context, this.accounts);
      await AccountStore.saveAll(context, this.accounts);
      // 全部账号同步成功才结束"一次性全量重拉"状态（修复旧模式落库的残缺数据）
      if (failMsg === '') {
        await AppSettings.markFullRefetchDone(context);
      }
    } catch (err) {
      const e = err as BusinessError;
      failMsg = e.message;
    }
    this.syncing = false;
    await ScreenKeeper.release(context as common.UIAbilityContext);
    if (failMsg !== '') {
      this.getUIContext().getPromptAction()
        .showToast({ message: ok > 0 ? `同步完成 ${ok} 个，失败：${failMsg}` : `同步失败：${failMsg}` });
    } else if (ok > 0 && manual) {
      this.getUIContext().getPromptAction()
        .showToast({ message: `同步完成（${ok} 个账号）` });
    }
    await this.reloadAll();
    // 同步后刷新服务卡片 + 重建提醒
    try {
      const ctx2 = this.getUIContext().getHostContext();
      if (ctx2 !== undefined) {
        await CardDataService.pushToAllForms(ctx2);
        await ReminderService.refreshReminders(ctx2);
      }
    } catch (err) {
      // 卡片刷新失败不影响主流程
    }
  }

  private openEvent(e: DisplayEvent): void {
    // 所有日程点击都弹出详情（只读/可写/系统一致）；可写日程在详情中可点"编辑"进入编辑页
    this.showEventDetail(e);
  }

  /** 只读日程详情：改为卡片式半屏弹层（与编辑页风格一致） */
  private showEventDetail(e: DisplayEvent): void {
    this.detailEvent = e;
    this.detailShow = true;
  }

  private detailStartText(e: DisplayEvent): string {
    if (e.isAllDay) {
      return `全天 ${this.fmtDateCn(e.startTime)}`;
    }
    return `${this.fmtDateCn(e.startTime)} ${this.fmtTime(e.startTime)}`;
  }

  private detailEndText(e: DisplayEvent): string {
    const sameDay: boolean = this.startOfDay(e.startTime) === this.startOfDay(e.endTime);
    if (e.isAllDay) {
      return `全天 ${this.fmtDateCn(e.endTime)}`;
    }
    if (sameDay) {
      return this.fmtTime(e.endTime);
    }
    return `${this.fmtDateCn(e.endTime)} ${this.fmtTime(e.endTime)}`;
  }

  /** 点击地点：拉起高德 App 路线规划，地址经系统地理编码转为坐标后传入目的地 */
  private async openInAmap(address: string): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined || address === '') {
      return;
    }
    const ctx = context as common.UIAbilityContext;
    const enc: string = encodeURIComponent(address);
    // 高德鸿蒙深链 dlat/dlon 为必填（dname 仅作名称显示），先地理编码拿坐标
    let coords: number[] | null = null;
    if (await this.ensureLocationPermission()) {
      coords = await this.geocodeAddress(address);
    }
    const base: string = 'amapuri://route/plan/?sourceApplication=SyncCalendar';
    let link: string;
    if (coords !== null) {
      // 系统地理编码返回 WGS84，高德要求 GCJ02（dev=0），做本地转换
      const gcj: number[] = this.wgs84ToGcj02(coords[0], coords[1]);
      link = `${base}&dlat=${gcj[0].toFixed(6)}&dlon=${gcj[1].toFixed(6)}&dname=${enc}&dev=0&t=0`;
    } else {
      // 无坐标时尽力而为：部分版本只认坐标，目的地可能为空
      link = `${base}&dname=${enc}&dev=0&t=0`;
    }
    try {
      await ctx.openLink(link);
      // 日志不落盘地点文本（可能包含家庭/公司等敏感地址），仅记录是否拿到坐标
      LogUtil.write(`已拉起高德导航（地点已脱敏，坐标=${coords !== null ? '有' : '无'}）`);
      return;
    } catch (err) {
      LogUtil.write(`高德深链打开失败：${(err as BusinessError).message}`);
    }
    this.getUIContext().getPromptAction().showToast({ message: '未安装高德地图或无法打开' });
  }

  /** 确认定位权限（地理编码依赖），未授权时向用户申请一次 */
  private async ensureLocationPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.appInfo.accessTokenId;
      const status = await atManager.checkAccessToken(tokenId, 'ohos.permission.LOCATION');
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
    } catch (err) {
      // 未授权会走申请流程
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atManager = abilityAccessCtrl.createAtManager();
      // LOCATION 与 APPROXIMATELY_LOCATION 必须一起申请
      const result = await atManager.requestPermissionsFromUser(context,
        ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION']);
      return result.authResults.every((r: number): boolean => r === 0);
    } catch (err) {
      return false;
    }
  }

  /** 正向地理编码：地址 → 坐标（系统服务，无需高德 key） */
  private async geocodeAddress(address: string): Promise<number[] | null> {
    try {
      if (!geoLocationManager.isGeocoderAvailable()) {
        LogUtil.write('系统地理编码服务不可用');
        return null;
      }
      const req: geoLocationManager.GeoCodeRequest = { description: address, maxItems: 1 };
      const list: geoLocationManager.GeoAddress[] =
        await geoLocationManager.getAddressesFromLocationName(req);
      if (list.length > 0 && list[0].latitude !== undefined && list[0].longitude !== undefined) {
        return [list[0].latitude, list[0].longitude];
      }
      // 日志不落盘地点文本（可能含家庭/公司等敏感地址）
      LogUtil.write('地理编码无结果（地点已脱敏）');
    } catch (err) {
      LogUtil.write(`地理编码失败：${(err as BusinessError).message}`);
    }
    return null;
  }

  /** WGS84 → GCJ02 火星坐标转换（中国境内；标准偏移算法） */
  private wgs84ToGcj02(wlat: number, wlon: number): number[] {
    const a: number = 6378245.0;
    const ee: number = 0.00669342162296594323;
    const transformLat = (x: number, y: number): number => {
      let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y
        + 0.2 * Math.sqrt(Math.abs(x));
      ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
      ret += (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
      ret += (160.0 * Math.sin(y / 12.0 * Math.PI) + 320.0 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
      return ret;
    };
    const transformLon = (x: number, y: number): number => {
      let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
      ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
      ret += (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
      ret += (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
      return ret;
    };
    if (wlon < 72.004 || wlon > 137.8347 || wlat < 0.8293 || wlat > 55.8271) {
      return [wlat, wlon]; // 中国境外无偏移
    }
    let dLat: number = transformLat(wlon - 105.0, wlat - 35.0);
    let dLon: number = transformLon(wlon - 105.0, wlat - 35.0);
    const radLat: number = wlat / 180.0 * Math.PI;
    let magic: number = Math.sin(radLat);
    magic = 1 - ee * magic * magic;
    const sqrtMagic: number = Math.sqrt(magic);
    dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
    dLon = (dLon * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
    return [wlat + dLat, wlon + dLon];
  }

  @Builder
  detailTag(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor($r('app.color.brand'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(9)
      .border({ width: 1, color: $r('app.color.brand') })
  }

  @Builder
  detailRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width(56)
      Text(value)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  detailSheet() {
    Column({ space: 12 }) {
      if (this.detailEvent !== null) {
        // 标题区：色点 + 标题 + 徽标紧跟标题 + 自绘关闭按钮（与标题同行）
        Row({ space: 8 }) {
          Circle()
            .fill(this.detailEvent.color)
            .width(12)
            .height(12)
          Text(this.detailEvent.title === '' ? '(无标题)' : this.detailEvent.title)
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '58%' })
          if (this.detailEvent.isSystem) {
            this.detailTag('系统')
          } else if (!this.detailEvent.writable) {
            this.detailTag('只读')
          }
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .borderRadius(15)
            .backgroundColor($r('app.color.card_bg'))
            .onClick(() => {
              this.detailShow = false;
            })
        }
        .width('100%')

        Scroll() {
          Column({ space: 12 }) {
            // 时间卡片
            Column({ space: 12 }) {
              if (this.detailEvent.isAllDay && !this.spansDays(this.detailEvent)) {
                this.detailRow('时间', `全天 ${this.fmtDateCn(this.detailEvent.startTime)}`)
              } else {
                this.detailRow('开始', this.detailStartText(this.detailEvent))
                Divider().color($r('app.color.shadow_color'))
                this.detailRow('结束', this.detailEndText(this.detailEvent))
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))

            // 日历本 / 重复
            Column({ space: 12 }) {
              Row({ space: 12 }) {
                Text('日历本')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                  .width(56)
                Text(this.detailEvent.calName === '' ? '-' : this.detailEvent.calName)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .textAlign(TextAlign.End)
                  .layoutWeight(1)
              }
              .width('100%')
              if (this.detailEvent.recurring) {
                Divider().color($r('app.color.shadow_color'))
                this.detailRow('重复', '重复日程')
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))

            // 地点：点击打开高德地图导航
            if (this.detailEvent.location !== '') {
              Row({ space: 8 }) {
                Column({ space: 4 }) {
                  Text('地点')
                    .fontSize(14)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.detailEvent.location)
                    .fontSize(15)
                    .fontColor($r('app.color.brand'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('导航 ›')
                  .fontSize(14)
                  .fontColor($r('app.color.brand'))
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .padding(14)
              .borderRadius(12)
              .backgroundColor($r('app.color.card_bg'))
              .onClick(() => {
                if (this.detailEvent !== null) {
                  this.openInAmap(this.detailEvent.location);
                }
              })
            }

            // 备注
            if (this.detailEvent.description !== '') {
              Column({ space: 8 }) {
                Text('备注')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.detailEvent.description)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(14)
              .borderRadius(12)
              .backgroundColor($r('app.color.card_bg'))
            }
          }
          .width('100%')
        }
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
        .layoutWeight(1)
      }
      // 可写日程：详情底部提供"编辑"入口（系统/只读日程无此按钮）
      if (this.detailEvent !== null && !this.detailEvent.isSystem && this.detailEvent.writable) {
        Button('编辑日程')
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.button_text'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(12)
          .onClick(() => {
            const id: number = this.detailEvent !== null ? this.detailEvent.id : 0;
            this.detailShow = false;
            if (id > 0) {
              AppStorage.setOrCreate<number>('pendingEventId', id);
              router.pushUrl({ url: 'pages/EventEditPage' });
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  private addEvent(): void {
    AppStorage.setOrCreate<number>('pendingEventId', 0);
    AppStorage.setOrCreate<number>('pendingEventDate', this.selectedDate);
    router.pushUrl({ url: 'pages/EventEditPage' });
  }

  // ---------- UI ----------
  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.header()
        this.modeTabs()
        if (this.mode === 'month') {
          this.monthBody()
        } else if (this.mode === 'week') {
          this.weekBody()
        } else if (this.mode === 'todo') {
          this.todoBody()
        } else {
          this.agendaBody()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      // ≡ 下拉菜单覆盖层（全屏遮罩 + 菜单卡片）
      if (this.menuOpen) {
        this.dropdownOverlay()
      }

      Button() {
        Text('＋')
          .fontSize(26)
          .fontColor($r('app.color.button_text'))
          .fontWeight(FontWeight.Medium)
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor($r('app.color.brand'))
      .shadow({ radius: 8, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 2 })
      .margin(24)
      .onClick(() => {
        this.addEvent();
      })

      // 未同意《隐私政策》与《用户协议》：整页门禁盖在最上层（不申请权限、不加载数据）
      if (!this.policyChecked) {
        // 读取同意状态期间的占位（极短），避免闪一下主界面或门禁页
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_bg'))
      } else if (!this.policyAgreed) {
        this.consentGate()
      }

      // 功能引导：整页覆盖层，放根 Stack 最后一层（盖住主界面与悬浮按钮）
      if (this.showTips) {
        this.tipsOverlay()
      }

      // 内置文档浏览器（《隐私政策》/《用户服务协议》）：
      // 根 Stack 最上层 —— 未同意时也能从同意门禁直接打开，看完点"✕"即刻回到门禁，无需切回应用。
      if (this.showDoc) {
        DocViewer({
          title: this.docTitle,
          url: this.docUrl,
          onClose: (): void => {
            this.showDoc = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.detailShow, this.detailSheet(), {
      height: 540,
      dragBar: true,
      showClose: false, // 关闭按钮自绘在标题行右侧，避免系统按钮压住徽标
      backgroundColor: $r('app.color.page_bg')
    })
  }

  /**
   * 首启隐私政策同意门禁（整页渲染，不用弹窗 —— 弹窗在本环境实测无法弹出）。
   * AGC 要求：明确同意前不得申请权限、不得收集/处理个人信息，故未同意时整页挡住主界面。
   */
  @Builder
  consentGate() {
    Column({ space: 14 }) {
      Text('隐私政策与用户协议')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ top: 40 })
      Text('欢迎使用「同步日历」。在使用前，请阅读并同意以下条款。')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('我们不会保存你的日程与账号数据：日历仅在你的设备与你自己填写的 CalDAV 服务器之间同步；位置信息仅在你点击“导航”时用于调用第三方地图，不会上传。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Button('《隐私政策》')
        .width('100%')
        .fontSize(14)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.brand'))
        .onClick(() => {
          this.openDoc(AppSettings.PRIVACY_TITLE, AppSettings.PRIVACY_URL);
        })
      Button('《用户服务协议》')
        .width('100%')
        .fontSize(14)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.brand'))
        .onClick(() => {
          this.openDoc(AppSettings.AGREEMENT_TITLE, AppSettings.AGREEMENT_URL);
        })
      Blank()
      Text('点击“同意并继续”，即表示你已阅读并同意上述两份文件。')
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
      Row({ space: 10 }) {
        Button('不同意并退出')
          .fontSize(15)
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            this.rejectPolicy();
          })
        Button('同意并继续')
          .fontSize(15)
          .layoutWeight(1)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.acceptPolicy();
          })
      }
      .width('100%')
      .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 12 })
    .backgroundColor($r('app.color.page_bg'))
  }

  /**
   * 首启功能引导：整页覆盖层（半透明遮罩 + 底部卡片），由 TipsPanel 提供 Swiper 三页与
   * 左下"上一步" / 右下"下一步"。
   * 用页面内容渲染而非 bindSheet/CustomDialog —— 本环境从"启动时的异步回调"里弹出系统弹层不可靠
   * （详见 MEMORY：CustomDialogController 静默失败；bindSheet 同样实测弹不出来）。
   */
  @Builder
  tipsOverlay() {
    Column() {
      // 上部留白：露出被遮罩压暗的主界面，制造"从下方弹出"的层次（点空白处也可关闭）
      Column() {
      }
      .width('100%')
      .layoutWeight(1)
      .onClick((): void => {
        this.hideTips();
      })

      // 底部引导卡片
      Column() {
        // 右上角关闭
        Row() {
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.text_hint'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick((): void => {
              this.hideTips();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })

        Column() {
          TipsPanel({ onClose: (): void => { this.hideTips(); } })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('70%')
      .backgroundColor($r('app.color.page_bg'))
      .borderRadius({ topLeft: 20, topRight: 20 })
      .clip(true)
      .shadow({ radius: 16, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: -2 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      Image($r('app.media.app_icon'))
        .width(32)
        .height(32)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
      Text('同步日历')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Button('今天')
        .fontSize(12)
        .fontColor($r('app.color.brand'))
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: $r('app.color.brand'), radius: 14 })
        .height(28)
        .padding({ left: 12, right: 12 })
        .margin({ right: 8 })
        .onClick(() => {
          this.goToday();
        })
      // ≡ 菜单按钮
      Button() {
        Column({ space: 4 }) {
          Row().width(16).height(1.5).backgroundColor($r('app.color.brand')).borderRadius(1)
          Row().width(16).height(1.5).backgroundColor($r('app.color.brand')).borderRadius(1)
          Row().width(16).height(1.5).backgroundColor($r('app.color.brand')).borderRadius(1)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: 1, color: $r('app.color.shadow_color') })
      .onClick(() => {
        this.menuOpen = !this.menuOpen;
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 12, bottom: 8 })
  }

  /** 顶部 ≡ 下拉菜单（全屏遮罩 + 右上角菜单卡片） */
  @Builder
  dropdownOverlay() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 遮罩：点击任意处关闭
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.menuOpen = false;
        })
      // 菜单卡片
      Column({ space: 2 }) {
        // 手动同步
        Row({ space: 10 }) {
          if (this.syncing) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.brand'))
          } else {
            Text('⟳')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width(16)
              .textAlign(TextAlign.Center)
          }
          Text(this.syncing ? '同步中…' : '手动同步')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        .height(40)
        .borderRadius(8)
        .padding({ left: 12 })
        .enabled(!this.syncing)
        .onClick(() => {
          this.menuOpen = false;
          this.syncAll(true);
        })
        // 账号管理
        Row({ space: 10 }) {
          Text('👤')
            .fontSize(13)
            .width(16)
            .textAlign(TextAlign.Center)
          Text('账号管理')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        .height(40)
        .borderRadius(8)
        .padding({ left: 12 })
        .onClick(() => {
          this.menuOpen = false;
          router.pushUrl({ url: 'pages/AccountsPage' });
        })
        // 设置
        Row({ space: 10 }) {
          Text('⚙')
            .fontSize(13)
            .width(16)
            .textAlign(TextAlign.Center)
          Text('设置')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        .height(40)
        .borderRadius(8)
        .padding({ left: 12 })
        .onClick(() => {
          this.menuOpen = false;
          router.pushUrl({ url: 'pages/SettingsPage' });
        })
      }
      .width(150)
      .padding(6)
      .borderRadius(12)
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: 1, color: $r('app.color.shadow_color') })
      .shadow({ radius: 12, color: '#22000000', offsetY: 4 })
      .margin({ top: 56, right: 20 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  modeTabs() {
    Row({ space: 4 }) {
      this.modeTab('month', '月')
      this.modeTab('week', '周')
      this.modeTab('agenda', '列表')
      Blank()
      if (this.mode === 'month') {
        Text(this.fmtMonthTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      } else {
        Text(this.fmtDateCn(this.selectedDate))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }

  @Builder
  modeTab(key: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.mode === key ? $r('app.color.button_text') : $r('app.color.text_secondary'))
      .width(label.length > 1 ? 48 : 36)
      .height(28)
      .textAlign(TextAlign.Center)
      .borderRadius(14)
      .backgroundColor(this.mode === key ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .onClick(() => {
        this.handleModeSwitch(key);
      })
  }

  /** 视图切换：进入列表视图时按需加载（今天整天 ~ 未来2年，昨天之前已结束的不显示）
   *  切换带转场动画：按视图顺序决定"前进/后退"方向 */
  private async handleModeSwitch(key: string): Promise<void> {
    if (key !== this.mode) {
      this.navDir = VIEW_ORDER.indexOf(key) > VIEW_ORDER.indexOf(this.mode) ? 1 : -1;
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, (): void => {
        this.mode = key;
      });
    }
    if (key === 'agenda') {
      await this.ensureAgendaData();
      this.scrollAgendaToNow();
    }
  }

  /** 带转场动画切换视图（手势用）：只处理 月↔周 */
  private switchModeAnimated(target: string): void {
    if (this.mode === target) {
      return;
    }
    this.navDir = VIEW_ORDER.indexOf(target) > VIEW_ORDER.indexOf(this.mode) ? 1 : -1;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, (): void => {
      this.mode = target;
    });
  }

  /** 视图内容转场：前进时旧内容上移淡出、新内容自下而上淡入；后退则方向相反 */
  private modeTransition(): TransitionEffect {
    const fwd: boolean = this.navDir >= 0;
    const appear: TransitionEffect = TransitionEffect.OPACITY.combine(
      TransitionEffect.translate({ y: fwd ? 48 : -48 }));
    const disappear: TransitionEffect = TransitionEffect.OPACITY.combine(
      TransitionEffect.translate({ y: fwd ? -48 : 48 }));
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /** 判定"上滑"：兼容 angle 的 -180~180 与 0~360 两种取值区间 */
  private isSwipeUp(event: GestureEvent): boolean {
    const a: number = event.angle;
    if (a >= -135 && a <= 135) {
      return a < 0;
    }
    return a > 0;
  }

  /** 判定"左滑"（→ 前进/下一天/下一周） */
  private isSwipeLeft(event: GestureEvent): boolean {
    return Math.abs(event.angle) > 90;
  }

  /** 周视图：日程区左右滑 → 按天切换（一次 1 天）；跨月时重载该月数据 */
  private switchDay(delta: number): void {
    this.selectedDate += delta * 86400000;
    const d = new Date(this.selectedDate);
    if (d.getFullYear() !== this.displayYear || d.getMonth() !== this.displayMonth) {
      this.displayYear = d.getFullYear();
      this.displayMonth = d.getMonth();
      this.reloadEvents();
    }
  }

  private async ensureAgendaData(): Promise<void> {
    if (!this.agendaStale) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.loading = true;
    const now: number = Date.now();
    const today: number = this.startOfDay(now);
    // 只从"今天"开始显示：不再回看过去的日期
    const start: number = today;
    const end: number = now + 730 * 86400000;
    try {
      const raw: DisplayEvent[] = await CalendarDataService.loadEvents(context, start, end, this.sources);
      // 保留：今天还没结束的（含进行中）+ 未来全部
      this.agendaEvents = raw.filter((e: DisplayEvent): boolean => e.endTime >= start);
      this.agendaTimelines = this.buildAgendaTimelines(this.agendaEvents);
      this.agendaStale = false;
      LogUtil.write(`列表视图加载：${this.agendaEvents.length} 条（今天~未来2年），时间轴 ${this.agendaTimelines.length} 天`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`列表视图加载失败：${e.message}`);
    }
    this.loading = false;
    this.scrollAgendaToNow();
  }

  /** 列表视图加载完成后定位到**今天当前时刻（红线）**，并让红线大致落在屏幕中间。
   *  不再用 scrollToIndex（那只会对齐到卡片顶部，看到的是最早那条日程）。
   *  做法：累加今天之前各天卡片高度（用与渲染一致的公式算），再加上红线在"今天"卡片内的偏移，
   *  最后减半屏高度 → 红线居中。 */
  private scrollAgendaToNow(): void {
    if (this.mode !== 'agenda') {
      return;
    }
    this.agendaScrollPending = true;
    setTimeout((): void => {
      this.doAgendaScroll();
    }, 80);
  }

  /** 真正执行滚动：视口高度还没实测到时先用估算值滚一次，等 onAreaChange 拿到真实高度再校正 */
  private doAgendaScroll(): void {
    if (!this.agendaScrollPending) {
      return;
    }
    const idx: number = this.agendaTimelines.findIndex((d: AgendaTimelineGroup): boolean => d.isToday);
    if (idx < 0) {
      // 今天没有日程：直接回到列表顶部
      this.agendaScroller.scrollToIndex(0);
      this.agendaScrollPending = false;
      return;
    }
    // List 顶部 padding 6 + 每项之间 space 10
    let cardTop: number = 6;
    for (let i = 0; i < idx; i++) {
      cardTop = cardTop + this.agendaCardH(this.agendaTimelines[i]) + 10;
    }
    const d: AgendaTimelineGroup = this.agendaTimelines[idx];
    const vp: number = this.agendaViewportH > 0 ? this.agendaViewportH : 600;
    // 今天定时日程已全部结束 → 红线不显示，直接定位到今天卡片顶部（不再按"当前时刻"居中）
    let target: number = cardTop - 6;
    if (!TimelineUtil.allTimedEnded(d.timeline.blocks, this.nowMs)) {
      // 卡片内：padding 10 + 日期头 + space 6 + 全天区 + 红线在视窗内的偏移
      let y: number = cardTop + 10 + this.agendaHeaderH() + 6 + this.agendaAllDayH(d.timeline);
      const rg: ViewRange = TimelineUtil.viewRange(d.timeline.blocks, true, this.nowMs);
      y = y + (TimelineUtil.nowRatio(this.nowMs) - rg.startHour / 24) * TimelineUtil.HOUR_UNIT * 24;
      target = y - vp / 2;
    }
    this.agendaScroller.scrollTo({ xOffset: 0, yOffset: target < 0 ? 0 : target });
    // 只有拿到真实视口高度后才算完成；否则等 onAreaChange 再校正一次
    if (this.agendaViewportH > 0) {
      this.agendaScrollPending = false;
    }
  }

  /** 列表某天卡片的总高度（必须与 agendaBody 里的实际布局保持一致） */
  private agendaCardH(d: AgendaTimelineGroup): number {
    // 上下 padding 10 + 日期头 + Column space 6 + 时间轴（全天区 + 视窗高）；border 画在组件内不占高
    return 10 + this.agendaHeaderH() + 6 + this.agendaTimelineH(d) + 10;
  }
  /** 日期头高度：padding top 4 + 14 号文字行高约 20 */
  private agendaHeaderH(): number {
    return 24;
  }
  /** 全天区高度：每条 26 + 间隔 4 + 底部 padding 6 */
  private agendaAllDayH(tl: DayTimeline): number {
    if (tl.allDay.length === 0) {
      return 0;
    }
    return tl.allDay.length * 26 + (tl.allDay.length - 1) * 4 + 6;
  }
  /** 某天时间轴高度 = 全天区 + 视窗小时数 × 每小时 vp
   *  （视窗的"是否并入当前小时"必须与 DayTimelineView 完全一致，否则卡片高度算错） */
  private agendaTimelineH(d: AgendaTimelineGroup): number {
    const incNow: boolean = d.isToday && !TimelineUtil.allTimedEnded(d.timeline.blocks, this.nowMs);
    const rg: ViewRange = TimelineUtil.viewRange(d.timeline.blocks, incNow, this.nowMs);
    return this.agendaAllDayH(d.timeline) + (rg.endHour - rg.startHour) * TimelineUtil.HOUR_UNIT;
  }

  /** 周条：周一到周日（周视图顶部 / 复用） */
  @Builder
  weekStrip() {
    Row({ space: 4 }) {
      ForEach(this.weekStripDays(), (cell: MonthCell) => {
        Column({ space: 2 }) {
          Text(WEEK_LABELS[(new Date(cell.dateMs).getDay() + 6) % 7])
            .fontSize(11)
            .fontColor(cell.dateMs === this.selectedDate
              ? $r('app.color.button_text') : $r('app.color.text_hint'))
          Text(String(cell.day))
            .fontSize(14)
            .fontWeight(cell.dateMs === this.selectedDate || cell.isToday
              ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(cell.dateMs === this.selectedDate
              ? $r('app.color.button_text') : $r('app.color.text_primary'))
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .borderRadius(15)
            .backgroundColor(cell.dateMs === this.selectedDate
              ? $r('app.color.selected_bg')
              : (cell.isToday ? $r('app.color.today_bg') : Color.Transparent))
          Text(cell.lunar)
            .fontSize(8)
            .fontColor($r('app.color.text_hint'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .onClick(() => {
          this.selectedDate = cell.dateMs;
        })
      }, (cell: MonthCell) => `${cell.dateMs}_${cell.dateMs === this.selectedDate}`)
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    // 上半区（周条）左右滑 → 按周切换（左滑下一周、右滑上一周）
    .gesture(
      SwipeGesture({ direction: SwipeDirection.Horizontal })
        .onAction((event: GestureEvent) => {
          this.switchWeek(this.isSwipeLeft(event) ? 1 : -1);
        })
    )
  }

  private weekStripDays(): MonthCell[] {
    // 以选中日期所在周（周一起）的 7 天
    const sel = new Date(this.selectedDate);
    const offset: number = (sel.getDay() + 6) % 7;
    const weekStart: number = this.selectedDate - offset * 86400000;
    const todayStart: number = this.startOfDay(Date.now());
    const cells: MonthCell[] = [];
    for (let i = 0; i < 7; i++) {
      const dateMs: number = weekStart + i * 86400000;
      const cell = new MonthCell();
      cell.dateMs = dateMs;
      cell.day = new Date(dateMs).getDate();
      cell.isToday = dateMs === todayStart;
      cell.lunar = LunarUtil.lunarDayText(dateMs);
      cells.push(cell);
    }
    return cells;
  }

  @Builder
  monthBody() {
    if (this.isLandscape) {
      // 横屏（平板适配）：左右双栏——左侧月历，右侧当日日程
      Row() {
        Column() {
          this.monthWeekHeader()
          this.monthSwiper()
        }
        .layoutWeight(3)
        .height('100%')

        Divider()
          .vertical(true)
          .height('92%')
          .strokeWidth(1)
          .color($r('app.color.shadow_color'))

        Column() {
          this.dayPanelHeader()
          this.eventList()
        }
        .layoutWeight(2)
        .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .transition(this.modeTransition())
    } else {
      // 竖屏：月历在上、当日日程在下（保持原布局）
      Column() {
        this.monthWeekHeader()
        this.monthSwiper()
        this.dayPanelHeader()
        this.eventList()
      }
      .width('100%')
      .layoutWeight(1)
      .transition(this.modeTransition())
    }
  }

  /** 月视图星期表头 */
  @Builder
  monthWeekHeader() {
    Row() {
      ForEach(WEEK_LABELS, (w: string) => {
        Text(w)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
      }, (w: string) => w)
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
  }

  /** 月视图三页 Swiper（横屏时占满剩余高度并均分每周行，竖屏保持自然高度） */
  @Builder
  monthSwiper() {
    Swiper(this.swiperController) {
      ForEach(this.monthPages, (cells: MonthCell[]) => {
        Column({ space: 2 }) {
          ForEach(this.chunkCells(cells), (week: MonthCell[], idx: number) => {
            Row({ space: 2 }) {
              ForEach(week, (cell: MonthCell) => {
                this.dayCell(cell)
              }, (cell: MonthCell) => `${cell.dateMs}_${cell.dateMs === this.selectedDate}`)
            }
            .width('100%')
            .layoutWeight(this.isLandscape ? 1 : 0)
          }, (week: MonthCell[], idx: number) => String(idx))
        }
        .width('100%')
        // 注意：不要给页面设百分比高度——竖屏时 Swiper 是自然高度，
        // 子组件 height('100%') 对 auto 父容器解析为 0，整月网格会塌陷
      }, (cells: MonthCell[]) => String(cells[0].dateMs))
    }
    .index(1)
    .loop(false)
    .indicator(false)
    .width('100%')
    .layoutWeight(this.isLandscape ? 1 : 0)
    .onChange((index: number) => {
      this.handleSwiperChange(index);
    })
    // 上划月份网格 → 切到周视图（带动画）；水平滑动仍由 Swiper 负责翻月
    .gesture(
      SwipeGesture({ direction: SwipeDirection.Vertical })
        .onAction((event: GestureEvent) => {
          if (this.isSwipeUp(event)) {
            this.switchModeAnimated('week');
          }
        })
    )
  }

  /** 当日日程标题行（长按可触发重复日程调试） */
  @Builder
  dayPanelHeader() {
    Row({ space: 8 }) {
      Text(this.fmtDateCn(this.selectedDate))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(this.fmtMonthTitle())
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6 })
    .gesture(LongPressGesture().onAction(() => {
      this.showOccurrenceDebug(this.selectedDate);
    }))
  }

  /** 调试（临时）：长按月视图日期标题，检查重复日程在该日的首次发生情况 */
  private async showOccurrenceDebug(dateMs: number): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      const dayStart: number = this.startOfDay(dateMs);
      const dayEnd: number = dayStart + 86400000;
      const winStart: number = dayStart - 365 * 86400000;
      const winEnd: number = dayEnd + 365 * 86400000;
      const rows: LocalEvent[] = await EventDb.queryRange(context, winStart, winEnd);
      const sources = await CalendarDataService.loadSources(context);
      const visibleKeys: string[] = sources.filter((s: CalSource): boolean => s.visible)
        .map((s: CalSource): string => s.calKey);
      const masters = new Map<string, LocalEvent>();
      const overrides = new Map<string, LocalEvent[]>();
      for (const r of rows) {
        if (r.rrule !== '') {
          masters.set(r.uid, r);
        } else {
          const arr = overrides.get(r.uid);
          if (arr === undefined) {
            overrides.set(r.uid, [r]);
          } else {
            arr.push(r);
          }
        }
      }
      const p = (n: number): string => (n < 10 ? '0' + n : String(n));
      const fmt = (ms: number): string => {
        const d = new Date(ms);
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
      };
      const lines: string[] = [`调试 ${this.fmtDateCn(dateMs)}`, `visibleKeys=${visibleKeys.join(',')}`];
      let idx: number = 0;
      let netChecked: boolean = false;
      for (const m of masters.values()) {
        if (idx >= 6) {
          lines.push('…（更多系列省略）');
          break;
        }
        // 只列出与该日期相关的系列：主行开始日在该日±90天内，或展开命中该日
        const exNums: number[] = [];
        if (m.exdate !== '') {
          for (const raw of m.exdate.split(';')) {
            const t = IcsUtil.parseTime(raw, !raw.includes('T'));
            if (t !== null) {
              exNums.push(t.time);
            }
          }
        }
        const occs: number[] = RruleUtil.expand(m.rrule, m.startTime, m.startTime, winEnd, exNums, 400);
        const hitsDay: boolean = occs.some((o: number): boolean => o >= dayStart && o < dayEnd);
        const nearStart: boolean = Math.abs(m.startTime - dayStart) <= 90 * 86400000;
        if (!hitsDay && !nearStart) {
          continue;
        }
        idx++;
        const hasFirst: boolean = occs.some((o: number): boolean => o === m.startTime);
        const mVis: boolean = visibleKeys.includes(m.calKey);
        lines.push(`◇ ${m.title}`);
        lines.push(`  uid=${m.uid.substring(0, 8)} 主行=${fmt(m.startTime)} rec=${m.recurring ? 1 : 0} calKey=${m.calKey} vis=${mVis ? 1 : 0} dirty=${m.dirty ? 1 : 0}`);
        lines.push(`  rrule=${m.rrule === '' ? '(空!)' : m.rrule}`);
        lines.push(`  exdate=${m.exdate === '' ? '无' : m.exdate}`);
        lines.push(`  展开条数=${occs.length} 含首次=${hasFirst ? '是' : '否'} 首次=${occs.length > 0 ? fmt(occs[0]) : '无'} 该日发生=${hitsDay ? '是' : '否'}`);
        lines.push(`  数据库提醒=${m.reminder}分钟 DB同UID行数=${rows.filter((r: LocalEvent): boolean => r.uid === m.uid).length}`);
        // 网络诊断（仅第一个命中该日的系列）：GET 服务器原始 ICS，看 VALARM 是否还在
        if (hitsDay && !netChecked) {
          netChecked = true;
          try {
            const accounts2: DavAccount[] = await AccountStore.loadAll(context);
            const acc2 = accounts2.find((a: DavAccount): boolean => a.calendarHrefs.includes(m.href));
            if (acc2 !== undefined) {
              const auth2: string = DavClient.authHeader(acc2.username, acc2.password);
              const url: string = m.href.endsWith('/')
                ? m.href + m.remotePath : `${m.href}/${m.remotePath}`;
              const raw: string = await DavClient.getRaw(url, auth2);
              const upper: string = raw.toUpperCase();
              const trigIdx: number = upper.indexOf('TRIGGER');
              lines.push(`  服务器ICS：${raw.length}字节 VALARM=${upper.includes('BEGIN:VALARM') ? '有' : '无'}` +
                (trigIdx >= 0 ? ` TRIGGER=${raw.substring(trigIdx, trigIdx + 40).replace(/\r?\n/g, ' ')}` : ''));
              // 用解析函数当场重解析这份 ICS，验证解析是否丢提醒
              const reParsed: RemoteEvent[] = IcsUtil.parse(raw);
              const hit = reParsed.find((p: RemoteEvent): boolean => p.uid === m.uid);
              lines.push(`  重新解析：提醒=${hit !== undefined ? hit.reminder : '?'}分钟 rec=${hit !== undefined ? (hit.recurring ? 1 : 0) : '?'} rrule=${hit !== undefined && hit.rrule !== '' ? hit.rrule : '无'}`);
              // 模拟同步路径：REPORT 拉取（与 SyncEngine 完全一致）再解析
              try {
                const repItems: RemoteItem[] = await DavClient.reportCalendar(m.href, auth2);
                const repIt = repItems.find((x: RemoteItem): boolean => x.ics.includes(m.uid));
                if (repIt !== undefined) {
                  const rp: RemoteEvent[] = IcsUtil.parse(repIt.ics);
                  const hit2 = rp.find((p: RemoteEvent): boolean => p.uid === m.uid);
                  lines.push(`  REPORT重解析：提醒=${hit2 !== undefined ? hit2.reminder : '?'}分钟 VALARM=${repIt.ics.toUpperCase().includes('BEGIN:VALARM') ? '有' : '无'} 字节=${repIt.ics.length}`);
                  lines.push(`  etag对比：DB=${m.etag === '' ? '(空)' : m.etag.substring(0, 16)} REPORT=${repIt.etag === '' ? '(空)' : repIt.etag.substring(0, 16)}`);
                } else {
                  lines.push(`  REPORT重解析：未找到该UID（共${repItems.length}条）`);
                }
              } catch (err2) {
                lines.push('  REPORT拉取失败：同步可能一直在此失败！');
              }
              lines.push(`  ICS原文：${raw.substring(0, 380).replace(/\r?\n/g, ' ⏎ ')}`);
            }
          } catch (err) {
            lines.push('  服务器ICS获取失败(网络)');
          }
        }
        const ovs = overrides.get(m.uid) ?? [];
        if (ovs.length === 0) {
          lines.push('  覆盖实例: 无');
        } else {
          for (const o of ovs.slice(0, 5)) {
            const oVis: boolean = visibleKeys.includes(o.calKey);
            lines.push(`  覆盖: ${fmt(o.startTime)}~${fmt(o.endTime)} rec=${o.recurring ? 1 : 0} calKey=${o.calKey} vis=${oVis ? 1 : 0} dirty=${o.dirty ? 1 : 0} 提醒=${o.reminder}分钟`);
          }
          if (ovs.length > 5) {
            lines.push(`  覆盖共 ${ovs.length} 条`);
          }
        }
      }
      if (lines.length <= 2) {
        lines.push('（该日期附近没有重复主事件）');
      }
      // 当日非重复日程（含覆盖实例）：核对 DB 中实际存储的提醒值，定位提醒丢失环节
      const plain: LocalEvent[] = rows.filter((r: LocalEvent): boolean =>
        r.rrule === '' && r.startTime < dayEnd && r.endTime >= dayStart);
      if (plain.length > 0) {
        lines.push(`—— 当日非重复日程 ${plain.length} 条 ——`);
        for (const r of plain.slice(0, 8)) {
          lines.push(`◇ ${r.title === '' ? '(无标题)' : r.title} 提醒=${r.reminder}分钟 rec=${r.recurring ? 1 : 0} calKey=${r.calKey}`);
        }
        if (plain.length > 8) {
          lines.push(`…（其余 ${plain.length - 8} 条省略）`);
        }
      }
      const text: string = lines.join('\n').substring(0, 3500);
      this.getUIContext().showAlertDialog({
        title: '重复日程调试',
        message: text,
        autoCancel: true,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: '复制',
          action: (): void => {
            const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
            pasteboard.getSystemPasteboard().setData(data);
          }
        },
        secondaryButton: {
          value: '关闭',
          action: (): void => {}
        }
      });
    } catch (err) {
      // 调试失败不影响主流程
    }
  }

  /** 周视图整周切换（左滑下一周、右滑上一周）；跨月时自动重载数据 */
  private switchWeek(delta: number): void {
    this.selectedDate += delta * 7 * 86400000;
    const d = new Date(this.selectedDate);
    if (d.getFullYear() !== this.displayYear || d.getMonth() !== this.displayMonth) {
      this.displayYear = d.getFullYear();
      this.displayMonth = d.getMonth();
      this.reloadEvents();
    }
  }

  /** 回到本周（含今天） */
  private goThisWeek(): void {
    this.selectedDate = this.startOfDay(Date.now());
  }

  @Builder
  weekBody() {
    if (this.isLandscape) {
      // 横屏（平板适配）：左侧一周日期，右侧选中日日程
      Row() {
        Column() {
          Text('本周')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 4, bottom: 8 })
            .onClick(() => {
              this.goThisWeek();
            })
          this.weekStripVertical()
        }
        .layoutWeight(1)
        .height('100%')
        // 左栏整块（"本周"行 + 一周日期）下滑 → 回到月视图（带动画）
        .gesture(
          SwipeGesture({ direction: SwipeDirection.Vertical })
            .onAction((event: GestureEvent) => {
              if (!this.isSwipeUp(event)) {
                this.switchModeAnimated('month');
              }
            })
        )

        Divider()
          .vertical(true)
          .height('92%')
          .strokeWidth(1)
          .color($r('app.color.shadow_color'))

        Column() {
          this.dayPanelHeader()
          this.eventList()
        }
        .layoutWeight(2)
        .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .transition(this.modeTransition())
    } else {
      // 竖屏：保持原上下结构
      Column() {
        // 顶部整块（"本周"行 + 一周七天 + 日期行）下滑 → 回到月视图（带动画）
        Column() {
          Row({ space: 16 }) {
            Blank()
            Text('本周')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .onClick(() => {
                this.goThisWeek();
              })
            Blank()
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 4, bottom: 4 })

          this.weekStrip()

          Row({ space: 8 }) {
            Text(this.fmtDateCn(this.selectedDate))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
            Blank()
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 8 })
        }
        .width('100%')
        .gesture(
          SwipeGesture({ direction: SwipeDirection.Vertical })
            .onAction((event: GestureEvent) => {
              if (!this.isSwipeUp(event)) {
                this.switchModeAnimated('month');
              }
            })
        )

        this.eventList()
      }
      .width('100%')
      .layoutWeight(1)
      .transition(this.modeTransition())
    }
  }

  /** 周视图竖排日期条（横屏左栏：周一~周日从上到下，可上下滚动） */
  @Builder
  weekStripVertical() {
    Scroll() {
      Column({ space: 2 }) {
        ForEach(this.weekStripDays(), (cell: MonthCell) => {
          Row({ space: 10 }) {
            Text(WEEK_LABELS[(new Date(cell.dateMs).getDay() + 6) % 7])
              .fontSize(12)
              .fontColor(cell.dateMs === this.selectedDate
                ? $r('app.color.text_secondary') : $r('app.color.text_hint'))
              .width(18)
              .textAlign(TextAlign.Center)
            Text(String(cell.day))
              .fontSize(15)
              .fontWeight(cell.dateMs === this.selectedDate || cell.isToday
                ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(cell.dateMs === this.selectedDate
                ? $r('app.color.button_text') : $r('app.color.text_primary'))
              .width(32)
              .height(32)
              .textAlign(TextAlign.Center)
              .borderRadius(16)
              .backgroundColor(cell.dateMs === this.selectedDate
                ? $r('app.color.selected_bg')
                : (cell.isToday ? $r('app.color.today_bg') : Color.Transparent))
          }
          .width('100%')
          .height(44)
          .borderRadius(10)
          .padding({ left: 10 })
          .backgroundColor(cell.dateMs === this.selectedDate
            ? $r('app.color.chip_off_bg') : Color.Transparent)
          .onClick(() => {
            this.selectedDate = cell.dateMs;
          })
        }, (cell: MonthCell) => `${cell.dateMs}_${cell.dateMs === this.selectedDate}`)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 2, bottom: 8 })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .width('100%')
    .layoutWeight(1)
    // 上半区（左侧周条）左右滑 → 按周切换
    .gesture(
      SwipeGesture({ direction: SwipeDirection.Horizontal })
        .onAction((event: GestureEvent) => {
          this.switchWeek(this.isSwipeLeft(event) ? 1 : -1);
        })
    )
  }

  /** 单日日程展示区（周视图 / 月视图下方共用）。
   *  - timeline 模式：竖向时间轴（DayTimelineView，带"当前时间红线"）。
   *  - list 模式：按"行"平铺（eventRow），无时间刻度 → 不画红线，进行中改用文字标记。 */
  @Builder
  eventList() {
    if (this.displayStyle === 'list') {
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.eventsOfDate(this.selectedDate), (e: DisplayEvent) => {
            this.eventRow(e, this.isEventNow(e, this.selectedDate === this.startOfDay(this.nowMs)))
          }, (e: DisplayEvent) => `${e.isSystem ? 's' : 'l'}${e.id}_${e.startTime}_${e.title}`)
          if (this.eventsOfDate(this.selectedDate).length === 0 && !this.loading) {
            Text('当天没有日程')
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(20)
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 24 })
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      .gesture(
        SwipeGesture({ direction: SwipeDirection.Horizontal })
          .onAction((event: GestureEvent) => {
            if (this.mode !== 'week') {
              return;
            }
            this.switchDay(this.isSwipeLeft(event) ? 1 : -1);
          })
      )
    } else {
      Column() {
        DayTimelineView({
          timeline: this.dayTimeline,
          nowMs: this.nowMs,
          showNowLine: this.selectedDate === this.startOfDay(this.nowMs),
          scrollable: true,
          onPick: (e: DisplayEvent): void => this.openEvent(e)
        })
        if (!this.dayTimeline.hasTimed && this.dayTimeline.allDay.length === 0 && !this.loading) {
          Text('当天没有日程')
            .fontSize(13)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(20)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 16, top: 4, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
      // 下半区（日程展示区）左右滑 → 按天切换（一次 1 天），仅周视图生效
      .gesture(
        SwipeGesture({ direction: SwipeDirection.Horizontal })
          .onAction((event: GestureEvent) => {
            if (this.mode !== 'week') {
              return;
            }
            this.switchDay(this.isSwipeLeft(event) ? 1 : -1);
          })
      )
    }
  }

  @Builder
  agendaBody() {
    if (this.displayStyle === 'list') {
      // 列表模式：按日分组，每天一条日期头 + 该日若干"行"卡片；不画红线，进行中改用文字标记
      List({ space: 6, scroller: this.agendaScroller }) {
        ListItem() {
          Row({ space: 8 }) {
            if (this.loading) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color($r('app.color.brand'))
            }
            Text(this.loading ? '正在加载全部日程…' : `共 ${this.agendaEvents.length} 条`)
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        }

        ForEach(this.agendaTimelines, (day: AgendaTimelineGroup) => {
          ListItem() {
            Text(day.label)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(day.isToday ? $r('app.color.brand') : $r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 6, bottom: 2 })
          }
          ForEach(this.dayEvents(day), (e: DisplayEvent) => {
            ListItem() {
              this.eventRow(e, this.isEventNow(e, day.isToday))
            }
            .width('100%')
          }, (e: DisplayEvent) => `${e.isSystem ? 's' : 'l'}${e.id}_${e.startTime}_${e.title}`)
        }, (day: AgendaTimelineGroup) => `day_${day.dateMs}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 20, right: 20, top: 6, bottom: 24 })
      .cachedCount(8)
      .onAreaChange((oldVal: Area, newVal: Area): void => {
        const h: number = Number(newVal.height);
        if (h > 0 && (h - this.agendaViewportH > 1 || h - this.agendaViewportH < -1)) {
          this.agendaViewportH = h;
          if (this.agendaScrollPending) {
            this.doAgendaScroll();
          }
        }
      })
    } else {
      // 时间轴模式：每天一条竖向时间轴（0-23 格，色块按时间平铺，冲突平分宽度；今天画红线）
      List({ space: 10, scroller: this.agendaScroller }) {
        ListItem() {
          Row({ space: 8 }) {
            if (this.loading) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color($r('app.color.brand'))
            }
            Text(this.loading ? '正在加载全部日程…' : `共 ${this.agendaEvents.length} 条` +
              `，${this.agendaTimelines.length} 天`)
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        }

        // 每一天：日期头 + 该日一条竖向时间轴（0-23 格，色块按时间平铺，冲突平分宽度）
        ForEach(this.agendaTimelines, (day: AgendaTimelineGroup) => {
          ListItem() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(day.label)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(day.isToday ? $r('app.color.brand') : $r('app.color.text_primary'))
                if (day.isToday) {
                  Text('今天')
                    .fontSize(10)
                    .fontColor($r('app.color.button_text'))
                    .backgroundColor($r('app.color.brand'))
                    .borderRadius(6)
                    .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                }
                Blank()
                Text(`${day.timeline.blocks.length + day.timeline.allDay.length} 条`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
              }
              .width('100%')
              .padding({ top: 4 })

              DayTimelineView({
                timeline: day.timeline,
                nowMs: this.nowMs,
                showNowLine: day.isToday,
                scrollable: false,
                onPick: (e: DisplayEvent): void => this.openEvent(e)
              })
            }
            .width('100%')
            .padding(10)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.shadow_color') })
          }
        }, (day: AgendaTimelineGroup) => `day_${day.dateMs}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 12, right: 12, top: 6, bottom: 24 })
      .cachedCount(4)
      .onAreaChange((oldVal: Area, newVal: Area): void => {
        const h: number = Number(newVal.height);
        if (h > 0 && (h - this.agendaViewportH > 1 || h - this.agendaViewportH < -1)) {
          this.agendaViewportH = h;
          if (this.agendaScrollPending) {
            this.doAgendaScroll();
          }
        }
      })
    }
  }

  /** 日程"行"卡片（列表模式 / 卡片共用）：左侧 4px 颜色条 + 标题 + 时间/地点 + 所属日历本。
   *  isNow=true 时以红色强调并打"● 进行中"标记（替代时间轴里的"当前时间红线"）。 */
  @Builder
  eventRow(e: DisplayEvent, isNow: boolean = false) {
    Row({ space: 10 }) {
      Column()
        .width(4)
        .height(38)
        .borderRadius(2)
        .backgroundColor(isNow ? '#FF3B30' : e.color)
      Column({ space: 3 }) {
        Text(e.title === '' ? '(无标题)' : e.title)
          .fontSize(15)
          .fontColor(isNow ? '#FF3B30' : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(e.isAllDay || this.spansDays(e)
            ? '全天' : `${this.fmtTime(e.startTime)} - ${this.fmtTime(e.endTime)}`)
            .fontSize(12)
            .fontColor(isNow ? '#FF3B30' : $r('app.color.text_secondary'))
          if (e.recurring) {
            Text('↻ 重复')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor($r('app.color.chip_off_bg'))
          }
          if (isNow) {
            Text('● 进行中')
              .fontSize(10)
              .fontColor('#FF3B30')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor('#FFECEA')
          }
        }
        if (e.location !== '') {
          Row({ space: 4 }) {
            Text('📍')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
            Text(e.location)
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (e.isSystem) {
        Text('系统')
          .fontSize(10)
          .fontColor($r('app.color.text_hint'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor($r('app.color.chip_off_bg'))
      }
      // 所属日历本：最右侧、垂直居中，颜色同日历本；只读日历本加删除线标识
      if (e.calName !== '') {
        Text(e.calName)
          .fontSize(11)
          .fontColor(e.color)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '30%' })
          .decoration({ type: e.writable ? TextDecorationType.None : TextDecorationType.LineThrough })
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding(10)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 1, color: $r('app.color.shadow_color') })
    .onClick(() => {
      this.openEvent(e);
    })
  }

  /** 某条日程此刻是否"正在进行"。仅当天、且为按时段（非全天/非跨天）且 now 落在 [start,end) 才算。
   *  列表模式用这个替代时间轴的"当前时间红线"：红条 + "● 进行中"文字标记。 */
  private isEventNow(e: DisplayEvent, isToday: boolean): boolean {
    if (!isToday) {
      return false;
    }
    if (e.isAllDay || this.spansDays(e)) {
      return false;
    }
    return e.startTime <= this.nowMs && this.nowMs < e.endTime;
  }

  /** 取某天时间轴里要按"行"平铺展示的全部日程（全天 + 时段色块对应事件）。 */
  private dayEvents(day: AgendaTimelineGroup): DisplayEvent[] {
    const arr: DisplayEvent[] = [];
    for (const a of day.timeline.allDay) {
      arr.push(a);
    }
    for (const b of day.timeline.blocks) {
      if (b.ev !== null) {
        arr.push(b.ev);
      }
    }
    return arr;
  }

  /** 列表视图：把每天的分组转成"一天一条竖向时间轴"
   *  多日/跨天日程会**展开到它覆盖的每一天**（起始日记为跨天，中间日整天），
   *  确保列表里每天的数据完整，而不是只挂在第一天。 */
  private buildAgendaTimelines(events: DisplayEvent[]): AgendaTimelineGroup[] {
    const today: number = this.startOfDay(Date.now());
    const map: Map<number, DisplayEvent[]> = new Map();
    const push = (key: number, e: DisplayEvent): void => {
      // 列表视图只显示"今天及以后"：跨天日程展开时也不往前补日期
      if (key < today) {
        return;
      }
      let arr: DisplayEvent[] | undefined = map.get(key);
      if (arr === undefined) {
        arr = [];
        map.set(key, arr);
      }
      arr.push(e);
    };
    for (const e of events) {
      const sDay: number = this.startOfDay(e.startTime);
      let eDay: number = this.startOfDay(e.endTime);
      // 结束时刻恰好在 0 点 → 实际只到前一天（对齐常见日历约定）
      if (e.endTime <= eDay && eDay > sDay) {
        eDay = eDay - 86400000;
      }
      const spans: boolean = eDay > sDay;
      if (!spans) {
        push(sDay, e);
        continue;
      }
      // 跨多天：逐天挂上（中间日同样展示，避免"这天什么都没有"）
      const days: number = Math.round((eDay - sDay) / 86400000);
      const maxDays: number = 60; // 防御：异常超长日程最多展开 60 天
      const n: number = days > maxDays ? maxDays : days;
      for (let i = 0; i <= n; i++) {
        push(sDay + i * 86400000, e);
      }
    }
    const keys: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    const out: AgendaTimelineGroup[] = [];
    for (const key of keys) {
      const g = new AgendaTimelineGroup();
      g.dateMs = key;
      g.label = key === today ? '今天' : this.fmtDateCn(key);
      g.isToday = key === today;
      const tl: DayTimeline = TimelineUtil.build(map.get(key) ?? [], key);
      TimelineUtil.markNow(tl.blocks, this.nowMs);
      g.timeline = tl;
      out.push(g);
    }
    return out;
  }

  // ---------- 待办（VTODO） ----------
  private colorOfCal(key: string): string {
    const found = this.sources.find((s: CalSource): boolean => s.calKey === key);
    return found !== undefined ? found.color : '#9AA0A6';
  }

  private fmtDue(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  /** 待办页：与日历视图完全分开，只读展示服务器端 VTODO */
  @Builder
  todoBody() {
    Scroll() {
      Column({ space: 8 }) {
        Text('未完成')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        ForEach(this.todos.filter((t: DisplayEvent): boolean => !t.completed), (t: DisplayEvent) => {
          this.todoRow(t)
        }, (t: DisplayEvent) => `t${t.id}_${t.completed}`)
        if (this.todos.some((t: DisplayEvent): boolean => t.completed)) {
          Text('已完成')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 10 })
          ForEach(this.todos.filter((t: DisplayEvent): boolean => t.completed), (t: DisplayEvent) => {
            this.todoRow(t)
          }, (t: DisplayEvent) => `t${t.id}_${t.completed}`)
        }
        if (this.todos.length === 0 && !this.loading) {
          Column({ space: 8 }) {
            Text('☑')
              .fontSize(34)
              .fontColor($r('app.color.text_hint'))
            Text('没有待办事项')
              .fontSize(14)
              .fontColor($r('app.color.text_hint'))
            Text('CalDAV 服务器日历本中的待办（VTODO）会同步显示在这里')
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(32)
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
      .constraintSize({ minHeight: '100%' })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
  }

  @Builder
  todoRow(t: DisplayEvent) {
    Row({ space: 10 }) {
      // 勾选框（颜色跟随日历本）
      if (t.completed) {
        Text('✓')
          .fontSize(13)
          .fontColor($r('app.color.button_text'))
          .width(22)
          .height(22)
          .textAlign(TextAlign.Center)
          .borderRadius(11)
          .backgroundColor(this.colorOfCal(t.calKey))
      } else {
        Text('')
          .width(22)
          .height(22)
          .borderRadius(11)
          .border({ width: 2, color: this.colorOfCal(t.calKey) })
      }
      Column({ space: 3 }) {
        Text(t.title === '' ? '(无标题待办)' : t.title)
          .fontSize(15)
          .fontColor(t.completed ? $r('app.color.text_hint') : $r('app.color.text_primary'))
          .decoration({ type: t.completed ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(t.startTime > 0 ? `截止 ${this.fmtDue(t.startTime)}` : '无截止时间')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 1, color: $r('app.color.shadow_color') })
    .opacity(t.completed ? 0.7 : 1)
    .onClick(() => {
      this.getUIContext().getPromptAction()
        .showToast({ message: '待办来自服务器，请在群晖日历等源端修改' });
    })
  }

  /** 是否跨天（结束日期晚于开始日期） */
  private spansDays(e: DisplayEvent): boolean {
    return this.startOfDay(e.endTime) > this.startOfDay(e.startTime);
  }

  @Builder
  dayCell(cell: MonthCell) {
    Column({ space: 2 }) {
      Text(String(cell.day))
        .fontSize(this.isLandscape ? 12 : 13)
        .fontWeight(cell.isToday || cell.dateMs === this.selectedDate ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(!cell.inMonth
          ? $r('app.color.text_hint')
          : (cell.dateMs === this.selectedDate ? $r('app.color.button_text') : $r('app.color.text_primary')))
        .width(this.isLandscape ? 22 : 26)
        .height(this.isLandscape ? 22 : 26)
        .textAlign(TextAlign.Center)
        .borderRadius(this.isLandscape ? 11 : 13)
        .backgroundColor(cell.dateMs === this.selectedDate
          ? $r('app.color.selected_bg')
          : (cell.isToday ? $r('app.color.today_bg') : Color.Transparent))
      if (!this.isLandscape) {
        // 横屏高度有限，省略农历腾出空间
        Text(cell.lunar)
          .fontSize(8)
          .fontColor(cell.dateMs === this.selectedDate
            ? $r('app.color.text_secondary') : $r('app.color.text_hint'))
          .maxLines(1)
      }
    }
    .layoutWeight(1)
    .padding({ top: 4, bottom: 4 })
    .borderRadius(8)
    .onClick(() => {
      this.selectedDate = cell.dateMs;
      if (!cell.inMonth) {
        const d = new Date(cell.dateMs);
        this.displayYear = d.getFullYear();
        this.displayMonth = d.getMonth();
        this.rebuildPages();
        this.swiperGuard = true;
        this.swiperController.changeIndex(1, false);
      }
    })
  }

  /** 把 42 个格子按每周 7 个分组 */
  private chunkCells(cells: MonthCell[]): MonthCell[][] {
    const weeks: MonthCell[][] = [];
    for (let i = 0; i < cells.length; i += 7) {
      weeks.push(cells.slice(i, i + 7));
    }
    return weeks;
  }
}

/** 列表视图的一天：日期标签 + 该日的时间轴布局 */
class AgendaTimelineGroup {
  dateMs: number = 0;
  label: string = '';
  isToday: boolean = false;
  timeline: DayTimeline = new DayTimeline();
}

/** 日程层纵向序列中的一行：空隙 / 冲突组。整点线与红线已移到另外两层，本层不含任何"线"。
 *  topRatio~botRatio = 该行覆盖的当日比例区间（0~1，乘整日高得 vp）。 */
class TimeRow {
  kind: number = 0; // 0=空隙 1=冲突组行
  h: number = 0;    // 备用（行高，当前未使用）
  topRatio: number = 0;
  botRatio: number = 0;
  group: TimelineGroup = new TimelineGroup(); // kind=1 时有效
  key: string = '';
}

/** 单日竖向时间轴：左侧 0-23 刻度，右侧按"冲突组"分行、组内每条日程占一列（lane）按时间纵向定位。
 *  每条日程 = 一个独立色块（跨整点也不再拆分、名字只出现一次）；冲突日程左右并排、不重叠。
 *  scrollable=true 时自带 Scroll+Scroller，并在"今天"自动定位到当前时刻（eventList 月/周视图用）；
 *  scrollable=false 时整页平铺（列表视图的今天卡片用，避免 Scroll 嵌套进 List）。 */
@Component
struct DayTimelineView {
  @Prop timeline: DayTimeline;
  @Prop nowMs: number;   // 当前时刻（drawLine 时定位红线）
  @Watch('onShowNowLine') @Prop showNowLine: boolean = false; // 仅"今天"显示红线 + 触发自动定位
  @Prop scrollable: boolean = false; // 是否自带可滚动容器（月/周视图日时间轴=true；列表视图卡片=false）
  hourUnit: number = TimelineUtil.HOUR_UNIT;
  private minBlockVp: number = 16;   // 极短日程色块的可读高度下限（一行"标题 + 时间"）
  private twoLineVp: number = 30;    // 能放下"标题 + 时间/地点"两行的高度门槛
  private threeLineVp: number = 46;  // 能放下"标题 / 时间 / 地址"三行的高度门槛
  onPick: (e: DisplayEvent) => void = (e: DisplayEvent): void => {};
  private scroller: Scroller = new Scroller();
  @State private viewportH: number = 0; // 滚动视口高度（由 Scroll 实测，用于把"当前时刻"居中）
  @State private allDayH: number = 0;   // 顶部"全天/跨天"区高度（它现在随内容滚动，居中定位要加上）
  private pendingScroll: boolean = false;

  aboutToAppear(): void {
    this.scrollToNow();
  }

  /** 显示日变为"今天"（或从今天切走）时触发；切到今天则自动定位到当前时刻 */
  private onShowNowLine(): void {
    this.scrollToNow();
  }

  /** 自动滚动：把"当前时刻红线"定位到可视区**垂直居中**
   *  （目标 y = nowRatio * 整日高 − 视口高/2，夹取 ≥0）。仅今天且自带滚动时生效。
   *  首帧视口高度未知 → 先用估算值滚一次，等 onAreaChange 实测到高度后再校正一次。 */
  private scrollToNow(): void {
    // 只有"红线会显示"时才需要自动定位到当前时刻；日程已全部结束时视窗已截断，不再滚动
    if (!this.scrollable || !this.includeNowHour()) {
      return;
    }
    this.pendingScroll = true;
    this.tryScroll();
  }
  private tryScroll(): void {
    if (!this.pendingScroll) {
      return;
    }
    const vp: number = this.viewportH > 0 ? this.viewportH : this.hourUnit * 8;
    // 内容顶部还有"全天/跨天"区（allDayH），且时间轴只从 viewTop 开始 → 都要计入偏移
    const y: number = this.allDayH + (TimelineUtil.nowRatio(this.nowMs) - this.viewTop()) * this.totalH() - vp / 2;
    setTimeout((): void => {
      this.scroller.scrollTo({ xOffset: 0, yOffset: y < 0 ? 0 : y });
    }, 60);
    if (this.viewportH > 0) {
      this.pendingScroll = false;
    }
  }

  private hourText(h: number): string {
    return h < 10 ? `0${h}:00` : `${h}:00`;
  }

  /** 是否把"当前小时"并入视窗：
   *  仅当"今天 + 还有未结束的定时日程"（即红线会显示）时才需要，保证红线可见。
   *  若今天定时日程已全部结束（红线已隐藏），则**不再并入当前小时** → 时间刻度直接截断到最晚日程。 */
  private includeNowHour(): boolean {
    return this.showNowLine && !this.allTimedEnded();
  }
  /** 视窗起始小时（统一走 TimelineUtil.viewRange，与列表视图高度计算共用同一份逻辑） */
  private viewStartHour(): number {
    return TimelineUtil.viewRange(this.timeline.blocks, this.includeNowHour(), this.nowMs).startHour;
  }
  /** 视窗结束小时 */
  private viewEndHour(): number {
    return TimelineUtil.viewRange(this.timeline.blocks, this.includeNowHour(), this.nowMs).endHour;
  }
  /** 视窗上/下边界（当日比例 0~1） */
  private viewTop(): number {
    return this.viewStartHour() / 24;
  }
  private viewBot(): number {
    return this.viewEndHour() / 24;
  }
  /** 视窗总高（vp）：三层堆叠区与左侧刻度都按这个高度对齐 */
  private viewH(): number {
    return (this.viewEndHour() - this.viewStartHour()) * this.hourUnit;
  }
  /** 当前选中日：定时日程是否已全部结束（统一走 TimelineUtil，供"隐藏红线/截断视窗"共用） */
  private allTimedEnded(): boolean {
    return TimelineUtil.allTimedEnded(this.timeline.blocks, this.nowMs);
  }
  /** 当前时间红线是否显示（今天 + 今天还有未结束的定时日程 + 当前时刻落在视窗内） */
  private nowVisible(): boolean {
    const r: number = TimelineUtil.nowRatio(this.nowMs);
    return this.showNowLine && !this.allTimedEnded()
      && r >= this.viewTop() - 0.0001 && r <= this.viewBot() + 0.0001;
  }
  /** 红线距层顶的偏移（vp）：减 1vp 让 2vp 高的线正好压在"现在"这一刻 */
  private nowOffsetVp(): number {
    const y: number = (TimelineUtil.nowRatio(this.nowMs) - this.viewTop()) * this.totalH() - 1;
    return y < 0 ? 0 : y;
  }
  /** 左侧小时刻度：只渲染视窗内的小时 */
  private hourLabels(): number[] {
    const arr: number[] = [];
    for (let h = this.viewStartHour(); h < this.viewEndHour(); h++) {
      arr.push(h);
    }
    return arr;
  }

  // ---- 布局换算：整日 = 24 小时竖向；横向按"冲突组"分列（lane），组内每条日程占一列 ----
  /** 整日高度（vp） */
  private totalH(): number {
    return this.hourUnit * 24;
  }
  /** 由色块重建冲突分组（组内按列并排） */
  private groups(): TimelineGroup[] {
    return TimelineUtil.groupsOf(this.timeline.blocks);
  }
  /** 冲突组这一行的高度（vp）= 该组的时间跨度 */
  private bandH(g: TimelineGroup): number {
    return (g.endRatio - g.startRatio) * this.totalH();
  }
  /** 某一列（lane）中、与本行窗口 [topRatio,botRatio] 有交集的色块（窗口外的整块跳过） */
  private laneBlocks(r: TimeRow, lane: TimelineBlock[]): TimelineBlock[] {
    const out: TimelineBlock[] = [];
    for (const b of lane) {
      const be: number = b.topRatio + b.heightRatio;
      if (be > r.topRatio + 0.0001 && b.topRatio < r.botRatio - 0.0001) {
        out.push(b);
      }
    }
    return out;
  }
  /** 列内第 index 个色块之前需要空出的高度（vp）= 本块顶 − 上一块底（都夹紧在窗口内，≥0） */
  private lanePadH(r: TimeRow, lane: TimelineBlock[], index: number): number {
    const arr: TimelineBlock[] = this.laneBlocks(r, lane);
    let prevEnd: number = r.topRatio;
    if (index > 0) {
      const p: TimelineBlock = arr[index - 1];
      const pe: number = p.topRatio + p.heightRatio;
      prevEnd = pe > r.topRatio ? pe : r.topRatio;
    }
    const b: TimelineBlock = arr[index];
    const top: number = b.topRatio > r.topRatio ? b.topRatio : r.topRatio;
    const d: number = (top - prevEnd) * this.totalH();
    return d < 0 ? 0 : d;
  }
  /** 色块实际渲染高度（vp）：按真实时长换算。
   *  "特别短"的日程（如 15 分钟）原始高度只有几 vp，放不下一行字 → 在不越过**同列下一个色块**的前提下
   *  尽量垫到 minBlockVp，保证至少能显示一行"时刻 + 题目"。垫不满时按实际可用量给，绝不重叠。 */
  private blockVp(r: TimeRow, lane: TimelineBlock[], index: number): number {
    const arr: TimelineBlock[] = this.laneBlocks(r, lane);
    const b: TimelineBlock = arr[index];
    const real: number = b.heightRatio * this.totalH();
    if (real >= this.minBlockVp) {
      return real;
    }
    let room: number = 0; // 可以借用的下方空隙（同列下一块之前 / 本行末尾）
    if (index + 1 < arr.length) {
      room = this.lanePadH(r, lane, index + 1);
    } else {
      const tail: number = (r.botRatio - (b.topRatio + b.heightRatio)) * this.totalH();
      room = tail > 0 ? tail : 0;
    }
    const h: number = real + room;
    return h > this.minBlockVp ? this.minBlockVp : h;
  }
  /** 色块信息行数（按**渲染高度**判定，标题永远独占第一行的开头）：
   *  1 = 一行放下 → 标题 · 时间 · 地址（时间用短格式）；
   *  2 = 标题一行 + "时间 · 地点"一行；
   *  3 = 标题 / 时间 / 地址 各一行（没有地址时退化为 2 行，不空占一行）。 */
  private blockLines(r: TimeRow, lane: TimelineBlock[], index: number, b: TimelineBlock): number {
    const h: number = this.blockVp(r, lane, index);
    if (h >= this.threeLineVp && b.location !== '') {
      return 3;
    }
    if (h >= this.twoLineVp) {
      return 2;
    }
    return 1;
  }
  /** 两行色块的第二行：'09:00 - 10:30 · 地点'（无地点时只剩时间） */
  private blockMeta(b: TimelineBlock): string {
    if (b.location !== '') {
      return `${b.timeText} · ${b.location}`;
    }
    return b.timeText;
  }
  /** 色块 ForEach key 的内容签名：只读标记 / 地点 / 渲染高度 / 标题长度任一变化都必须强制重建，
   *  否则 ArkUI 会按旧 key 复用子组件 → "改了样式界面不更新"。 */
  private blockSig(r: TimeRow, lane: TimelineBlock[], index: number, b: TimelineBlock): string {
    return `${b.writable ? 1 : 0}_${b.location.length}_${Math.round(this.blockVp(r, lane, index))}_${b.title.length}`;
  }
  /** 「只读」小标：圆角矩形白框 + 白字，紧跟在日程标题后面，字号比标题小一号 */
  @Builder
  private roTag() {
    Text('只读')
      .fontSize(9)
      .fontColor('#FFFFFF')
      .border({ width: 0.5, color: '#FFFFFF' })
      .borderRadius(4)
      .padding({ left: 4, right: 4, top: 0, bottom: 0 })
      .maxLines(1)
  }
  // 整点灰线由第 1 层（网格层）画、红线由第 3 层画 → 日程层不再为它们切段。
  /** 左侧刻度：当前小时是否高亮（仅今天） */
  private isNowHour(h: number): boolean {
    return this.showNowLine && Math.floor(TimelineUtil.nowRatio(this.nowMs) * 24) === h;
  }
  /** 组装"日程层"的纵向序列：只渲染视窗 [viewTop,viewBot] 内的时间。
   *  **本层只有两样东西：空隙（Blank）与冲突组行**，不再为整点线 / 红线切段 ——
   *  线与网格都交给另外两层去画，所以每条日程永远是一个完整、连续的色块。
   *  注意：所有 key 都带 dateKey + 视窗 + 内容签名 → 切换日期/内容时 key 必变，强制重渲染
   *  （否则 ArkUI 复用旧子组件会导致"串天/重复"）。 */
  private buildTimeRows(): TimeRow[] {
    const rows: TimeRow[] = [];
    const gs: TimelineGroup[] = this.groups();
    const top: number = this.viewTop();
    const bot: number = this.viewBot();
    const dk: string = `${this.timeline.dateKey}_${this.viewStartHour()}_${this.viewEndHour()}`;
    let cursor: number = top;
    for (const g of gs) {
      const gsx: number = g.startRatio > top ? g.startRatio : top;
      const gex: number = g.endRatio < bot ? g.endRatio : bot;
      if (gex - gsx <= 0.0002) {
        continue; // 整组都在视窗外
      }
      this.pushSpanRow(rows, cursor, gsx, null, dk);
      this.pushSpanRow(rows, gsx, gex, g, dk);
      cursor = gex;
    }
    this.pushSpanRow(rows, cursor, bot, null, dk);
    return rows;
  }

  private pushSpanRow(rows: TimeRow[], from: number, to: number, g: TimelineGroup | null,
    dk: string): void {
    if (to - from <= 0.0002) {
      return;
    }
    const r = new TimeRow();
    r.topRatio = from;
    r.botRatio = to;
    if (g === null) {
      r.kind = 0;
      r.key = `g_${dk}_${rows.length}_${Math.round((to - from) * 100000)}`;
    } else {
      r.kind = 1;
      r.group = g;
      let sig: string = '';
      for (const b of g.blocks) {
        sig = sig + '_' + b.eventKey;
      }
      r.key = `b_${dk}_${rows.length}${sig}`;
    }
    rows.push(r);
  }

  build() {
    Column() {
      // 时间轴主体（含顶部"全天/跨天"条 —— 它们随内容一起滚动，向下滑时跟 0 点一起上移）。
      // scrollable=true 时包一层 Scroll 并自动定位到当前时刻；否则整页平铺。
      if (this.scrollable) {
        Scroll(this.scroller) {
          this.timelineBody()
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
        .onAreaChange((oldVal: Area, newVal: Area): void => {
          const h: number = Number(newVal.height);
          if (h > 0 && (this.viewportH < 1 || h - this.viewportH > 1 || h - this.viewportH < -1)) {
            this.viewportH = h;
            this.tryScroll();
          }
        })
      } else {
        this.timelineBody()
      }
    }
    .width('100%')
    // 自带滚动（月/周视图）：占满父容器剩余高度；平铺（列表视图）：按内容自适应高度
    // —— 列表里每天需要的高度不同（视窗已按日程起止截断），必须让外层随内容伸缩，否则会显示不全
    .layoutWeight(this.scrollable ? 1 : 0)
    .alignItems(HorizontalAlign.Start)
  }

  /** 时间轴主体：顶部"全天/跨天"条（随滚动一起移动）+ 左侧小时刻度 + 右侧按冲突组分行、组内按列并排 */
  @Builder
  private timelineBody() {
    Column() {
      // 全天 / 跨天日程：同样用**色块**展示（与普通日程保持一致的视觉），
      // 画在 0 点之前并**随内容一起滚动**（向下滑时跟 0 点一起上移，不再常驻顶部）
      if (this.timeline.allDay.length > 0) {
        Column({ space: 4 }) {
          ForEach(this.timeline.allDay, (e: DisplayEvent) => {
            Row({ space: 6 }) {
              Text(e.isAllDay ? '全天' : '跨天')
                .fontSize(9)
                .fontColor('#FFFFFF')
                .backgroundColor('#26000000')
                .borderRadius(6)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              if (!e.writable) {
                // 只读标记：圆角矩形白框 + 白字（与色块上的「只读」小标同一套样式）
                Text('只读')
                  .fontSize(9)
                  .fontColor('#FFFFFF')
                  .border({ width: 0.5, color: '#FFFFFF' })
                  .borderRadius(4)
                  .padding({ left: 4, right: 4, top: 0, bottom: 0 })
              }
              Text(e.title === '' ? '(无标题)' : e.title)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (e.location !== '') {
                Text(e.location)
                  .fontSize(10)
                  .fontColor('#D9FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 120 })
              }
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .height(26)
            .padding({ left: 8, right: 8 })
            .borderRadius(8)
            // 只读不再用灰蒙版（已撤），只靠标题后的「只读」白框小标区分
            .backgroundColor(e.color)
            .onClick(() => this.onPick(e))
          }, (e: DisplayEvent) => `al_${this.timeline.dateKey}_${TimelineUtil.keyOf(e)}_${e.writable ? 1 : 0}_${e.location.length}`)
        }
        .width('100%')
        .padding({ bottom: 6 })
        .onAreaChange((oldVal: Area, newVal: Area): void => {
          const h: number = Number(newVal.height);
          if (h > 0 && (h - this.allDayH > 1 || h - this.allDayH < -1)) {
            this.allDayH = h;
            this.tryScroll();
          }
        })
      }

      Row() {
        // 左侧小时刻度（每格一条底线，作为时间尺；当前小时高亮）。只渲染视窗内的小时
        Column() {
          ForEach(this.hourLabels(), (h: number) => {
            Text(this.hourText(h))
              .fontSize(10)
              .fontColor(this.isNowHour(h) ? '#FF3B30' : '#9AA0A6')
              .width(36)
              .height(this.hourUnit)
              .textAlign(TextAlign.End)
              .padding({ right: 4, top: 2 })
              .border({ width: { bottom: 0.5 }, color: { bottom: '#14000000' } })
          }, (h: number) => `h${h}`)
        }
        .width(36)

        // 右侧内容区：**三层堆叠**（网格层 / 日程层 / 红线层）。
        // 三层尺寸、分格方式完全一致；上层透明，只画自己该画的东西，互不挤占 →
        // 日程色块再也不会被整点线或红线"切开"，红线也永远浮在最上面。
        Stack() {
          this.gridLayer()  // 第 1 层：整点网格线（贯穿全宽）
          this.eventLayer() // 第 2 层：日程色块（透明底，盖住下面的网格线属正常）
          this.nowLayer()   // 第 3 层：当前时间红线（盖住前两层）
        }
        .layoutWeight(1)
        .height(this.viewH())
        .alignContent(Alignment.TopStart)
        .border({ width: { left: 0.5 }, color: { left: '#14000000' } })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
  }

  // ===== 三层绘图：每层尺寸与分格方式完全相同（高 = viewH，宽 = 内容区全宽），上层透明 =====

  /** 第 1 层：整点网格 —— 每个小时一格，格底一条灰线，贯穿全宽 */
  @Builder
  private gridLayer() {
    Column() {
      ForEach(this.hourLabels(), (h: number) => {
        Column()
          .width('100%')
          .height(this.hourUnit)
          .border({ width: { bottom: 0.5 }, color: { bottom: '#14000000' } })
          .hitTestBehavior(HitTestMode.None) // 装饰层子节点同样不参与命中测试
      }, (h: number) => `gd_${h}`)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None) // 装饰层：不参与命中测试，触碰事件穿透到下层色块
  }

  /** 第 2 层：日程色块 —— 冲突组分行 + 组内 lane 分列，纵向用 Blank 定位。
   *  本层不再需要为"整点线 / 红线"让路而切段 → 每条日程永远是一个完整连续的色块。 */
  @Builder
  private eventLayer() {
    Column() {
      ForEach(this.buildTimeRows(), (r: TimeRow) => {
        if (r.kind === 1) {
          Row() {
            ForEach(r.group.lanes, (lane: TimelineBlock[], li: number) => {
              Column() {
                ForEach(this.laneBlocks(r, lane), (b: TimelineBlock, index: number) => {
                  Blank().height(this.lanePadH(r, lane, index))
                  Column({ space: 1 }) {
                    if (this.blockLines(r, lane, index, b) === 1) {
                      // 一行：标题 · [只读] · 时间 · 地址
                      // 时间用**完整起止**（09:00 - 10:30）：宽度够就整段显示，不够由 maxWidth + 省略号自然截断；
                      // 三者的让位顺序是"地址先没 → 时间省略 → 标题只保 50%"，保证标题与开始时间一定看得到。
                      Row({ space: 4 }) {
                        Text(b.title)
                          .fontSize(10)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: '50%' })
                          .lineHeight(12)
                        if (!b.writable) {
                          this.roTag()
                        }
                        Text(b.timeText)
                          .fontSize(9)
                          .fontColor('#E6FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: '55%' })
                          .lineHeight(12)
                        if (b.location !== '') {
                          Text(b.location)
                            .fontSize(9)
                            .fontColor('#B3FFFFFF')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .lineHeight(12)
                            .layoutWeight(1)
                        }
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                    } else {
                      // 第一行：标题 · [只读]（标题永远打头）
                      Row({ space: 4 }) {
                        Text(b.title)
                          .fontSize(11)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: '70%' })
                        if (!b.writable) {
                          this.roTag()
                        }
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                      if (this.blockLines(r, lane, index, b) >= 3) {
                        // 三行：第二行时间、第三行地址
                        Text(b.timeText)
                          .fontSize(9)
                          .fontColor('#E6FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                        Text(b.location)
                          .fontSize(9)
                          .fontColor('#B3FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      } else {
                        // 两行：第二行"时间 · 地点"
                        Text(this.blockMeta(b))
                          .fontSize(9)
                          .fontColor('#E6FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      }
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .justifyContent(FlexAlign.Start)
                  .padding({ left: 6, right: 3, top: 2, bottom: 2 })
                  .borderRadius(6)
                  .backgroundColor(b.color)
                  .opacity(b.isNow ? 1 : 0.92)
                  .clip(true)
                  .width('100%')
                  .height(this.blockVp(r, lane, index))
                  .onClick(() => {
                    if (b.ev !== null) {
                      this.onPick(b.ev);
                    }
                  })
                }, (b: TimelineBlock, index: number) => `blk_${r.key}_${b.eventKey}_${this.blockSig(r, lane, index, b)}`)
              }
              .layoutWeight(1)
              .height('100%')
              .padding({ right: 2 })
              .clip(true)
            }, (lane: TimelineBlock[], li: number) => `ln_${r.key}_${li}`)
          }
          .width('100%')
          .height((r.botRatio - r.topRatio) * this.totalH())
          .alignItems(VerticalAlign.Top)
        } else {
          // 空隙：纯占位（网格线在第 1 层，红线在第 3 层，本层不参与）
          Blank().height((r.botRatio - r.topRatio) * this.totalH())
        }
      }, (r: TimeRow) => r.key)
    }
    .width('100%')
    .height('100%')
  }

  /** 第 3 层：当前时间红线 —— 浮在最上层，不挤占任何布局，也不切割任何色块 */
  @Builder
  private nowLayer() {
    Column() {
      if (this.nowVisible()) {
        Blank().height(this.nowOffsetVp()).hitTestBehavior(HitTestMode.None) // 占位块：不拦截点击
        Row() {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor('#FF3B30')
          Column()
            .height(2)
            .layoutWeight(1)
            .backgroundColor('#FF3B30')
            .borderRadius(1)
        }
        .width('100%')
        .hitTestBehavior(HitTestMode.None) // 红线本身也不拦截点击，穿透到色块层
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None) // 装饰层：整层不参与命中测试，触碰事件穿透到下层色块
  }
}