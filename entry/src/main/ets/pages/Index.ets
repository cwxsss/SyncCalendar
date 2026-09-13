// entry/src/main/ets/pages/Index.ets
// 同步日历主界面：月视图（左右滑动翻月）/ 周视图 / 日视图 / 日程列表
// 混合展示 DAV 与系统日历；每分钟自动同步；可"回到今天"
import { mediaquery, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, CalSource, TYPE_CALDAV } from '../common/AccountStore';
import { DisplayEvent, CalendarDataService } from '../common/CalendarDataService';
import { SyncEngine } from '../common/SyncEngine';
import { LogUtil } from '../common/LogUtil';
import { LunarUtil } from '../common/LunarUtil';
import { CardDataService } from '../common/CardDataService';
import { ReminderService } from '../common/ReminderService';
import { AppSettings } from '../common/AppSettings';
import { EventDb, LocalEvent, RemoteEvent } from '../common/EventDb';
import { RruleUtil } from '../common/RruleUtil';
import { IcsUtil } from '../common/IcsUtil';
import { DavClient, RemoteItem } from '../common/DavClient';
import { SystemCalendarImport } from '../common/SystemCalendarImport';
import { ScreenKeeper } from '../common/ScreenKeeper';

/** 月视图单元格 */
class MonthCell {
  dateMs: number = 0;
  day: number = 0;
  inMonth: boolean = false;
  isToday: boolean = false;
  lunar: string = ''; // 农历（初一时显示月名）
}

const WEEK_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

@Entry
@Component
struct Index {
  @State mode: string = 'month'; // month | week | agenda | todo
  @State displayYear: number = 2026;
  @State displayMonth: number = 0; // 0-11
  @State selectedDate: number = 0; // 当天 0 点毫秒
  @State events: DisplayEvent[] = [];
  @State todos: DisplayEvent[] = []; // 待办（VTODO，单独展示）
  @State agendaEvents: DisplayEvent[] = []; // 列表视图全量数据（过去1年~未来2年）
  @State agendaGroupsData: AgendaGroup[] = []; // 预计算分组（避免 build 中重算卡顿）
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
  private autoSyncTimer: number = -1;
  private lastSyncTime: number = 0;
  private permissionAsked: boolean = false;

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
    this.initPermissionAndLoad();
  }

  aboutToDisappear(): void {
    if (this.autoSyncTimer !== -1) {
      clearInterval(this.autoSyncTimer);
      this.autoSyncTimer = -1;
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
    // 无条件刷新：之前"列表为空就跳过"的条件会导致账号列表卡死在空状态，
    // 同步时误报"没有可同步的账号"
    this.reloadAll().then((): Promise<void> => this.handlePendingSync());
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
    if (!this.permissionAsked) {
      this.permissionAsked = true;
      // 申请读取全部日历权限（用于混合展示系统日程）
      CalendarDataService.ensureSystemCalendarPermission(context as common.UIAbilityContext)
        .then((): void => {
          this.reloadAll();
        });
    }
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
        const minutes: number = AppStorage.get<number>('syncIntervalMinutes') ?? 1;
        if (Date.now() - this.lastSyncTime < minutes * 60000) {
          return; // 未到设置的同步间隔
        }
        if (!this.syncing && this.accounts.length > 0) {
          this.lastSyncTime = Date.now();
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
    const rangeStart: number = monthStart - 7 * 86400000;
    const rangeEnd: number = monthStart + 32 * 86400000 + 60 * 86400000;
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
  }

  private eventsOfDate(dateMs: number): DisplayEvent[] {
    return this.events.filter((e: DisplayEvent): boolean =>
      this.startOfDay(e.startTime) <= dateMs && e.endTime >= dateMs);
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
    // 只读日历本或系统日历日程：无法保存修改，直接显示详情
    if (e.isSystem || !e.writable) {
      this.showEventDetail(e);
      return;
    }
    AppStorage.setOrCreate<number>('pendingEventId', e.id);
    router.pushUrl({ url: 'pages/EventEditPage' });
  }

  /** 只读日程详情弹窗 */
  private showEventDetail(e: DisplayEvent): void {
    const lines: string[] = [];
    if (e.isAllDay) {
      lines.push(`时间：全天 ${this.fmtDateCn(e.startTime)}`);
      if (this.spansDays(e)) {
        lines.push(`        ~ ${this.fmtDateCn(e.endTime)}`);
      }
    } else if (this.spansDays(e)) {
      lines.push(`时间：${this.fmtDateCn(e.startTime)} ${this.fmtTime(e.startTime)}`);
      lines.push(`        ~ ${this.fmtDateCn(e.endTime)} ${this.fmtTime(e.endTime)}`);
    } else {
      lines.push(`时间：${this.fmtDateCn(e.startTime)} ${this.fmtTime(e.startTime)} ~ ${this.fmtTime(e.endTime)}`);
    }
    if (e.location !== '') {
      lines.push(`地点：${e.location}`);
    }
    if (e.recurring) {
      lines.push('重复：是');
    }
    if (e.calName !== '') {
      lines.push(`日历本：${e.calName}${e.isSystem ? '' : '（只读）'}`);
    }
    if (e.description !== '') {
      lines.push(`备注：${e.description}`);
    }
    this.getUIContext().showAlertDialog({
      title: e.title === '' ? '(无标题)' : e.title,
      message: lines.join('\n'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '关闭',
        action: (): void => {}
      }
    });
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
    }
    .width('100%')
    .height('100%')
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
      this.modeTab('todo', '待办')
      Blank()
      if (this.mode === 'month') {
        Text(this.fmtMonthTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      } else if (this.mode === 'todo') {
        Text(`${this.todos.filter((t: DisplayEvent): boolean => !t.completed).length} 项未完成`)
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

  /** 切换视图：进入列表视图时按需加载（今天整天 ~ 未来2年，昨天之前已结束的不显示） */
  private async handleModeSwitch(key: string): Promise<void> {
    this.mode = key;
    if (key === 'agenda') {
      await this.ensureAgendaData();
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
    const start: number = this.startOfDay(now);
    const end: number = now + 730 * 86400000;
    try {
      const raw: DisplayEvent[] = await CalendarDataService.loadEvents(context, start, end, this.sources);
      // 保留"今天 0 点以来"的全部日程：今天已结束的也显示（否则重复日程的第一次发生会被隐藏），
      // 昨天及更早且已结束的不显示；跨天进行中的归到今天，与卡片一致
      this.agendaEvents = raw.filter((e: DisplayEvent): boolean => e.endTime >= start);
      this.agendaGroupsData = this.buildAgendaGroups(this.agendaEvents);
      this.agendaStale = false;
      LogUtil.write(`列表视图加载：${this.agendaEvents.length} 条（今天~未来2年），分组 ${this.agendaGroupsData.length} 组`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`列表视图加载失败：${e.message}`);
    }
    this.loading = false;
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
      .gesture(
        SwipeGesture({ direction: SwipeDirection.Horizontal })
          .onAction((event: GestureEvent) => {
            if (Math.abs(event.angle) > 90) {
              this.switchWeek(1);
            } else {
              this.switchWeek(-1);
            }
          })
      )
    } else {
      // 竖屏：保持原上下结构
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

        this.eventList()
      }
      .width('100%')
      .layoutWeight(1)
      .gesture(
        SwipeGesture({ direction: SwipeDirection.Horizontal })
          .onAction((event: GestureEvent) => {
            // 左滑角度约 ±180（|angle|>90）→ 下一周；右滑约 0° → 上一周（与月视图 Swiper 方向一致）
            if (Math.abs(event.angle) > 90) {
              this.switchWeek(1);
            } else {
              this.switchWeek(-1);
            }
          })
      )
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
  }

  /** 单日日程列表（周视图使用） */
  @Builder
  eventList() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.eventsOfDate(this.selectedDate), (e: DisplayEvent) => {
          this.eventRow(e)
        }, (e: DisplayEvent) => `${e.isSystem ? 's' : 'l'}${e.id}_${e.startTime}`)
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
  }

  @Builder
  agendaBody() {
    List({ space: 6 }) {
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

      ForEach(this.agendaGroupsData, (group: AgendaGroup) => {
        ListItem() {
          Text(group.label)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 6, bottom: 2 })
        }
        ForEach(group.items, (e: DisplayEvent) => {
          ListItem() {
            this.eventRow(e)
          }
        }, (e: DisplayEvent) => `${e.isSystem ? 's' : 'l'}${e.id}_${e.startTime}_${e.title}`)
      }, (group: AgendaGroup) => group.label)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ left: 20, right: 20, top: 6, bottom: 24 })
    .cachedCount(8)
  }

  /** 列表视图分组：今天 ~ 未来的日程（跨天进行中的归今天，与卡片一致）。
   *  结果预计算到 @State，避免每次 build 重算导致卡顿 */
  private buildAgendaGroups(events: DisplayEvent[]): AgendaGroup[] {
    const map: Map<number, DisplayEvent[]> = new Map();
    const today: number = this.startOfDay(Date.now());
    for (const e of events) {
      const spans: boolean = this.startOfDay(e.endTime) > this.startOfDay(e.startTime);
      // 跨天且已开始：归今天；其余归开始日
      const key: number = spans && this.startOfDay(e.startTime) < today
        ? today : this.startOfDay(e.startTime);
      let arr: DisplayEvent[] | undefined = map.get(key);
      if (arr === undefined) {
        arr = [];
        map.set(key, arr);
      }
      arr.push(e);
    }
    const keys: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    const groups: AgendaGroup[] = [];
    for (const key of keys) {
      const items: DisplayEvent[] = map.get(key) ?? [];
      items.sort((a: DisplayEvent, b: DisplayEvent): number => {
        const aAll: boolean = a.isAllDay ||
          this.startOfDay(a.endTime) > this.startOfDay(a.startTime);
        const bAll: boolean = b.isAllDay ||
          this.startOfDay(b.endTime) > this.startOfDay(b.startTime);
        if (aAll !== bAll) {
          return aAll ? -1 : 1;
        }
        return a.startTime - b.startTime;
      });
      const g = new AgendaGroup();
      g.label = key === today ? '今天' : this.fmtDateCn(key);
      g.items = items;
      groups.push(g);
    }
    return groups;
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
  eventRow(e: DisplayEvent) {
    Row({ space: 10 }) {
      Column()
        .width(4)
        .height(38)
        .borderRadius(2)
        .backgroundColor(e.color)
      Column({ space: 3 }) {
        Text(e.title === '' ? '(无标题)' : e.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(e.isAllDay || this.spansDays(e)
            ? '全天' : `${this.fmtTime(e.startTime)} - ${this.fmtTime(e.endTime)}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          if (e.recurring) {
            Text('↻ 重复')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor($r('app.color.chip_off_bg'))
          }
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

/** 日程列表的按日分组 */
class AgendaGroup {
  label: string = '';
  items: DisplayEvent[] = [];
}