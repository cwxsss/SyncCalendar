// entry/src/main/ets/pages/Index.ets
// 同步日历主界面：月视图（左右滑动翻月）/ 周视图 / 日视图 / 日程列表
// 混合展示 DAV 与系统日历；每分钟自动同步；可"回到今天"
import { curves, display, router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, CalSource, TYPE_CALDAV } from '../common/AccountStore';
import { DisplayEvent, CalendarDataService } from '../common/CalendarDataService';
import { SyncEngine, SyncBusyError } from '../common/SyncEngine';
import { LogUtil } from '../common/LogUtil';
import { LunarUtil, dayStartMs, normalizeSingleDayIfFestival } from '../common/LunarUtil';
import { CardDataService } from '../common/CardDataService';
import { ReminderService } from '../common/ReminderService';
import { AppSettings } from '../common/AppSettings';
import { TipsPanel } from '../common/TipsPanel';
import { DocViewer } from '../common/DocViewer';
import { EventDb, LocalEvent, RemoteEvent } from '../common/EventDb';
import { RruleUtil } from '../common/RruleUtil';
import { IcsUtil, AttachMeta } from '../common/IcsUtil';
import { DavClient, RemoteItem } from '../common/DavClient';
import { SystemCalendarImport } from '../common/SystemCalendarImport';
import { SystemCalendarMirror } from '../common/SystemCalendarMirror';
import { MirrorInbound, InboundResult } from '../common/MirrorInbound';
import { ScreenKeeper } from '../common/ScreenKeeper';
import { TodoService } from '../common/TodoService';
import { TimelineUtil, TimelineBlock, TimelineGroup, DayTimeline, ViewRange } from '../common/TimelineUtil';
import { HolidayUtil, HolidayInfo } from '../common/HolidayUtil';
import { SmartDateParser, ParsedEventInfo } from '../common/SmartDateParser';

/** 月视图单元格 */
class MonthCell {
  dateMs: number = 0;
  day: number = 0;
  inMonth: boolean = false;
  isToday: boolean = false;
  lunar: string = ''; // 农历（初一时显示月名）
  hasEvent: boolean = false;
  hasEvents: boolean = false; // 是否有日程（日期下方小红点）
  events: DisplayEvent[] = []; // 该日日程列表（全月展开视图展示）
  holidayBadge: string = ''; // '休' | '班'
  holidayType: string = '';  // 'holiday' | 'workday'
}

/**
 * 待办列表的扁平行。
 */
class TodoFlatRow {
  role: string = '';
  text: string = '';
  group: TodoGroup | undefined = undefined;
  event: DisplayEvent | undefined = undefined;
  extraTop: number = 0;

  keyOf(idx: number): string {
    if (this.role === 'item' && this.event !== undefined) {
      return `i${this.event.id}_${this.event.completed}`;
    }
    if (this.role === 'header' && this.group !== undefined) {
      return `h${this.group.calKey}`;
    }
    return `c${idx}`;
  }
}

class TodoGroup {
  calKey: string = '';
  name: string = '';
  color: string = '#007DFF';
  items: DisplayEvent[] = [];
}

const WEEK_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/** 视图前后顺序（决定手势/标签切换时的转场方向）：月 → 周 → 列表 */
const VIEW_ORDER: string[] = ['month', 'month_expanded', 'week', 'agenda', 'todo'];

@Entry
@Component
struct Index {
  @State mode: string = 'month'; // month | week | agenda | todo
  @State displayYear: number = 2026;
  @State displayMonth: number = 0; // 0-11
  @Watch('onSelectedDateChange') @State selectedDate: number = 0; // 当天 0 点毫秒
  @State selectedDayEvents: DisplayEvent[] = []; // 当前选中日期的日程列表，保证 UI 响应式强刷新
  @State dataVersion: number = 0; // 数据版本戳，递增促发 ForEach 彻底重绘
  @State detailSheetMode: string = 'detail'; // 'detail' | 'scope' | 'confirm'
  @State topRangeMode: string = 'today'; // 顶部时间范围模式：'today' | '3days' | '7days' | ''（空表示选中非今天单日）
  @State searchOpen: boolean = false; // 全局日程搜索弹窗
  @State searchQuery: string = '';
  @State searchResults: DisplayEvent[] = [];
  @State searchLoading: boolean = false;
  @State events: DisplayEvent[] = [];
  @State todos: DisplayEvent[] = []; // 待办（VTODO，单独展示）
  @State quickTodoText: string = ''; // 待办快速输入框文本
  @State todoBusy: boolean = false;  // 正在写回待办状态（防连点）
  // ⭐ 待办新建模式：true=新建（弹层显示日历本选择），false=编辑既有待办
  @State todoCreating: boolean = false;
  // 新建待办时可选的日历本（铺开供用户选，与新建日程一致）
  @State todoBooks: CalSource[] = [];
  // 新建待办时选中的日历本 calKey
  @State todoCreateBookKey: string = '';
  // calKey → 日历本集合 URL 的映射（CalSource 本身不带 href，需从账号解析）
  private todoBookHrefs: Map<string, string> = new Map<string, string>();

  // ⭐ TODO_EDITOR 待办编辑弹框状态
  @State todoEditShow: boolean = false;
  @State todoEditId: number = 0;
  @State todoEditTitle: string = '';
  @State todoEditDesc: string = '';
  @State todoEditDueMs: number = 0;      // 0 = 无截止时间
  @State todoEditBook: string = '';      // 所属本名（只读展示）
  @State todoEditWritable: boolean = true;
  @State todoEditRecur: string = '';   // 当前循环（'' = 不循环），存 FREQ 值如 WEEKLY
  /** 优先级：iCal 原生值 1=高 5=中 9=低，0=未设置 */
  @State todoEditPriority: number = 0;
  /** 分类标签，逗号分隔（对应 CATEGORIES） */
  @State todoEditCategories: string = '';
  /** 地点（复用 VTODO 的 LOCATION） */
  @State todoEditLocation: string = '';
  /** 提醒：提前分钟数（多选），空 = 不提醒 */
  @State todoEditReminders: number[] = [];
  /** 当前编辑待办的父任务 UID（空 = 顶层任务） */
  @State todoEditParentUid: string = '';
  /** 附件 JSON（格式与数据层一致：[{name,mime,size,base64}]） */
  @State todoEditAttachments: string = '';
  /** 父任务选择弹层 */
  @State todoParentPickShow: boolean = false;
  /** 附件选择中（防连点，文件选择器打开期间） */
  @State todoAttachBusy: boolean = false;
  @State todoEditHasDue: boolean = false;
  @State todoEditPickShow: boolean = false;  // 截止时间选择器
  @State todoEditPickDate: Date = new Date();
  @State todoEditPickHour: number = 9;
  @State todoEditPickMin: number = 0;
  @State agendaEvents: DisplayEvent[] = []; // 列表视图全量数据（今天 ~ 未来2年）
  private agendaStale: boolean = true; // 全量数据是否需要重新加载
  @State monthPages: MonthCell[][] = [[], [], []]; // 上月/本月/下月
  /** ⭐ 月视图数据版本号：每次 rebuildPages 后自增，拼进外层 ForEach 的 key。
   *  为什么需要它：外层 key 原本用"这页第一天"（cells[0].dateMs），
   *  数据重载前后这个值完全相同，ArkUI 会判定"同一项"而**复用整棵子树**，
   *  连 itemGenerator 都不重新执行 ⇒ 内层永远拿到旧的 cells（hasEvent 全 false）。
   *  只改内层 key 是没用的，必须让外层 key 变。 */
  @State monthDataVersion: number = 0;
  /** ⭐ 用户**主动选中**的日号（1~31）。翻月时用它算目标日，
   *  避免"1/31 → 2/28 → 3/28"这种日号被永久钳死的问题：
   *  有了它，2 月显示 28 号，翻到 3 月能回到 31 号。 */
  @State preferredDay: number = new Date().getDate();
  @State syncing: boolean = false;
  @State loading: boolean = true;
  @State menuOpen: boolean = false; // 顶部 ≡ 下拉菜单
  // 宽屏（双栏：月视图左月历 / 右当日日程，周视图同理）判据，两条满足其一即双栏：
  //   ① 窗口短边 ≥ 840vp —— 折叠屏展开态 / 平板这类"大屏"。短边在旋转时不变，
  //      故横竖屏布局天然一致，满足"屏幕比例接近 1:1 的设备，横竖屏布局需保持一致"；
  //   ② 横屏且宽高比 ≥ 1.5 —— 长条形屏幕（普通手机、折叠屏**合上后的外屏**）。
  //      这类设备比例远离 1:1，旋转应当切换布局（0.0.2 起即如此，用户已习惯）。
  //      加比例下限是为了兜底"短边不足 840 但比例接近 1:1"的小方屏：旋转依旧不变。
  // 2026-09-29 修复：上一版只留了判据 ①，导致 Mate X7 合盖后旋转屏幕布局不再变化。
  @State wideLayout: boolean = false;
  private winObj: window.Window | null = null;
  private winSizeCallback: ((size: window.Size) => void) | null = null;
  private accounts: DavAccount[] = [];
  private sources: CalSource[] = [];
  private eventsByDay: Map<number, DisplayEvent[]> = new Map<number, DisplayEvent[]>();
  private isLoadingAll: boolean = false;
  private pendingReload: boolean = false;
  private swiperController: SwiperController = new SwiperController();
  private expandedSwiperController: SwiperController = new SwiperController();
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
  @State showTodosInCalendar: boolean = true;
  // 服务卡片"添加"按钮深链：EntryAbility 写入，本页读取后拉起新建日程页
  @Watch('onWidgetActionChange') @StorageLink('widgetAction') widgetAction: string = '';
  // 服务卡片点击进入日历时携带的"显示日"毫秒（用户可能已翻到其他日期）：消费后定位 selectedDate
  @Watch('onWidgetOpenDateChange') @StorageLink('widgetOpenDate') widgetOpenDate: number = 0;
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
  @State showTips: boolean = false;       // 首启功能引导（整页覆盖层：遮罩 + 底部卡片 + Swiper 三页）
  // ---- 内置文档浏览器（《隐私政策》/《用户服务协议》，整页 Web 覆盖层，不跳出应用） ----
  @State showDoc: boolean = false;
  @State docTitle: string = '';
  @State docUrl: ResourceStr = '';

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
    // 卡片点击：若携带显示日（用户可能已翻到其他日期），进入日历时定位到那一天
    const openFromCard: number = AppStorage.get<number>('widgetOpenDate') ?? 0;
    if (openFromCard !== 0) {
      AppStorage.setOrCreate<number>('widgetOpenDate', 0); // 用后即清，避免残留
      // 合法性校验（防 int32 溢出等脏值把日历定位到 1970）
      if (openFromCard >= 946684800000 && openFromCard <= 4102444800000) {
        const cd = new Date(openFromCard);
        this.displayYear = cd.getFullYear();
        this.displayMonth = cd.getMonth();
        this.selectedDate = this.startOfDay(openFromCard);
        LogUtil.write(`从卡片进入：定位到显示日 ${this.selectedDate}`);
      }
    }
    this.rebuildPages();
    this.initLayoutListener();
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
    // 红线"播放"效果：每 30s 更新 nowMs，让当前时间红线随真实时间推进（同时刷新色块"进行中"标记与跨天检测）
    this.nowTimer = setInterval((): void => {
      const prevMs = this.nowMs;
      this.nowMs = Date.now();
      // 跨天检测（0点翻篇）：若日期变了，自动刷新全量数据并推送服务卡片
      if (TimelineUtil.startOfDay(this.nowMs) !== TimelineUtil.startOfDay(prevMs)) {
        LogUtil.write('应用内检测到跨天，自动刷新全部数据与服务卡片');
        this.reloadAll().catch(() => {});
      } else {
        this.refreshNowMarks();
      }
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
    if (this.winObj !== null && this.winSizeCallback !== null) {
      try {
        this.winObj.off('windowSizeChange', this.winSizeCallback);
      } catch (err) {
        // 窗口可能已销毁（页面退出），忽略
      }
      this.winSizeCallback = null;
      this.winObj = null;
    }
  }

  /**
   * 由窗口实际尺寸（px → vp）计算单栏/双栏。判据见 wideLayout 字段注释：
   * 短边 ≥ 840vp（大屏，旋转不变）或 横屏且宽高比 ≥ 1.5（长条形屏幕，旋转切换）。
   */
  private applyLayoutFromWindow(win: window.Window): void {
    try {
      const rect = win.getWindowProperties().windowRect;
      const density: number = display.getDefaultDisplaySync().densityPixels;
      if (density <= 0) {
        return;
      }
      const w: number = rect.width / density;
      const h: number = rect.height / density;
      const shortEdge: number = Math.min(w, h);
      const ratio: number = h > 0 ? w / h : 1;
      const wide: boolean = shortEdge >= 840 || (w > h && ratio >= 1.5);
      LogUtil.write(`窗口尺寸 ${Math.round(w)}x${Math.round(h)}vp（短边 ${Math.round(shortEdge)}，宽高比 ${ratio.toFixed(2)}）→ ${wide ? '双栏' : '单栏'}`);
      if (wide !== this.wideLayout) {
        this.wideLayout = wide;
      }
    } catch (err) {
      // 取窗口信息失败时保持现状（罕见：窗口已销毁）
    }
  }

  private initLayoutListener(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window): void => {
      this.winObj = win;
      this.applyLayoutFromWindow(win);
      this.winSizeCallback = (_size: window.Size): void => {
        // size 参数为 px；重新读取属性并换算（折叠/展开、旋转都会触发）
        this.applyLayoutFromWindow(win);
      };
      win.on('windowSizeChange', this.winSizeCallback);
    }).catch((err: BusinessError): void => {
      LogUtil.write(`窗口尺寸监听初始化失败(保持默认单栏)：${err.message}`);
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

    // 检查是否有编辑/新建日程传回的定位日期
    const pendingDate: number = AppStorage.get<number>('pendingEventDate') ?? 0;
    if (pendingDate !== 0) {
      AppStorage.setOrCreate<number>('pendingEventDate', 0);
      if (pendingDate >= 946684800000 && pendingDate <= 4102444800000) {
        this.jumpToDate(pendingDate);
      }
    }

    // 消费日程修改时间戳标记（若有修改，清除旧详情缓存）
    const modifiedTs: number = AppStorage.get<number>('eventModifiedTimestamp') ?? 0;
    if (modifiedTs !== 0) {
      AppStorage.setOrCreate<number>('eventModifiedTimestamp', 0);
      this.detailShow = false;
      this.detailEvent = null;
    }

    // 无条件刷新：保证回到前台或编辑返回时即时重载所有日程和卡片，并对账系统日历新建/改动
    this.reloadAll().then(async (): Promise<void> => {
      await this.handlePendingSync();
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        try {
          const inboundRes: InboundResult = await MirrorInbound.reconcile(ctx);
          if (inboundRes.created > 0 || inboundRes.updated > 0 || inboundRes.deleted > 0) {
            await this.reloadEvents();
            if (!this.syncing) {
              this.syncAll(false).catch(() => {});
            }
          }
        } catch (err) {
          // 忽略对账异常
        }
      }
    });
  }

  /** 卡片深链监听（App 已在后台运行时，onNewWant 改写 AppStorage 触发） */
  private onWidgetActionChange(): void {
    this.consumeWidgetAction();
  }

  /** 卡片点击携带的"显示日"：App 已在后台运行时由 onNewWant 改写，定位到那一天后清除 */
  private onWidgetOpenDateChange(): void {
    const d: number = this.widgetOpenDate;
    if (d !== 0) {
      AppStorage.setOrCreate<number>('widgetOpenDate', 0); // 用后即清，避免残留
      // 合法性校验（防 int32 溢出等脏值）
      if (d >= 946684800000 && d <= 4102444800000) {
        this.jumpToDate(d);
        LogUtil.write(`卡片切入（运行中）：定位到显示日 ${this.selectedDate}`);
      }
    }
  }

  /**
   * 定位到指定日期时间（毫秒时间戳）：
   * 同步更新 selectedDate，并检查是否需要切换 displayYear / displayMonth；
   * 若月份改变，则重新加载事件并重建日历三页，同时将 Swiper 索引归正到 1。
   */
  private jumpToDate(ms: number): void {
    if (ms < 946684800000 || ms > 4102444800000) {
      return;
    }
    const d = new Date(ms);
    const targetDay = this.startOfDay(ms);
    const targetY = d.getFullYear();
    const targetM = d.getMonth();
    this.selectedDate = targetDay;
    if (targetY !== this.displayYear || targetM !== this.displayMonth) {
      this.displayYear = targetY;
      this.displayMonth = targetM;
      this.rebuildPages();
      this.reloadEvents();
      this.swiperGuard = true;
      this.swiperController.changeIndex(1, false);
      this.expandedSwiperController.changeIndex(1, false);
    } else {
      this.rebuildDayTimeline();
    }
  }

  /** 消费卡片"添加"深链：拉起新建日程页并立即清除标记，避免重复触发 */
  private consumeWidgetAction(): void {
    const action: string = AppStorage.get<string>('widgetAction') ?? '';
    if (action === '') {
      return;
    }
    AppStorage.setOrCreate<string>('widgetAction', '');
    if (action === 'add') {
      this.addEvent();
    } else if (action === 'addTodo') {
      this.mode = 'todo';
      this.openTodoCreator();
    } else if (action === 'openTodo') {
      this.mode = 'todo';
    }
  }

  private async handlePendingSync(): Promise<void> {
    const pendingId: string | undefined = AppStorage.get<string>('pendingSyncAccountId');
    if (pendingId !== undefined && pendingId !== '') {
      AppStorage.setOrCreate<string>('pendingSyncAccountId', '');
      await this.syncSingle(pendingId);
    }
  }

  /**
   * 启动/同意隐私政策后的初始化：**只加载本地库与 DAV 数据**。
   *
   * ⚠️ 合规约束（《审核指南》7.17）：这里**不申请任何权限**。
   * 权限必须由用户主动点击对应功能时申请，否则会被判定为"未主动点击即提前弹窗申请"：
   *   - 读取全部日程（日历）→ 设置页「混合显示系统日历」开关 / 「备份到 CalDAV 日历本」
   *   - 通知 → 保存带提醒的日程 / 开启「后台持续同步」/ 设置页「去开启通知」
   * 本方法只负责加载数据；系统日历来源由 CalendarDataService.loadSources 按开关与授权状态自行决定是否读取。
   */
  private initPermissionAndLoad(): void {
    this.reloadAll();
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
  private openDoc(title: string, url: ResourceStr): void {
    if (typeof url === 'string' && !url.startsWith('https://') && !url.startsWith('http://')) {
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
    if (this.isLoadingAll) {
      this.pendingReload = true;
      return;
    }
    this.isLoadingAll = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      this.accounts = await AccountStore.loadAll(context);
      this.sources = await CalendarDataService.loadSources(context);
      // 显示方式（时间轴 / 列表）可能在设置页被改过，每次回到前台都重新读一次
      this.displayStyle = await AppSettings.getDisplayStyle(context);
      await this.reloadEvents();
      try {
        await CardDataService.pushToAllForms(context);
      } catch (err) {}
      this.startAutoSync();
    } finally {
      this.isLoadingAll = false;
      if (this.pendingReload) {
        this.pendingReload = false;
        setTimeout(() => {
          this.reloadAll().catch(() => {});
        }, 60);
      }
    }
  }

  /** 自动同步：每 15 秒检查一次，到达设置的间隔（AppStorage.syncIntervalMinutes）才真正同步 */
  private startAutoSync(): void {
    if (this.autoSyncTimer === -1) {
      // ⭐ 0.0.8：默认间隔 1 分钟 → 15 分钟（见 AppSettings.getSyncIntervalMinutes 注释）
      AppStorage.setOrCreate('syncIntervalMinutes', 15);
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
        const minutes: number = AppStorage.get<number>('syncIntervalMinutes') ?? 15;
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

    // 计算覆盖 [上月前14天, 下月后14天] 的完整时间区间，确保三页 Swiper 的所有 42 格数据完整
    const prevMonth = this.addMonths(this.displayYear, this.displayMonth, -1);
    const prevStart: number = new Date(prevMonth[0], prevMonth[1], 1).getTime();
    const nextMonth = this.addMonths(this.displayYear, this.displayMonth, 1);
    const nextEnd: number = new Date(nextMonth[0], nextMonth[1] + 1, 0, 23, 59, 59).getTime();

    const rangeStart: number = Math.min(prevStart - 14 * 86400000, this.selectedDate - 14 * 86400000);
    const rangeEnd: number = Math.max(nextEnd + 14 * 86400000, this.selectedDate + 14 * 86400000);

    this.showTodosInCalendar = await AppSettings.getShowTodosInCalendar(context);
    this.events = await CalendarDataService.loadEvents(context, rangeStart, rangeEnd, this.sources);
    this.todos = await CalendarDataService.loadTodos(context, this.sources);
    this.buildEventsByDay();
    LogUtil.write(`界面刷新完成：日程 ${this.events.length} 条（显示区间内），待办 ${this.todos.length} 条`);
    this.rebuildPagesFor(this.displayYear, this.displayMonth);
    this.rebuildDayTimeline();
    // 当前正处于列表视图时立即重载，避免同步后列表空白
    if (this.mode === 'agenda') {
      await this.ensureAgendaData();
    }
    this.loading = false;
    this.dataVersion++;
  }

  /** 将事件按天构建哈希索引，供 buildMonthCells $O(1)$ 快速提取 */
  private buildEventsByDay(): void {
    const map = new Map<number, DisplayEvent[]>();
    for (const e of this.events) {
      const startDay = this.startOfDay(e.startTime);
      let endDay = startDay;
      const fest: number[] | null = normalizeSingleDayIfFestival(e.title, e.startTime, e.endTime, e.isAllDay);
      if (fest !== null) {
        endDay = dayStartMs(fest[1]);
      } else {
        // 半开区间判定：如果结束时间在某天 00:00:00，则实际属于前一天结束，不计入下一天！
        const effectiveEnd = (e.endTime > e.startTime) ? (e.endTime - 1) : e.startTime;
        endDay = this.startOfDay(effectiveEnd);
      }
      for (let t = startDay; t <= endDay; t += 86400000) {
        const arr = map.get(t);
        if (arr === undefined) {
          map.set(t, [e]);
        } else {
          arr.push(e);
        }
      }
    }

    // 修复问题 2：若用户开启「在日历中显示待办」，将有截止时间的待办合并投射到日程按天索引中
    if (this.showTodosInCalendar && this.todos.length > 0) {
      for (const t of this.todos) {
        if (t.startTime > 0) {
          const tDay = this.startOfDay(t.startTime);
          const arr = map.get(tDay);
          if (arr === undefined) {
            map.set(tDay, [t]);
          } else {
            if (!arr.some((x: DisplayEvent): boolean => x.id === t.id && x.kind === 'todo')) {
              arr.push(t);
            }
          }
        }
      }
    }

    this.eventsByDay = map;
  }

  /** 构建某年某月的 42 格 */
  /**
   * ⭐ 预先算出"有事件的日期"集合（按 dayStart 归一化）。
   *
   * 为什么要预计算：月视图一次渲染 42 个格子，若每格都去 filter 一遍全部事件，
   * 就是 O(42 × 事件数)；本机 15 个本、近 3000 条数据，翻月会明显卡顿。
   * 这里只遍历事件一次，把区间相交的每一天都塞进 Set，之后每格 O(1) 查询。
   *
   * 与 `eventsOfDate()` 用**完全相同**的区间相交口径
   * （`startOfDay(start) <= day && end >= day`），
   * 因此跨天/多天事件覆盖的每一天都会有点，不会出现"点进去有日程、格子上却没点"的不一致。
   * 另：待办（isTodo）不计入 —— 待办没有时间点语义，混进月视图会让点失去意义。
   */
  private buildEventDaySet(): Set<number> {
    const set: Set<number> = new Set<number>();
    for (const e of this.events) {
      const s: number = this.startOfDay(e.startTime);
      const end: number = e.endTime > 0 ? e.endTime : s;
      // 兜底：异常数据（end < start）或跨度大得离谱（>1 年）不入集合，避免循环失控
      if (end < s || end - s > 366 * 86400000) {
        set.add(s);
        continue;
      }
      for (let t = s; t <= end; t += 86400000) {
        set.add(this.startOfDay(t));
      }
    }
    return set;
  }

  private buildMonthCells(year: number, month: number): MonthCell[] {
    const first: number = new Date(year, month, 1).getTime();
    const firstDay = new Date(first).getDay();
    const offset: number = (firstDay + 6) % 7; // 周一为一周开始
    const gridStart: number = first - offset * 86400000;
    const todayStart: number = this.startOfDay(Date.now());
    const eventDays: Set<number> = this.buildEventDaySet();
    // 诊断：本次构建里 hasEvent=true 的格子数（用于排查"首屏不变色"）
    let flagTrue: number = 0;
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
      cell.hasEvent = eventDays.has(this.startOfDay(dateMs));
      cell.events = this.eventsOfDate(dateMs);
      cell.hasEvents = cell.events.length > 0;
      if (cell.hasEvent || cell.hasEvents) {
        flagTrue++;
      }
      const hInfo: HolidayInfo | null = HolidayUtil.getHoliday(dateMs);
      if (hInfo !== null) {
        cell.holidayBadge = hInfo.badge;
        cell.holidayType = hInfo.type;
        const hName: string = HolidayUtil.getName(dateMs);
        if (hName !== '' && !cell.lunar.includes('节气')) {
          cell.lunar = hName.length > 3 ? hName.substring(0, 2) : hName;
        }
      }
      }
      cells.push(cell);
    }
    if (month >= 0) {
      LogUtil.write(`月视图构建 ${year}-${month + 1}：事件 ${this.events.length} 条，`
        + `有事件的日期 ${eventDays.size} 天，本页命中 ${flagTrue} 格，`
        + `版本 v${this.monthDataVersion}`);
    }
    return cells;
  }

  /** 重建三页（上月/本月/下月） */
  private rebuildPages(): void {
    this.rebuildPagesFor(this.displayYear, this.displayMonth);
  }

  /**
   * 按**显式传入的年月**重建三页。
   *
   * ⭐ 为什么需要这个版本：ArkUI 的 @State 赋值在同一个同步调用栈内
   *    **不一定立即反映到后续读取**（实测：先 `this.displayMonth = 12`
   *    再 `rebuildPages()`，里面读到的仍是 11）。
   *    翻月这种"改状态 + 立刻据此重建"的场景，必须把值用参数传下去，
   *    不能依赖 `this.displayMonth` 的可读时机 —— 否则中间页会停留在旧月份，
   *    表现为"闪回上个月再跳回来"。
   */
  private rebuildPagesFor(year: number, month: number): void {
    const prev = this.addMonths(year, month, -1);
    const next = this.addMonths(year, month, 1);
    this.monthPages = [
      this.buildMonthCells(prev[0], prev[1]),
      this.buildMonthCells(year, month),
      this.buildMonthCells(next[0], next[1])
    ];
    // 自增版本号，强制外层 ForEach 重建（见字段注释）
    this.monthDataVersion = this.monthDataVersion + 1;
    this.rebuildDayTimeline();
  }

  /** 获取从今天开始未来指定天数（如3天、7天）的所有日程并按时间排序去重 */
  private getRangeEvents(days: number): DisplayEvent[] {
    const today = this.startOfDay(Date.now());
    const seen = new Set<string>();
    const result: DisplayEvent[] = [];
    for (let i = 0; i < days; i++) {
      const dayMs = today + i * 86400000;
      const dayList = this.eventsByDay.get(dayMs) ?? [];
      for (const e of dayList) {
        const key = `${e.isSystem ? 's' : 'l'}_${e.id}_${e.startTime}`;
        if (!seen.has(key)) {
          seen.add(key);
          result.push(e);
        }
      }
    }
    result.sort((a: DisplayEvent, b: DisplayEvent) => a.startTime - b.startTime);
    return result;
  }

  /** 获取未来多天聚合标题，如：未来3天 (10月31日 - 11月2日) */
  private getRangeTitle(days: number): string {
    const today = this.startOfDay(Date.now());
    const endDay = today + (days - 1) * 86400000;
    const d1 = new Date(today);
    const d2 = new Date(endDay);
    const m1 = d1.getMonth() + 1;
    const day1 = d1.getDate();
    const m2 = d2.getMonth() + 1;
    const day2 = d2.getDate();
    const rangeStr = m1 === m2 ? `${m1}月${day1}日 - ${day2}日` : `${m1}月${day1}日 - ${m2}月${day2}日`;
    return `未来${days}天 (${rangeStr})`;
  }

  /** 多天模式下日程卡片的日期前缀，如：今天、明天、后天、11月3日 */
  private fmtEventDatePrefix(e: DisplayEvent): string {
    const todayStart = this.startOfDay(this.nowMs);
    const eventDayStart = this.startOfDay(e.startTime);
    const diffDays = Math.round((eventDayStart - todayStart) / 86400000);
    if (diffDays === 0) {
      return '今天 ';
    } else if (diffDays === 1) {
      return '明天 ';
    } else if (diffDays === 2) {
      return '后天 ';
    } else {
      const d = new Date(e.startTime);
      return `${d.getMonth() + 1}月${d.getDate()}日 `;
    }
  }

  /** 顶部切换 今天 / 三天 / 七天 范围模式 */
  private selectTopRange(key: string): void {
    this.topRangeMode = key;
    const now = new Date();
    const needReload = (this.displayYear !== now.getFullYear() || this.displayMonth !== now.getMonth());
    this.displayYear = now.getFullYear();
    this.displayMonth = now.getMonth();
    this.selectedDate = this.startOfDay(now.getTime());
    this.swiperController.changeIndex(1, false);
    this.expandedSwiperController.changeIndex(1, false);
    if (needReload) {
      this.rebuildPages();
      this.reloadEvents();
    } else {
      this.rebuildDayTimeline();
    }
  }

  /** 点击月历/周条中的日期单元格：切换到该单日，并更新顶部选中状态 */
  private selectDayCell(dateMs: number): void {
    const today = this.startOfDay(Date.now());
    this.topRangeMode = (dateMs === today) ? 'today' : '';
    this.selectedDate = dateMs;
    this.rebuildDayTimeline();

  /**
   * 当天截止、尚未完成的待办（#45 待办投射到日历）。
   * 待办的 DUE 存在 startTime；只有未完成且有截止时间的才显示。
   */
  private todosDueOn(dateMs: number): DisplayEvent[] {
    const day: number = this.startOfDay(dateMs);
    const out: DisplayEvent[] = this.todos.filter(
      (t: DisplayEvent): boolean => !t.completed && t.startTime > 0
        && this.startOfDay(t.startTime) === day);
    out.sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
    return out;
  }

  /** 重建"选中日"的时间轴布局（月/周视图下方那条） */
  private rebuildDayTimeline(): void {
    let dayEvents: DisplayEvent[] = [];
    if (this.topRangeMode === '3days') {
      dayEvents = this.getRangeEvents(3);
    } else if (this.topRangeMode === '7days') {
      dayEvents = this.getRangeEvents(7);
    } else {
      dayEvents = this.eventsOfDate(this.selectedDate);
    }
    this.selectedDayEvents = dayEvents.slice();
    this.dataVersion++;
    const tl: DayTimeline = TimelineUtil.build(dayEvents, this.selectedDate);
    tl.todos = this.todosDueOn(this.selectedDate);
    TimelineUtil.markNow(tl.blocks, this.nowMs);
    this.dayTimeline = tl;
    LogUtil.write(`时间轴(${this.fmtDateCn(this.selectedDate)})：模式 ${this.topRangeMode}，输入 ${dayEvents.length} 条 → 色块 ${tl.blocks.length} 块，全天/跨天 ${tl.allDay.length} 条，待办 ${tl.todos.length} 条`);
  }

  /** 选中日期变化（点月格/周条）→ 重算该日时间轴 */
  private onSelectedDateChange(): void {
    if (this.selectedDate !== this.startOfDay(Date.now())) {
      this.topRangeMode = '';
    } else if (this.topRangeMode === '') {
      this.topRangeMode = 'today';
    }
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
    d.todos = this.dayTimeline.todos;
    this.dayTimeline = d;
    this.agendaTimelines = this.agendaTimelines.slice();
  }

  private eventsOfDate(dateMs: number): DisplayEvent[] {
    return this.eventsByDay.get(dateMs) ?? [];
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
    this.topRangeMode = 'today';
    const now = new Date();
    this.displayYear = now.getFullYear();
    this.displayMonth = now.getMonth();
    this.selectedDate = this.startOfDay(now.getTime());
    this.rebuildPages();
    this.reloadEvents();
    this.swiperController.changeIndex(1, false);
    this.expandedSwiperController.changeIndex(1, false);
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
    // ⭐ KEEP_SELECTED_DAY 翻月后必须把选中日迁到新月份的同一天
    const lastDay: number = new Date(nm[0], nm[1] + 1, 0).getDate();
    this.selectedDate = new Date(nm[0], nm[1], Math.min(this.preferredDay, lastDay)).getTime();
    this.rebuildPagesFor(nm[0], nm[1]);
    this.swiperGuard = true;
    this.swiperController.changeIndex(1, false);
    this.expandedSwiperController.changeIndex(1, false);
    this.reloadEvents();
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
      // ⭐ 已有同步在进行中 → 提示"请耐心等待"，不报"失败"
      if (err instanceof SyncBusyError) {
        this.getUIContext().getPromptAction()
          .showToast({ message: '有同步任务正在进行中，请耐心等待' });
        return;
      }
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
    // ⭐ 是否因为"已有同步在进行"而被跳过（这不算失败，只提示等待）
    let busySkipped: boolean = false;
    // 备份模式：先把系统本地日历导入目标日历本（幂等），再随正常同步推送上服务器
    try {
      await SystemCalendarImport.importIfNeeded(context);
    } catch (err) {
      // 导入失败不影响正常同步
    }
    // 入站对账：把用户在系统日历里的改动读回来置 dirty，**必须在同步之前**，才能借本次同步一起推送
    try {
      await MirrorInbound.reconcile(context);
    } catch (err) {
      // 对账失败不影响正常同步
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
        // ⭐ 并发被互斥锁拦下：不是失败，只是"已有同步在跑"，稍后自动同步会覆盖，直接略过
        if (err instanceof SyncBusyError) {
          busySkipped = true;
          continue;
        }
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
    // 出站镜像：把服务器最新状态写进系统日历（自动化，无需手点）
    try {
      if (await AppSettings.getMirrorEnabled(context) && await SystemCalendarMirror.hasPermission()) {
        const mr = await SystemCalendarMirror.syncNow(context);
        LogUtil.write(`同步后自动镜像：本=${mr.books} 新增=${mr.added} 更新=${mr.updated} 删除=${mr.deleted}`);
      }
    } catch (err) {
      // 镜像失败不影响同步结果
    }
    this.syncing = false;
    await ScreenKeeper.release(context as common.UIAbilityContext);
    if (failMsg !== '') {
      this.getUIContext().getPromptAction()
        .showToast({ message: ok > 0 ? `同步完成 ${ok} 个，失败：${failMsg}` : `同步失败：${failMsg}` });
    } else if (busySkipped && ok === 0) {
      // 全部账号都因"已有同步在进行"被跳过 → 只提示等待，不说失败
      this.getUIContext().getPromptAction()
        .showToast({ message: '有同步任务正在进行中，请耐心等待' });
    } else if (ok > 0 && manual) {
      this.getUIContext().getPromptAction()
        .showToast({ message: `同步完成（${ok} 个账号）` });
    }
    // 同步完成后重新读库并重建月格。
    // ⚠️ reloadAll() 内部已包含 reloadEvents()，这里不要重复调用 ——
    //    只在"同步确实拉到了新数据"时再刷一次，避免多余的重建开销。
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
    if (e.kind === 'todo') {
      AppStorage.setOrCreate<number>('pendingTodoId', e.id);
      router.pushUrl({ url: 'pages/TodoEditPage' });
      return;
    }
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
    // 高德鸿蒙深链 dlat/dlon 为必填（dname 仅作名称显示），先地理编码拿坐标。
    // 地理编码（getAddressesFromLocationName）在本 SDK 上不要求定位权限，
    // 因此这里既不申请、也不使用定位权限 —— 应用自始至终不读取设备实时位置。
    const coords: number[] | null = await this.geocodeAddress(address);
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

  /** 正向地理编码：地址 → 坐标（系统服务，无需高德 key、无需定位权限） */
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
    Column() {
      if (this.detailSheetMode === 'scope') {
        this.scopeContent()
      } else if (this.detailSheetMode === 'confirm') {
        this.confirmDeleteContent()
      } else {
        this.detailMainContent()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  scopeContent() {
    Column({ space: 10 }) {
      Text('删除重复日程')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 4 })

      Text('这是一个重复日程，请选择作用的范围')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 10 })

      this.scopeOptionCard('one', '仅删除这一次', '只影响所选日期的这一次，其余保持不变')
      this.scopeOptionCard('future', '删除此次及以后', '从这一次开始到最后一次都删除')
      this.scopeOptionCard('all', '删除全部', '整条重复日程的所有发生都删除')

      Text('取消')
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 18, bottom: 12 })
        .onClick(() => {
          this.detailSheetMode = 'detail';
        })
    }
    .width('100%')
  }

  @Builder
  scopeOptionCard(mode: string, title: string, desc: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(mode === 'all' ? '#E64545' : $r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)
      Text(desc)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(14)
    .backgroundColor($r('app.color.card_bg'))
    .onClick(() => {
      this.executeDeleteDetail(mode);
    })
  }

  @Builder
  confirmDeleteContent() {
    Column({ space: 14 }) {
      Text('删除日程')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 16, bottom: 4 })

      Text(this.detailEvent !== null && this.detailEvent.title !== ''
        ? `确定要删除日程「${this.detailEvent.title}」吗？`
        : '确定要删除这条日程吗？')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ left: 20, right: 20, bottom: 20 })

      Button('确认删除')
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor('#E64545')
        .borderRadius(22)
        .onClick(() => {
          this.executeDeleteDetail('all');
        })

      Button('取消')
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(22)
        .onClick(() => {
          this.detailSheetMode = 'detail';
        })
    }
    .width('100%')
  }

  @Builder
  detailMainContent() {
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
          Button() {
            Row({ space: 4 }) {
              Text('⎘')
                .fontSize(12)
                .fontColor(('app.color.brand'))
              Text('分享')
                .fontSize(12)
                .fontColor(('app.color.brand'))
            }
          }
          .height(28)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: ('app.color.brand') })
          .borderRadius(14)
          .padding({ left: 8, right: 8 })
          .margin({ right: 6 })
          .onClick(() => {
            this.shareEventIcs();
          })
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
      // 可写日程：详情底部提供"转为待办"、"编辑"与"删除"入口（系统/只读日程无此按钮）
      if (this.detailEvent !== null && !this.detailEvent.isSystem && this.detailEvent.writable) {
        Row({ space: 8 }) {
          Button('转为待办')
            .layoutWeight(1)
            .height(44)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
            .backgroundColor($r('app.color.chip_off_bg'))
            .borderRadius(22)
            .onClick(() => {
              this.askConvertDetailToTodo();
            })

          Button('编辑日程')
            .layoutWeight(1)
            .height(44)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.button_text'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius(22)
            .onClick(() => {
              const id: number = this.detailEvent !== null ? this.detailEvent.id : 0;
              const occ: number = this.detailEvent !== null ? this.detailEvent.startTime : 0;
              this.detailShow = false;
              if (id > 0) {
                AppStorage.setOrCreate<number>('pendingEventId', id);
                AppStorage.setOrCreate<number>('pendingOccurrenceTs', occ);
                router.pushUrl({ url: 'pages/EventEditPage' });
              }
            })

          Button('删除')
            .width(68)
            .height(44)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#E64545')
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: '#E64545' })
            .borderRadius(22)
            .onClick(() => {
              if (this.detailEvent !== null) {
                if (this.detailEvent.recurring) {
                  this.detailSheetMode = 'scope';
                } else {
                  this.detailSheetMode = 'confirm';
                }
              }
            })
        }
        .width('100%')
        .padding({ top: 8, bottom: 4 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 将详情弹层中的日程转换为待办事项 */
  private askConvertDetailToTodo(): void {
    if (this.detailEvent === null) {
      return;
    }
    const target = this.detailEvent;
    const label: string = target.title.trim() === '' ? '该日程' : `「${target.title.trim()}」`;
    this.getUIContext().showAlertDialog({
      title: '转换为待办',
      message: `确定要将${label}转换为待办事项吗？\n\n转换后该项将从日程视图移至待办清单中。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '确定转换',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.executeConvertDetailToTodo(target.id);
        }
      }
    });
  }

  private async executeConvertDetailToTodo(eventId: number): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.detailShow = false;
    const ok = await CalendarDataService.convertEventToTodo(ctx, eventId);
    if (ok) {
      try {
        await CardDataService.pushToAllForms(ctx);
      } catch (err) {}
      this.getUIContext().getPromptAction().showToast({ message: '已成功转换为待办事项' });
      await this.reloadAll();
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '转换失败' });
    }
  }

  private async executeDeleteDetail(scope: string): Promise<void> {
    const target: DisplayEvent | null = this.detailEvent;
    if (target === null) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      const cur: LocalEvent | null = await EventDb.getById(context, target.id);
      if (cur === null) {
        this.detailShow = false;
        return;
      }
      if (!target.recurring || scope === 'all') {
        if (target.recurring) {
          await EventDb.markDeletedByUid(context, cur.calKey, cur.uid);
        } else {
          await EventDb.markDeleted(context, cur.id);
        }
        // 立即从当前内存列表清除该日程
        this.events = this.events.filter((e: DisplayEvent): boolean =>
          target.recurring ? !(e.calKey === cur.calKey && e.id === cur.id) : e.id !== cur.id);
      } else if (scope === 'one') {
        const boundsOcc: number = target.startTime;
        let master: LocalEvent | null = cur;
        if (cur.rrule === '' && cur.recurrenceId > 0) {
          master = await EventDb.getMasterByUid(context, cur.calKey, cur.uid);
        }
        if (master !== null) {
          const exList: string[] = master.exdate === '' ? [] : master.exdate.split(';');
          const occIcs: string = IcsUtil.fmtIcsTime(boundsOcc, master.isAllDay);
          if (!exList.includes(occIcs)) {
            exList.push(occIcs);
          }
          await EventDb.setExdate(context, master.id, exList.join(';'));
          const rows: LocalEvent[] = await EventDb.queryByUid(context, cur.calKey, cur.uid);
          for (const r of rows) {
            if (r.rrule === '' && r.recurrenceId > 0 && Math.abs(r.recurrenceId - boundsOcc) < 12 * 3600000) {
              await EventDb.markDeleted(context, r.id);
            }
          }
        } else if (cur.rrule === '' && cur.recurrenceId > 0) {
          await EventDb.markDeleted(context, cur.id);
        }
        // 立即从内存中过滤掉该次发生
        this.events = this.events.filter((e: DisplayEvent): boolean =>
          !(e.id === target.id && e.startTime === target.startTime));
      } else if (scope === 'future') {
        const boundsOcc: number = target.startTime;
        let master: LocalEvent | null = cur;
        if (cur.rrule === '' && cur.recurrenceId > 0) {
          master = await EventDb.getMasterByUid(context, cur.calKey, cur.uid);
        }
        if (master !== null) {
          const beforeThis: number = boundsOcc - 1000;
          const truncated: string = IcsUtil.rruleWithUntil(master.rrule, beforeThis);
          await EventDb.setRruleForUid(context, master.calKey, master.uid, truncated);
          await EventDb.purgeByUidFrom(context, master.calKey, master.uid, boundsOcc);
        }
        // 立即从当前内存过滤掉该时间及以后的发生
        this.events = this.events.filter((e: DisplayEvent): boolean =>
          !(e.id === target.id && e.startTime >= boundsOcc));
      }

      this.detailShow = false;
      this.detailSheetMode = 'detail';
      this.detailEvent = null;

      // 立即刷新内存与视图
      this.buildEventsByDay();
      this.rebuildPages();
      this.rebuildDayTimeline();
      if (this.mode === 'agenda') {
        this.ensureAgendaData().catch(() => {});
      }
      this.dataVersion++;

      this.getUIContext().getPromptAction().showToast({ message: '日程已删除' });

      // 1) 后台异步推送 CalDAV 服务器（经 triggerPush 串行保护，避免与全量拉取竞态）
      if (cur.href !== '') {
        CalendarDataService.triggerPush(context, cur.href).catch((err: Error) => {
          LogUtil.write(`异步推送删除失败: ${err.message}`);
        });
      }

      // 2) 刷新通知提醒
      try {
        ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (e) {
        // 忽略
      }

      // 3) 联动清理系统日历中的镜像事件
      try {
        if (await AppSettings.getMirrorEnabled(context) && await SystemCalendarMirror.hasPermission()) {
          SystemCalendarMirror.syncNow(context).catch((err: Error) => {
            LogUtil.write(`详情弹窗删除后同步清理系统日历失败: ${err.message}`);
          });
        }
      } catch (err) {
        // 忽略
      }

      // 4) 联动刷新桌面服务卡片
      try {
        CardDataService.pushToAllForms(context);
      } catch (err) {
        // 忽略
      }
    } catch (err) {
      const ex = err as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: `删除失败: ${ex.message}` });
    }
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
        } else if (this.mode === 'month_expanded') {
          this.monthExpandedBody()
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

      // 全局日程搜索覆盖层
      this.searchModal()


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
        // ⭐ 职责感知：待办视图下新建待办，其余视图新建日程。
        if (this.mode === 'todo') {
          this.openTodoCreator();
        } else {
          this.addEvent();
        }
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

      // ⭐ TODO_EDITOR_UI 待办编辑弹框（覆盖层方案：同一组件只能挂一个 bindSheet）
      if (this.todoEditShow) {
        this.todoEditorOverlay()
      }

      // ⭐ 父任务选择弹层（子任务支持）
      if (this.todoParentPickShow) {
        this.todoParentPickerOverlay()
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
    // 沉浸式：根容器背景延伸到状态栏/导航条区域（只扩绘制、不移动子组件），
    // 配合 EntryAbility 里"系统栏透明"的设置，彻底消除顶部通知栏与底部灰条。
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.detailShow, this.detailSheet(), {
      height: 540,
      dragBar: true,
      showClose: false, // 关闭按钮自绘在标题行右侧，避免系统按钮压住徽标
      backgroundColor: $r('app.color.page_bg')
    })
  }

  /**
   * 页面转场：淡入淡出。
   * 不做左右平移 / 上下位移（不调用 .slide() / .translate()），只做透明度变化，
   * 避免单帧直接切换；曲线使用弹簧曲线（springMotion）。
   */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.None, duration: 300, curve: curves.springMotion(0.35, 0.75) })
      .opacity(0);
    PageTransitionExit({ type: RouteType.None, duration: 250, curve: curves.springMotion(0.35, 0.75) })
      .opacity(0);
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
      Text('欢迎使用「小褚日历」。在使用前，请阅读并同意以下条款。')
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
          this.openDoc(AppSettings.PRIVACY_TITLE, $rawfile('privacy.html'));
        })
      Button('《用户服务协议》')
        .width('100%')
        .fontSize(14)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.brand'))
        .onClick(() => {
          this.openDoc(AppSettings.AGREEMENT_TITLE, $rawfile('user_agreement.html'));
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
  topRangeSelector() {
    Row({ space: 2 }) {
      this.topRangeItem('today', '今天')
      this.topRangeItem('3days', '三天')
      this.topRangeItem('7days', '七天')
    }
    .padding(2)
    .borderRadius(15)
    .backgroundColor($r('app.color.chip_off_bg'))
    .margin({ right: 6 })
  }

  @Builder
  topRangeItem(key: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.topRangeMode === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.topRangeMode === key ? $r('app.color.button_text') : $r('app.color.text_secondary'))
      .backgroundColor(this.topRangeMode === key ? $r('app.color.brand') : Color.Transparent)
      .borderRadius(13)
      .height(26)
      .padding({ left: 8, right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.selectTopRange(key);
      })
  }

  /** 触发全局模糊搜索 */
  private async triggerSearch(kw: string): Promise<void> {
    this.searchQuery = kw;
    const trimmed = kw.trim();
    if (trimmed === '') {
      this.searchResults = [];
      this.searchLoading = false;
      return;
    }
    this.searchLoading = true;
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      const results = await CalendarDataService.searchEvents(ctx, trimmed, this.sources);
      this.searchResults = results;
    }
    this.searchLoading = false;
  }

  /** 点击搜索结果：收起搜索面板并精准定位至该日程 */
  private pickSearchResult(e: DisplayEvent): void {
    this.searchOpen = false;
    const dayStart = this.startOfDay(e.startTime);
    this.selectedDate = dayStart;
    const d = new Date(dayStart);
    if (d.getFullYear() !== this.displayYear || d.getMonth() !== this.displayMonth) {
      this.displayYear = d.getFullYear();
      this.displayMonth = d.getMonth();
      this.rebuildPages();
    }
    this.topRangeMode = (dayStart === this.startOfDay(Date.now())) ? 'today' : '';
    this.rebuildDayTimeline();
    this.openEvent(e);
  }

  /** 全局搜索浮层面板 */
  @Builder
  searchModal() {
    if (this.searchOpen) {
      Stack({ alignContent: Alignment.Top }) {
        // 半透明背景遮罩
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#80000000')
          .onClick(() => {
            this.searchOpen = false;
          })

        // 搜索面板
        Column({ space: 10 }) {
          // 搜索栏
          Row({ space: 8 }) {
            Row({ space: 6 }) {
              Text('🔍')
                .fontSize(14)
              TextInput({ text: this.searchQuery, placeholder: '搜索日程标题、地点、描述…' })
                .layoutWeight(1)
                .height(38)
                .fontSize(14)
                .backgroundColor(Color.Transparent)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_hint'))
                .onChange((v: string) => {
                  this.triggerSearch(v);
                })
              if (this.searchQuery !== '') {
                Button() {
                  Text('✕')
                    .fontSize(12)
                    .fontColor($r('app.color.text_hint'))
                }
                .width(24)
                .height(24)
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  this.triggerSearch('');
                })
              }
            }
            .layoutWeight(1)
            .height(42)
            .padding({ left: 10, right: 8 })
            .borderRadius(10)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.shadow_color') })

            Button('取消')
              .fontSize(14)
              .fontColor($r('app.color.brand'))
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.searchOpen = false;
              })
          }
          .width('100%')

          // 结果列表
          if (this.searchLoading) {
            Row({ space: 8 }) {
              LoadingProgress().width(20).height(20).color($r('app.color.brand'))
              Text('正在搜索…').fontSize(13).fontColor($r('app.color.text_hint'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(20)
          } else if (this.searchQuery.trim() !== '' && this.searchResults.length === 0) {
            Text('未找到匹配的日程')
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(30)
          } else if (this.searchResults.length > 0) {
            Text(`找到 ${this.searchResults.length} 条日程`)
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .padding({ left: 4 })

            List({ space: 8 }) {
              ForEach(this.searchResults, (e: DisplayEvent) => {
                ListItem() {
                  Row({ space: 10 }) {
                    Column()
                      .width(4)
                      .height(40)
                      .borderRadius(2)
                      .backgroundColor(e.color)
                    Column({ space: 3 }) {
                      Text(e.title)
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Row({ space: 8 }) {
                        Text(this.fmtDateCn(e.startTime))
                          .fontSize(12)
                          .fontColor($r('app.color.text_secondary'))
                        Text(e.isAllDay ? '全天' : `${this.fmtTime(e.startTime)} - ${this.fmtTime(e.endTime)}`)
                          .fontSize(12)
                          .fontColor($r('app.color.text_hint'))
                      }
                      if (e.location !== '') {
                        Text(`📍 ${e.location}`)
                          .fontSize(11)
                          .fontColor($r('app.color.text_hint'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (e.calName !== '') {
                      Text(e.calName)
                        .fontSize(11)
                        .fontColor(e.color)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: '28%' })
                    }
                  }
                  .alignItems(VerticalAlign.Center)
                  .width('100%')
                  .padding(10)
                  .borderRadius(10)
                  .backgroundColor($r('app.color.card_bg'))
                  .border({ width: 1, color: $r('app.color.shadow_color') })
                  .onClick(() => {
                    this.pickSearchResult(e);
                  })
                }
              }, (e: DisplayEvent) => `search_${e.id}_${e.startTime}`)
            }
            .width('100%')
            .layoutWeight(1)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        .height('75%')
        .padding({ left: 16, right: 16, top: 16, bottom: 20 })
        .borderRadius({ bottomLeft: 16, bottomRight: 16 })
        .backgroundColor($r('app.color.page_bg'))
        .shadow({ radius: 16, color: '#40000000', offsetY: 6 })
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  header() {
    Row({ space: 8 }) {
      Image($r('app.media.app_icon'))
        .width(30)
        .height(30)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
      Text('小褚日历')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Blank()
      this.topRangeSelector()
      // 右侧操作按钮组（内收留白防贴边，远离曲面返回手势热区）
      Row({ space: 8 }) {
        // 🔍 搜索按钮
        Button() {
          Text('🔍')
            .fontSize(13)
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1, color: $r('app.color.shadow_color') })
        .onClick(() => {
          this.searchOpen = true;
        })

        // ≡ 菜单按钮
        Button() {
          Column({ space: 3.5 }) {
            Row().width(14).height(1.5).backgroundColor($r('app.color.brand')).borderRadius(1)
            Row().width(14).height(1.5).backgroundColor($r('app.color.brand')).borderRadius(1)
            Row().width(14).height(1.5).backgroundColor($r('app.color.brand')).borderRadius(1)
          }
          .alignItems(HorizontalAlign.Center)
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1, color: $r('app.color.shadow_color') })
        .onClick(() => {
          this.menuOpen = !this.menuOpen;
        })
      }
      .margin({ right: 6 })
    }
    .width('100%')
    .padding({ left: 16, right: 24, top: 10, bottom: 8 })
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
        // 联系人（CardDAV 通讯录）
        Row({ space: 10 }) {
          Text('📇')
            .fontSize(13)
            .width(16)
            .textAlign(TextAlign.Center)
          Text('联系人')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        .height(40)
        .borderRadius(8)
        .padding({ left: 12 })
        .onClick(() => {
          this.menuOpen = false;
          router.pushUrl({ url: 'pages/ContactListPage' });
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
      .shadow({ radius: 12, color: $r('app.color.shadow_color'), offsetY: 4 })
      .margin({ top: 54, right: 26 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  modeTabs() {
    Row({ space: 4 }) {
      this.modeTab('month', '月')
      this.modeTab('month_expanded', '全月')
      this.modeTab('week', '周')
      this.modeTab('agenda', '列表')
      this.modeTab('todo', '待办')
      Blank()
      if (this.mode === 'todo') {
        Text(this.todos.filter((t: DisplayEvent): boolean => !t.completed).length + ' 项未完成')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      } else if (this.mode === 'month' || this.mode === 'month_expanded') {
        Text(this.fmtMonthTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      } else if (this.mode === 'todo') {
        // 待办与具体日期无关，显示剩余未完成数量更有用
        Text(`${this.todos.filter((t: DisplayEvent): boolean => !t.completed).length} 项待办`)
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
    // 间距与月视图保持一致（space: 2）：周条原来用 4，7 天多吃了 12px，
    // 每格从 149 缩到 133，圆就只能跟着变小 —— 这才是"圆不够大"的根因。
    Row({ space: 2 }) {
      // ⭐ WEEK_REUSE 直接复用月视图的日期格 dayCellCircle，不再单独实现。
      //    周条一行就是 7 天，和月视图一行结构完全相同，另写一套只会不一致
      //    （之前就因为圆的大小/字号/间距三处各调一遍，怎么调都对不齐）。
      //    复用后选中圆、今天圆、农历、事件点天然与月视图一致。
      ForEach(this.weekStripDays(), (cell: MonthCell) => {
        Column({ space: 2 }) {
          Text(WEEK_LABELS[(new Date(cell.dateMs).getDay() + 6) % 7])
            .fontSize(11)
            // ⚠️ 这里原来用 button_text（纯白），但该标签**没有背景**、坐在页面底色上，
            //    浅色模式下是"白字压浅灰底"→ 对比度仅 1.11:1（应用市场 UX 检测被判不合格）。
            //    改用 brand_text（品牌色文字版）：浅 #0057C2 → 6.01:1，深 #4DA3FF → 8.0:1，
            //    既保留"选中"的强调含义，又满足对比度要求。
            .fontColor(cell.dateMs === this.selectedDate
              ? $r('app.color.brand_text') : $r('app.color.text_hint'))
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
          Row() {
            if (cell.hasEvents) {
              Circle({ width: 4, height: 4 })
                .fill(cell.dateMs === this.selectedDate ? $r('app.color.brand') : '#FF3B30')
            }
          }
          .height(4)
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.Center)
        }
        .layoutWeight(1)
        .onClick(() => {
          this.selectDayCell(cell.dateMs);
        })
      }, (cell: MonthCell) => `${this.dataVersion}_${cell.dateMs}_${cell.dateMs === this.selectedDate}_${cell.hasEvents}_${cell.events.length}`)
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
    // ⭐ WEEK_DOT 周条也要显示圆点 ⇒ 与月视图共用同一份"有事件日期"集合，
    //    口径完全一致（区间相交，跨天事件覆盖的每天都算）。
    const eventDays: Set<number> = this.buildEventDaySet();
    const cells: MonthCell[] = [];
    for (let i = 0; i < 7; i++) {
      const dateMs: number = weekStart + i * 86400000;
      const cell = new MonthCell();
      cell.dateMs = dateMs;
      cell.day = new Date(dateMs).getDate();
      cell.isToday = dateMs === todayStart;
      cell.lunar = LunarUtil.lunarDayText(dateMs);
      cell.hasEvent = eventDays.has(this.startOfDay(dateMs));
      cell.events = this.eventsOfDate(dateMs);
      cell.hasEvents = cell.events.length > 0;
      cell.inMonth = true;
      cells.push(cell);
    }
    return cells;
  }

  @Builder
  monthBody() {
    if (this.wideLayout) {
      // 宽屏（平板 / 折叠屏展开态）：左右双栏——左侧月历，右侧当日日程
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
        this.monthExpandHandle()
        this.dayPanelHeader()
        this.eventList()
      }
      .width('100%')
      .layoutWeight(1)
      .transition(this.modeTransition())
    }
  }

  /** 月历展开把手（参考图2胶囊条，点击展开全月视图） */
  @Builder
  monthExpandHandle() {
    Row() {
      Row()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.text_hint'))
        .opacity(0.35)
    }
    .width('100%')
    .height(16)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.switchModeAnimated('month_expanded');
    })
  }

  /** 全月视图底部收起把手（参考图3） */
  @Builder
  monthCollapseHandle() {
    Row() {
      Column({ space: 1 }) {
        Text('︿')
          .fontSize(16)
          .fontColor($r('app.color.text_hint'))
          .opacity(0.8)
        Text('收起')
          .fontSize(10)
          .fontColor($r('app.color.text_hint'))
      }
      .width('100%')
      .height(36)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      this.switchModeAnimated('month');
    })
  }

  /** 全月展开视图（参考图3：占满主区域，每个日期格内直接展示具体事项与+N） */
  @Builder
  monthExpandedBody() {
    Column() {
      // 星期表头
      this.monthWeekHeader()

      // 全月日历大网格 Swiper
      Swiper(this.expandedSwiperController) {
        ForEach(this.monthPages, (cells: MonthCell[], pIdx: number) => {
          Column() {
            ForEach(this.chunkCells(cells), (week: MonthCell[], idx: number) => {
              Row() {
                ForEach(week, (cell: MonthCell) => {
                  this.dayCellExpanded(cell)
                }, (cell: MonthCell) => `${this.dataVersion}_${cell.dateMs}_${cell.dateMs === this.selectedDate}_${cell.hasEvents}_${cell.events.length}`)
              }
              .width('100%')
              .layoutWeight(1)
            }, (week: MonthCell[], idx: number) => String(idx))
          }
          .width('100%')
          .height('100%')
        }, (cells: MonthCell[], pIdx: number) => `${this.dataVersion}_ep_${pIdx}_${cells[0]?.dateMs ?? 0}`)
      }
      .index(1)
      .loop(false)
      .indicator(false)
      .width('100%')
      .layoutWeight(1)
      .onAnimationEnd((index: number) => {
        this.handleSwiperChange(index);
      })

      // 底部收起按钮（参考图3）
      this.monthCollapseHandle()
    }
    .width('100%')
    .layoutWeight(1)
    .transition(this.modeTransition())
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
      ForEach(this.monthPages, (cells: MonthCell[], pIdx: number) => {
        Column({ space: 2 }) {
          ForEach(this.chunkCells(cells), (week: MonthCell[], idx: number) => {
            Row({ space: 2 }) {
              // ⭐ key 必须包含影响渲染的**全部**状态：hasEvent / isToday /
              //    是否选中。只放 dateMs+选中态时，数据加载完成后 hasEvent 从
              //    false 变 true 但 key 没变 ⇒ ArkUI 复用旧组件、跳过重绘，
              //    表现为"首屏农历不变红，切一次视图才正常"。
              ForEach(week, (cell: MonthCell) => {
                this.dayCell(cell)
              }, (cell: MonthCell) => `${this.dataVersion}_${cell.dateMs}_${cell.dateMs === this.selectedDate}_${cell.hasEvents}_${cell.events.length}`)
            }
            .width('100%')
            .layoutWeight(this.wideLayout ? 1 : 0)
          // 用"这一周首日的 dateMs"当 key，而不是序号：跨月翻页时序号会重复，
          // 会让 ArkUI 误以为是同一周而复用旧节点。
          }, (week: MonthCell[], idx: number) => `wk${week.length > 0 ? week[0].dateMs : idx}`)
        }
        .width('100%')
        // 注意：不要给页面设百分比高度——竖屏时 Swiper 是自然高度，
        // 子组件 height('100%') 对 auto 父容器解析为 0，整月网格会塌陷
      }, (cells: MonthCell[], pIdx: number) => `${this.monthDataVersion}_p_${pIdx}_${cells.length > 0 ? cells[0].dateMs : 0}`)
    }
    .index(1)
    .loop(false)
    .indicator(false)
    .width('100%')
    .layoutWeight(this.wideLayout ? 1 : 0)
    .onAnimationEnd((index: number) => {
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
      if (this.topRangeMode === '3days') {
        Text(this.getRangeTitle(3))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
        Blank()
        Text(`共 ${this.selectedDayEvents.length} 条`)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      } else if (this.topRangeMode === '7days') {
        Text(this.getRangeTitle(7))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
      Blank()
        Text(`共 ${this.selectedDayEvents.length} 条`)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      } else {
        Text(this.fmtDateCn(this.selectedDate))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(this.fmtMonthTitle())
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
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

  /**
   * ⭐ TODO_TAB_FACT 待办标签是否显示 —— 只看**事实**，不看声明。
   *
   * 判定：`this.todos` 里是否有数据。
   *
   * 为什么不再判断"有没有勾选待办本"：
   *   那个判定依赖 CalendarDataService.loadTodos 之外的 comps 字段，
   *   而 comps 来自服务器的 supported-calendar-component-set —— 实测本环境
   *   **拿不到这个属性**，字段恒为空 ⇒ 判定恒 false ⇒ 明明有待办也不显示标签。
   *   （这个 bug 就是这样产生的：数据同步成功了，标签却被前面的判定挡掉。）
   *
   * 而 `loadTodos` 内部已经按 `visibleKeys`（用户勾选的日历本）过滤过，
   * 所以 `todos.length > 0` 本身就等价于"用户勾选的范围内确实有待办"，
   * 用户没勾任何待办本时这个值必然是 0 —— 原本想防的场景天然被覆盖。
   *
   * 结论：功能判定必须挂在**数据事实**上，不能挂在可能缺失的元数据上。
   */
  private shouldShowTodoTab(): boolean {
    return this.todos.length > 0;
  }

  /** 当前选中日是否就是今天（用于「今天」按钮的视觉状态） */
  private isOnToday(): boolean {
    return this.selectedDate === this.startOfDay(Date.now());
  }

  /** 回到本周（含今天） */
  private goThisWeek(): void {
    this.selectedDate = this.startOfDay(Date.now());
  }

  @Builder
  weekBody() {
    if (this.wideLayout) {
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
              // 同上：选中态改用高对比的 brand_text（原 text_secondary 在浅色下仅 2.85:1）
              .fontColor(cell.dateMs === this.selectedDate
                ? $r('app.color.brand_text') : $r('app.color.text_hint'))
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
            this.selectDayCell(cell.dateMs);
          })
        }, (cell: MonthCell) => `${this.dataVersion}_${cell.dateMs}_${cell.dateMs === this.selectedDate}_${cell.hasEvents}_${cell.events.length}`)
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
    if (this.displayStyle === 'list' || this.topRangeMode === '3days' || this.topRangeMode === '7days') {
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.selectedDayEvents, (e: DisplayEvent) => {
            this.eventRow(e, this.isEventNow(e, this.topRangeMode === '3days' || this.topRangeMode === '7days' || this.selectedDate === this.startOfDay(this.nowMs)))
          }, (e: DisplayEvent) => `${this.dataVersion}_${e.isSystem ? 's' : 'l'}${e.id}_${e.completed ? '1' : '0'}_${e.startTime}_${e.title}`)
          if (this.selectedDayEvents.length === 0 && !this.loading) {
            Text(this.topRangeMode === '3days' ? '未来三天没有日程' : (this.topRangeMode === '7days' ? '未来七天没有日程' : '当天没有日程'))
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
          onPick: (e: DisplayEvent): void => this.openEvent(e),
          onToggleTodo: (t: DisplayEvent): void => {
            this.toggleTodo(t);
          }
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
          }, (e: DisplayEvent) => `${this.dataVersion}_${e.isSystem ? 's' : 'l'}${e.id}_${e.completed ? '1' : '0'}_${e.startTime}_${e.title}`)
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
                onPick: (e: DisplayEvent): void => this.openEvent(e),
                onToggleTodo: (t: DisplayEvent): void => {
                  this.toggleTodo(t);
                }
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
      if (e.kind === 'todo') {
        // 待办专属勾选按钮（36x36 舒适触控区）
        Row() {
          if (e.completed) {
            Text('✓')
              .fontSize(13)
              .fontColor($r('app.color.button_text'))
              .width(22)
              .height(22)
              .textAlign(TextAlign.Center)
              .borderRadius(11)
              .backgroundColor(e.color)
          } else {
            Text('')
              .width(22)
              .height(22)
              .borderRadius(11)
              .border({ width: 2, color: e.color })
          }
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.toggleTodo(e);
        })
      } else {
        Column()
          .width(4)
          .height(38)
          .borderRadius(2)
          .backgroundColor(isNow ? '#FF3B30' : e.color)
      }
      Column({ space: 3 }) {
        Text(e.title === '' ? (e.kind === 'todo' ? '(无标题待办)' : '(无标题)') : e.title)
          .fontSize(15)
          .fontColor(isNow ? '#FF3B30' : (e.kind === 'todo' && e.completed ? $r('app.color.text_hint') : $r('app.color.text_primary')))
          .decoration({ type: (e.kind === 'todo' && e.completed) ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          if (e.kind === 'todo') {
            Text('待办 · ' + (e.isAllDay ? '全天截止' : (e.startTime > 0 ? `截止 ${this.fmtDue(e.startTime)}` : '无截止时间')))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            if (e.rrule !== '' || e.recurring) {
              Text(`↻ ${this.fmtTodoRepeat(e.rrule)}`)
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(4)
                .backgroundColor($r('app.color.chip_off_bg'))
            }
          } else {
            Text((this.topRangeMode === '3days' || this.topRangeMode === '7days' ? this.fmtEventDatePrefix(e) : '') +
              (e.isAllDay || this.spansDays(e) ? '全天' : `${this.fmtTime(e.startTime)} - ${this.fmtTime(e.endTime)}`))
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
    .opacity((e.kind === 'todo' && e.completed) ? 0.7 : 1)
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
      tl.todos = this.todosDueOn(key);
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

  /**
   * 待办列表的扁平行（摊平后渲染）。
   *
   * ⚠️ 这是**普通方法**，不能挂 @Builder —— 里面是普通语句（new/赋值/循环），
   *    @Builder 内只允许 UI 组件语法。
   */
  private todoFlatRows(): TodoFlatRow[] {
    const rows: TodoFlatRow[] = [];
    const undone: TodoGroup[] = this.todoGroups(false);
    const r0 = new TodoFlatRow();
    r0.role = 'caption';
    r0.text = `未完成（${this.todos.filter((t: DisplayEvent): boolean => !t.completed).length}）`;
    rows.push(r0);
    for (const g of undone) {
      const rh = new TodoFlatRow();
      rh.role = 'header';
      rh.group = g;
      rows.push(rh);
      for (const t of g.items) {
        const rt = new TodoFlatRow();
        rt.role = 'item';
        rt.event = t;
        rows.push(rt);
      }
    }
    if (this.todos.some((t: DisplayEvent): boolean => t.completed)) {
      const r1 = new TodoFlatRow();
      r1.role = 'caption';
      r1.text = `已完成（${this.todos.filter((t: DisplayEvent): boolean => t.completed).length}）`;
      r1.extraTop = 10;
      rows.push(r1);
      for (const g of this.todoGroups(true)) {
        const rh = new TodoFlatRow();
        rh.role = 'header';
        rh.group = g;
        rows.push(rh);
        for (const t of g.items) {
          const rt = new TodoFlatRow();
          rt.role = 'item';
          rt.event = t;
          rows.push(rt);
        }
      }
    }
    return rows;
  }

  @Builder
  todoBody() {
    // ⭐ 用扁平 List 而非 ListItemGroup：
    //    ListItemGroup 会把剩余空间按比例再分给组内 ListItem，
    //    实测「不设高度=176px、设 height(96)=300px」（越限越高），
    //    无法得到"由内容决定"的行高。扁平化后行高自然贴合内容。
    //    分组视觉不受影响 —— 分组头就是一行普通 ListItem。
    List({ space: 4 }) {
      ForEach(this.todoFlatRows(), (row: TodoFlatRow) => {
        if (row.role === 'caption') {
          ListItem() {
            Text(row.text)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: row.extraTop })
          }
          .width('100%')
        } else if (row.role === 'header') {
          ListItem() {
            if (row.group !== undefined) {
              this.todoGroupHeader(row.group)
            }
          }
          .width('100%')
        } else if (row.event !== undefined) {
          ListItem() {
            this.todoRow(row.event as DisplayEvent)
          }
          .width('100%')
          // 高度由内容自然决定（实测两行文字 ≈ 56vp，正常）。
          // ⚠️ 绝不能给内部内容区加 height('100%') —— 那会把行撑到 573vp。
          .swipeAction({ end: this.todoSwipeDelete(row.event as DisplayEvent) })
        }
      }, (row: TodoFlatRow, idx: number) => row.keyOf(idx))

      if (this.todos.length === 0 && !this.loading) {
        ListItem() {
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
            Text('提示：系统日历未开放待办接口，这里的待办不会出现在系统「待办」页签中')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .textAlign(TextAlign.Center)
              .margin({ top: 6 })
          }
          .width('100%')
          .padding(32)
        }
        .width('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 分组头：色点 + 本名（条数） */
  @Builder
  todoGroupHeader(g: TodoGroup) {
    Row({ space: 6 }) {
      Circle({ width: 8, height: 8 }).fill(g.color)
      Text(`${g.name}（${g.items.length}）`)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Blank()
    }
    .width('100%')
    .padding({ top: 6, bottom: 2 })
  }

  /**
   * 左滑露出的「删除」按钮。
   *
   * ⚠️ 不要用 height('100%')：swipeAction 的 end 组件参与行高测量，
   *    百分比会造成放大循环。用固定高度。
   */
  @Builder
  todoSwipeDelete(t: DisplayEvent) {
    Row() {
      Text('删除')
        .fontSize(14)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
    }
    .width(72)
    // 用 100% 与 ListItem 同高：ListItem 高度由内容决定，
    // 按钮跟随即可（官方文档：swipeAction builder 高度默认不匹配内容，
    // 需要显式撑满才不会只占一半）。
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.error'))
    .borderRadius(12)
    .margin({ left: 6 })
    .onClick(() => {
      this.todoEditId = t.id;
      this.todoEditTitle = t.title;
      this.todoEditWritable = t.writable;
      this.askDeleteTodo();
    })
  }



  /**
   * 待办编辑覆盖层。
   *
   * 为什么用覆盖层而不是 bindSheet：
   *   ArkUI 里**同一组件只能挂一个 bindSheet**，Index 已用 `detailShow` 挂了日程详情，
   *   再挂一个会被覆盖（EventEditPage 顶部也记过这个坑）。
   *   覆盖层跟 tipsOverlay / consentGate 是同一套路，已验证可用。
   */
  /**
   * 父任务选择覆盖层（子任务支持）。
   * 候选 = 未完成的顶层任务（不能选自己或自己的后代，防成环）。
   */
  @Builder
  todoParentPickerOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.todoParentPickShow = false;
        })

      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('选择父任务')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('无父任务')
            .fontSize(14)
            .fontColor($r('app.color.brand_text'))
            .onClick(() => {
              this.todoEditParentUid = '';
              this.todoParentPickShow = false;
            })
        }
        .width('100%')

        if (this.todoParentCandidates().length === 0) {
          Text('没有可选的顶层任务')
            .fontSize(13)
            .fontColor($r('app.color.text_hint'))
            .padding(20)
        } else {
          List({ space: 6 }) {
            ForEach(this.todoParentCandidates(), (c: DisplayEvent) => {
              ListItem() {
                Row({ space: 6 }) {
                  Circle({ width: 8, height: 8 }).fill(c.color)
                  Text(c.title === '' ? '(无标题待办)' : c.title)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (this.todoEditParentUid === c.uid) {
                    Text('✓')
                      .fontSize(14)
                      .fontColor($r('app.color.brand_text'))
                  }
                }
                .width('100%')
                .padding(10)
              }
              .width('100%')
              .onClick(() => {
                this.todoEditParentUid = c.uid;
                this.todoParentPickShow = false;
              })
            }, (c: DisplayEvent) => `pc_${c.uid}`)
          }
          .width('100%')
          .constraintSize({ maxHeight: 340 })
        }

        Button('取消')
          .width('100%')
          .height(44)
          .borderRadius(12)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.chip_off_bg'))
          .onClick(() => {
            this.todoParentPickShow = false;
          })
      }
      .width('100%')
      .padding(20)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  todoEditorOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 半透明遮罩：点空白关闭
      Column()
        .width('100%')
        .height('100%')
        // 与 tipsOverlay 同款遮罩色（资源里没有 scrim 这个色，用字面值保持一致）
        .backgroundColor('#66000000')
        .onClick(() => {
          this.todoEditShow = false;
        })

      Column({ space: 12 }) {
        // 标题行（新建/编辑两态）
        Row({ space: 8 }) {
          Text(this.todoCreating ? '新建待办' : '编辑待办')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          // 新建时没有可删的东西，隐藏删除入口
          if (!this.todoCreating && this.todoEditWritable) {
            Text('删除')
              .fontSize(14)
              .fontColor($r('app.color.error'))
              .onClick(() => {
                this.askDeleteTodo();
              })
          }
        }
        .width('100%')

        // ⭐ 中间字段区可滚动（#46）：原来整块 Column 直接铺开，
        //    字段一多就顶出屏幕且滑不动 → 底部按钮点不到。
        //    这里参照新建日程页：固定头 + Scroll 承载字段 + 固定底部按钮。
        Scroll() {
          Column({ space: 12 }) {

        // 日历本区：新建时**铺开全部可写本供选择**（与新建日程一致的交互），
        // 编辑时只读显示归属本（改归属等于搬家，不支持原地改）
        if (this.todoCreating) {
          Column({ space: 6 }) {
            Text('日历本')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.todoBooks, (b: CalSource) => {
                Row({ space: 6 }) {
                  Circle().width(8).height(8).fill(b.color)
                  Text(b.name)
                    .fontSize(12)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(this.todoCreateBookKey === b.calKey
                      ? $r('app.color.button_text') : $r('app.color.text_primary'))
                }
                .width('48%')
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .borderRadius(14)
                .margin({ bottom: 8 })
                .backgroundColor(this.todoCreateBookKey === b.calKey
                  ? b.color : $r('app.color.chip_off_bg'))
                .onClick(() => {
                  this.todoCreateBookKey = b.calKey;
                })
              }, (b: CalSource) => b.calKey)
            }
            .width('100%')
          }
          .width('100%')
        } else if (this.todoEditBook !== '') {
          Row({ space: 6 }) {
            Text('日历本')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Text(this.todoEditBook)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
            Blank()
          }
          .width('100%')
        }

        if (!this.todoEditWritable) {
          Text('该日历本为只读，无法修改')
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .width('100%')
        }

        // 标题输入
        TextInput({ text: this.todoEditTitle, placeholder: '待办标题' })
          .fontSize(15)
          .height(44)
          .borderRadius(10)
          .backgroundColor($r('app.color.page_bg'))
          .onChange((v: string) => {
            this.todoEditTitle = v;
          })

        // 截止时间
        Row({ space: 8 }) {
          Text('截止时间')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(this.todoEditHasDue
            ? this.fmtDueFull(this.todoEditDueMs) : '无')
            .fontSize(14)
            .fontColor(this.todoEditHasDue
              ? $r('app.color.text_primary') : $r('app.color.text_hint'))
          if (this.todoEditHasDue) {
            Text('清除')
              .fontSize(13)
              .fontColor($r('app.color.brand_text'))
              .onClick(() => {
                this.todoEditHasDue = false;
                this.todoEditDueMs = 0;
              })
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .onClick(() => {
          this.openTodoDuePicker();
        })

        // ⭐ 循环设置
        Row({ space: 8 }) {
          Text('重复')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(this.todoEditRecur === '' ? '不重复' : this.recurLabel(`FREQ=${this.todoEditRecur}`))
            .fontSize(14)
            .fontColor(this.todoEditRecur === ''
              ? $r('app.color.text_hint') : $r('app.color.brand_text'))
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })

        // 四个循环选项（点同一个取消）
        Row({ space: 8 }) {
          ForEach([
            { v: 'DAILY', label: '每天' },
            { v: 'WEEKLY', label: '每周' },
            { v: 'MONTHLY', label: '每月' },
            { v: 'YEARLY', label: '每年' }
          ], (opt: Record<string, string>): void => {
            Text(opt.label)
              .fontSize(13)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(this.todoEditRecur === opt.v
                ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
              .fontColor(this.todoEditRecur === opt.v
                ? $r('app.color.button_text') : $r('app.color.text_primary'))
              .onClick(() => {
                // 再点一次 = 取消循环
                this.todoEditRecur = this.todoEditRecur === opt.v ? '' : opt.v;
              })
          }, (opt: Record<string, string>): string => `rr_${opt.v}`)
        }
        .width('100%')

        // ⭐ 优先级（iCal 原生值 1/5/9，再点一次取消）
        Row({ space: 8 }) {
          Text('优先级')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          ForEach([
            { v: 1, label: '高' },
            { v: 5, label: '中' },
            { v: 9, label: '低' }
          ], (opt: Record<string, Object>): void => {
            Text(opt.label as string)
              .fontSize(13)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(this.todoEditPriority === (opt.v as number)
                ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
              .fontColor(this.todoEditPriority === (opt.v as number)
                ? $r('app.color.button_text') : $r('app.color.text_primary'))
              .onClick(() => {
                // 再点一次 = 取消优先级
                const v: number = opt.v as number;
                this.todoEditPriority = this.todoEditPriority === v ? 0 : v;
              })
          }, (opt: Record<string, Object>): string => `pri_${opt.v}`)
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })

        // ⭐ 提醒（#38）：与日程同一套选项；待办的提醒基准是 DUE 到期时刻
        Row({ space: 8 }) {
          Text('提醒')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width(52)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach([
              { v: 0, label: '不提醒' },
              { v: 5, label: '提前5分钟' },
              { v: 15, label: '提前15分钟' },
              { v: 30, label: '提前30分钟' },
              { v: 60, label: '提前1小时' },
              { v: 1440, label: '提前1天' }
            ], (opt: Record<string, Object>): void => {
              Text(opt.label as string)
                .fontSize(12)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .margin({ right: 6, bottom: 6 })
                .borderRadius(13)
                .backgroundColor(this.todoReminderActive(opt.v as number)
                  ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                .fontColor(this.todoReminderActive(opt.v as number)
                  ? $r('app.color.button_text') : $r('app.color.text_primary'))
                .onClick(() => {
                  this.toggleTodoReminder(opt.v as number);
                })
            }, (opt: Record<string, Object>): string => `tr_${opt.v}`)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        // ⭐ 分类标签（逗号分隔，对应 CATEGORIES）
        Row({ space: 8 }) {
          Text('标签')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width(52)
          TextInput({ text: this.todoEditCategories, placeholder: '多个用逗号分隔' })
            .fontSize(14)
            .height(40)
            .layoutWeight(1)
            .borderRadius(10)
            .backgroundColor($r('app.color.page_bg'))
            .onChange((v: string) => {
              this.todoEditCategories = v;
            })
        }
        .width('100%')

        // ⭐ 地点（复用 location 字段）
        Row({ space: 8 }) {
          Text('地点')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width(52)
          TextInput({ text: this.todoEditLocation, placeholder: '可选' })
            .fontSize(14)
            .height(40)
            .layoutWeight(1)
            .borderRadius(10)
            .backgroundColor($r('app.color.page_bg'))
            .onChange((v: string) => {
              this.todoEditLocation = v;
            })
        }
        .width('100%')

        // ⭐ 父任务（子任务支持，对应 RELATED-TO）
        Row({ space: 8 }) {
          Text('父任务')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width(52)
          Blank()
          Text(this.parentName(this.todoEditParentUid))
            .fontSize(14)
            .fontColor(this.todoEditParentUid === ''
              ? $r('app.color.text_hint') : $r('app.color.text_primary'))
          if (this.todoEditParentUid !== '') {
            Text('清除')
              .fontSize(13)
              .fontColor($r('app.color.brand_text'))
              .onClick(() => {
                this.todoEditParentUid = '';
              })
          } else {
            Text('选择')
              .fontSize(13)
              .fontColor($r('app.color.brand_text'))
              .onClick(() => {
                this.openTodoParentPicker();
              })
          }
        }
        .width('100%')
        .padding({ top: 2, bottom: 2 })
        .onClick(() => {
          this.openTodoParentPicker();
        })

        // ⭐ 附件（内联 base64，随待办同步）
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text('附件')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width(52)
            if (this.attachList().length < 3) {
              Text('添加文件')
                .fontSize(13)
                .fontColor($r('app.color.brand_text'))
                .onClick(() => {
                  const ctx = this.getUIContext().getHostContext();
                  if (ctx !== undefined) {
                    this.pickAttachment(ctx);
                  }
                })
            }
            Blank()
          }
          .width('100%')

          ForEach(this.attachList(), (m: AttachMeta, idx: number) => {
            Row({ space: 8 }) {
              Text(m.name)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('✕')
                .fontSize(13)
                .fontColor($r('app.color.text_hint'))
                .onClick(() => {
                  this.removeAttach(idx);
                })
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor($r('app.color.chip_off_bg'))
          }, (m: AttachMeta, idx: number) => `att_${idx}_${m.name}`)
        }
        .width('100%')

        if (this.todoEditRecur !== '' && !this.todoEditHasDue) {
          Text('提示：循环任务需要有截止时间，才能算出下一次')
            .fontSize(11)
            .fontColor($r('app.color.error'))
            .width('100%')
        }

        // 备注
        TextArea({ text: this.todoEditDesc, placeholder: '备注（可选）' })
          .fontSize(14)
          .height(88)
          .borderRadius(10)
          .backgroundColor($r('app.color.page_bg'))
          .onChange((v: string) => {
            this.todoEditDesc = v;
          })

          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)

        // 底部按钮固定在 Scroll 之外，滚动时始终可见（#46）
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.chip_off_bg'))
            .onClick(() => {
              this.todoEditShow = false;
            })
          Button(this.todoBusy ? '保存中…' : (this.todoCreating ? '创建' : '保存'))
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .fontSize(15)
            .enabled(!this.todoBusy && this.todoEditWritable)
            .onClick(() => {
              this.saveTodoEdit();
            })
        }
        .width('100%')
      }
      .width('100%')
      // ⭐ 高度上限 88%（#46）：内容少时自动收缩，内容多时不再顶出屏幕
      .constraintSize({ maxHeight: '88%' })
      .padding(18)
      .borderRadius({ topLeft: 18, topRight: 18 })
      .backgroundColor($r('app.color.card_bg'))
      .shadow({ radius: 16, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: -2 })

      // 截止时间选择器（叠在弹框之上）
      if (this.todoEditPickShow) {
        Column({ space: 12 }) {
          Text('选择截止时间')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
          Row({ space: 4 }) {
            DatePicker({
              start: new Date(2000, 0, 1),
              end: new Date(2050, 11, 31),
              selected: this.todoEditPickDate
            })
              .onDateChange((value: Date) => {
                this.todoEditPickDate = value;
              })
              .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
              .selectedTextStyle({
                color: $r('app.color.text_primary'),
                font: { size: 16, weight: FontWeight.Medium }
              })
              .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
              .layoutWeight(1)
              .height(200)
            TimePicker({ selected: new Date(2000, 0, 1, this.todoEditPickHour, this.todoEditPickMin) })
              .onChange((value: TimePickerResult) => {
                this.todoEditPickHour = value.hour;
                this.todoEditPickMin = value.minute;
              })
              .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
              .selectedTextStyle({
                color: $r('app.color.text_primary'),
                font: { size: 16, weight: FontWeight.Medium }
              })
              .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
              .layoutWeight(1)
              .height(200)
          }
          .width('100%')
          Row({ space: 10 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .borderRadius(12)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.chip_off_bg'))
              .onClick(() => {
                this.todoEditPickShow = false;
              })
            Button('确定')
              .layoutWeight(1)
              .height(42)
              .borderRadius(12)
              .fontSize(15)
              .onClick(() => {
                this.confirmTodoDue();
              })
          }
          .width('100%')
        }
        .width('92%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))
        .shadow({ radius: 20, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 4 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 截止时间完整显示（含时分） */
  private fmtDueFull(ms: number): string {
    const d = new Date(ms);
    const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hh}:${mm}`;
  }

    /** 快速添加待办事项（支持智能自然语言解析并自动同步 CalDAV） */
  private async createQuickTodo(): Promise<void> {
    const trimmed = this.quickTodoText.trim();
    if (trimmed === '') {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }

    // 智能提取时间与标题
    const parsed = SmartDateParser.parse(trimmed);
    const todoTitle = parsed.title !== '' ? parsed.title : trimmed;
    const dueTime = (parsed.confidence && parsed.startTime > 0) ? parsed.startTime : 0;

    // 查找可写的 CalDAV 日历本集合（优先默认选择 inbox / 收件箱）
    let targetKey = '';
    let targetHref = '';
    for (const acc of this.accounts) {
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const writable = i < acc.calendarWritable.length ? acc.calendarWritable[i] : '1';
        if (writable !== '0') {
          const cName = i < acc.calendarNames.length ? acc.calendarNames[i].toLowerCase() : '';
          const cHref = acc.calendarHrefs[i].toLowerCase();
          if (cName.includes('inbox') || cHref.includes('inbox') || cName.includes('收件箱')) {
            targetKey = acc.id + '_' + i;
            targetHref = acc.calendarHrefs[i];
            break;
          }
        }
      }
      if (targetKey !== '') {
        break;
      }
    }
    if (targetKey === '') {
      for (const acc of this.accounts) {
        for (let i = 0; i < acc.calendarHrefs.length; i++) {
          const writable = i < acc.calendarWritable.length ? acc.calendarWritable[i] : '1';
          if (writable !== '0') {
            targetKey = acc.id + '_' + i;
            targetHref = acc.calendarHrefs[i];
            break;
          }
        }
        if (targetKey !== '') {
          break;
        }
      }
    }

    const uid = 'syncal-todo-' + Date.now() + '-' + Math.floor(Math.random() * 1000000);
    const e = new LocalEvent();
    e.uid = uid;
    e.calKey = targetKey;
    e.href = targetHref;
    e.remotePath = encodeURIComponent(uid) + '.ics';
    e.title = todoTitle;
    e.startTime = dueTime;
    e.endTime = dueTime;
    e.kind = 'todo';
    e.completed = false;
    e.dirty = true;

    try {
      const newId = await EventDb.insertLocal(ctx, e);
      e.id = newId;
      this.quickTodoText = '';
      this.todos = await CalendarDataService.loadTodos(ctx, this.sources);
      this.buildEventsByDay();
      this.rebuildPages();
      this.rebuildDayTimeline();
      if (this.mode === 'agenda') {
        this.agendaTimelines = this.buildAgendaTimelines(this.agendaEvents);
      }
      this.dataVersion++;
      CardDataService.pushToAllForms(ctx).catch(() => {});
      const toastMsg = dueTime > 0 ? ('待办已添加（截止 ' + this.fmtDue(dueTime) + '）并同步') : '待办已添加并同步到云端';
      this.getUIContext().getPromptAction().showToast({ message: toastMsg });

      // 后台触发实时推送
      this.syncAll(false).catch((err: Error) => {
        LogUtil.write('后台推送新建待办失败: ' + err.message);
      });
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '添加待办失败: ' + (err as Error).message });
    }
  }

  /** 询问是否删除待办 */
  private askDeleteTodo(t: DisplayEvent): void {
    const label = t.title === '' ? '待办事项' : '「' + t.title + '」';
    this.getUIContext().showAlertDialog({
      title: '删除待办',
      message: '确定要删除' + label + '吗？\n删除后将从本地和 CalDAV 服务器彻底移除。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E64545',
        action: () => {
          this.deleteTodo(t);
        }
      }
    });
  }

  /** 推送待办变更/删除到 CalDAV（直接推送对应账号，避免 syncAll 重入被丢弃） */
  private async pushTodoChange(ctx: common.Context, todoId: number): Promise<void> {
    const ev: LocalEvent | null = await EventDb.getById(ctx, todoId);
    if (ev !== null && ev.href !== '') {
      await CalendarDataService.triggerPush(ctx, ev.href);
    } else if (!this.syncing) {
      await this.syncAll(false);
    }
  }

  /** 执行删除待办并推送到服务器 */
  private async deleteTodo(t: DisplayEvent): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    await EventDb.markDeleted(ctx, t.id);
    this.todos = this.todos.filter((item: DisplayEvent): boolean => item.id !== t.id);
    this.selectedDayEvents = this.selectedDayEvents.filter((item: DisplayEvent): boolean => !(item.id === t.id && item.kind === 'todo'));
    this.buildEventsByDay();
    this.rebuildPages();
    this.rebuildDayTimeline();
    if (this.mode === 'agenda') {
      this.agendaTimelines = this.buildAgendaTimelines(this.agendaEvents);
    }
    this.dataVersion++;
    CardDataService.pushToAllForms(ctx).catch(() => {});
    this.getUIContext().getPromptAction().showToast({ message: '待办已删除' });
    this.pushTodoChange(ctx, t.id).catch((err: Error) => {
      LogUtil.write('同步删除待办失败: ' + err.message);
    });
  }

  /** 点击待办：打勾完成/取消完成，0ms 瞬间响应渲染，本地落库并后台双向推送到 CalDAV */
  private async toggleTodo(t: DisplayEvent): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    // 判断是否为重复待办从未完成勾选为完成
    if (!t.completed && (t.rrule !== '' || t.recurring)) {
      const nextOcc = RruleUtil.nextOccurrence(t.rrule, t.startTime > 0 ? t.startTime : Date.now());
      if (nextOcc > 0) {
        // 重复待办自动推进到下一次发生时刻
        this.todos = this.todos.map((item: DisplayEvent): DisplayEvent => {
          if (item.id === t.id) {
            const copy = new DisplayEvent();
            copy.id = item.id;
            copy.isSystem = item.isSystem;
            copy.title = item.title;
            copy.description = item.description;
            copy.location = item.location;
            copy.startTime = nextOcc;
            copy.endTime = nextOcc;
            copy.isAllDay = item.isAllDay;
            copy.calKey = item.calKey;
            copy.calName = item.calName;
            copy.color = item.color;
            copy.completed = false;
            copy.recurring = item.recurring;
            copy.writable = item.writable;
            copy.kind = item.kind;
            copy.rrule = item.rrule;
            return copy;
          }
          return item;
        });
        // 瞬间同步更新选今日程列表
        this.selectedDayEvents = this.selectedDayEvents.map((item: DisplayEvent): DisplayEvent => {
          if (item.id === t.id && item.kind === 'todo') {
            const copy = new DisplayEvent();
            copy.id = item.id;
            copy.isSystem = item.isSystem;
            copy.title = item.title;
            copy.description = item.description;
            copy.location = item.location;
            copy.startTime = nextOcc;
            copy.endTime = nextOcc;
            copy.isAllDay = item.isAllDay;
            copy.calKey = item.calKey;
            copy.calName = item.calName;
            copy.color = item.color;
            copy.completed = false;
            copy.recurring = item.recurring;
            copy.writable = item.writable;
            copy.kind = item.kind;
            copy.rrule = item.rrule;
            return copy;
          }
          return item;
        });
        this.buildEventsByDay();
        this.rebuildPages();
        this.rebuildDayTimeline();
        if (this.mode === 'agenda') {
          this.agendaTimelines = this.buildAgendaTimelines(this.agendaEvents);
        }
        this.dataVersion++;

        const nextDateStr: string = this.fmtDateCn(nextOcc);
        this.getUIContext().getPromptAction().showToast({
          message: `已完成本次，下期截止：${nextDateStr}`
        });

        if (ctx !== undefined) {
          CardDataService.pushToAllForms(ctx).catch(() => {});
          await EventDb.advanceTodo(ctx, t.id, nextOcc);
          this.pushTodoChange(ctx, t.id).catch((err: Error) => {
            LogUtil.write('待办后台同步失败: ' + err.message);
          });
        }
        return;
      }
    }

    // 常规待办完成 / 取消完成 或重复待办最后一期完成
    const nextCompleted: boolean = !t.completed;
    this.todos = this.todos.map((item: DisplayEvent): DisplayEvent => {
      if (item.id === t.id) {
        const copy = new DisplayEvent();
        copy.id = item.id;
        copy.isSystem = item.isSystem;
        copy.title = item.title;
        copy.description = item.description;
        copy.location = item.location;
        copy.startTime = item.startTime;
        copy.endTime = item.endTime;
        copy.isAllDay = item.isAllDay;
        copy.calKey = item.calKey;
        copy.calName = item.calName;
        copy.color = item.color;
        copy.completed = nextCompleted;
        copy.recurring = item.recurring;
        copy.writable = item.writable;
        copy.kind = item.kind;
        copy.rrule = item.rrule;
        return copy;
      }
      return item;
    });
    // 瞬间同步更新选今日程列表，保证在日程视图中点击立即打勾或划线生效
    this.selectedDayEvents = this.selectedDayEvents.map((item: DisplayEvent): DisplayEvent => {
      if (item.id === t.id && item.kind === 'todo') {
        const copy = new DisplayEvent();
        copy.id = item.id;
        copy.isSystem = item.isSystem;
        copy.title = item.title;
        copy.description = item.description;
        copy.location = item.location;
        copy.startTime = item.startTime;
        copy.endTime = item.endTime;
        copy.isAllDay = item.isAllDay;
        copy.calKey = item.calKey;
        copy.calName = item.calName;
        copy.color = item.color;
        copy.completed = nextCompleted;
        copy.recurring = item.recurring;
        copy.writable = item.writable;
        copy.kind = item.kind;
        copy.rrule = item.rrule;
        return copy;
      }
      return item;
    });
    this.buildEventsByDay();
    this.rebuildPages();
    this.rebuildDayTimeline();
    if (this.mode === 'agenda') {
      this.agendaTimelines = this.buildAgendaTimelines(this.agendaEvents);
    }
    this.dataVersion++;

    this.getUIContext().getPromptAction().showToast({
      message: nextCompleted ? '已标记为完成' : '已取消完成'
    });

    if (ctx !== undefined) {
      CardDataService.pushToAllForms(ctx).catch(() => {});
      await EventDb.toggleTodoCompleted(ctx, t.id, nextCompleted);
      this.pushTodoChange(ctx, t.id).catch((err: Error) => {
        LogUtil.write('待办后台同步失败: ' + err.message);
      });
    }
  }

  private fmtTodoRepeat(rrule: string): string {
    if (rrule === '') {
      return '重复';
    }
    const u = rrule.toUpperCase();
    if (u.includes('BYDAY=MO,TU,WE,TH,FR')) {
      return '工作日';
    }
    if (u.includes('FREQ=DAILY')) {
      return '每天';
    }
    if (u.includes('FREQ=WEEKLY')) {
      return '每周';
    }
    if (u.includes('FREQ=MONTHLY')) {
      return '每月';
    }
    if (u.includes('FREQ=YEARLY')) {
      return '每年';
    }
    return '重复';
  }

  

  /** 一键复制标准 iCal (.ics) 日程到剪贴板，支持跨软件分享与导入 */
  private async shareEventIcs(): Promise<void> {
    if (this.detailEvent === null) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      try {
        const local = await EventDb.getById(ctx, this.detailEvent.id);
        if (local === null) {
          this.getUIContext().getPromptAction().showToast({ message: '日程数据未找到' });
          return;
        }
        const ics = IcsUtil.buildSeries(local, []);
        const pData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, ics);
        const pb = pasteboard.getSystemPasteboard();
        await pb.setData(pData);
        this.getUIContext().getPromptAction().showToast({
          message: '已复制标准 iCal (.ics) 日程，可直接分享'
        });
      } catch (err) {
        this.getUIContext().getPromptAction().showToast({
          message: '复制失败: ' + (err as Error).message 
        });
      }
    }
  }

  /** 待办事项左滑出现的转日程与删除按钮 */
  @Builder
  todoSwipeAction(t: DisplayEvent) {
    Row({ space: 6 }) {
      Button({ type: ButtonType.Normal }) {
        Text('转日程')
          .fontSize(13)
          .fontColor($r('app.color.button_text'))
          .fontWeight(FontWeight.Medium)
      }
      .width(68)
      .height('100%')
      .backgroundColor($r('app.color.brand'))
      .borderRadius(12)
      .onClick(() => {
        this.quickConvertTodoToEvent(t);
      })

      Button({ type: ButtonType.Normal }) {
        Text('删除')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
      }
      .width(60)
      .height('100%')
      .backgroundColor('#E64545')
      .borderRadius(12)
      .onClick(() => {
        this.askDeleteTodo(t);
      })
    }
    .padding({ left: 6 })
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 将待办快捷转换为日程 */
  private async quickConvertTodoToEvent(t: DisplayEvent): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const ok = await CalendarDataService.convertTodoToEvent(ctx, t.id);
    if (ok) {
      try {
        await CardDataService.pushToAllForms(ctx);
      } catch (err) {}
      this.getUIContext().getPromptAction().showToast({ message: `「${t.title || '待办'}」已成功转换为日程` });
      await this.reloadAll();
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '转换失败' });
    }
  }

  @Builder
  todoRow(t: DisplayEvent) {
    // ⭐ TODO_ROW_SPLIT 点击区域拆分：
    //    · 左侧圆圈 → 勾选/取消完成
    //    · 其余部分 → 打开编辑弹框
    //    旧版把 onClick 挂在整行上，点标题、点截止时间、点空白都会改完成状态，
    //    用户反馈"点任何地方都是完成"，是明确的交互缺陷。
    // 子任务缩进：顶层不缩，子任务缩 24vp
    Row({ space: 10 }) {
      // 勾选框（颜色跟随日历本）—— **只有这块触发完成切换**
      Row() {
        if (t.completed) {
          // ⭐ 用矢量 Path 画勾（#50）：字符 '✓' 依赖字体，
          //    不同设备下粗细/居中不一致，视觉上"不精致"。
          //    Path 可精确控制线宽、端点圆角与几何比例。
          Stack() {
            Path()
              .width(22)
              .height(22)
              .commands('M6 12.5 L9.5 16 L16.5 8')
              .stroke($r('app.color.button_text'))
              .strokeWidth(2.2)
              .strokeLineCap(LineCapStyle.Round)
              .strokeLineJoin(LineJoinStyle.Round)
              .fill(Color.Transparent)
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(this.colorOfCal(t.calKey))
        } else {
          Text('')
            .width(22)
            .height(22)
            .borderRadius(11)
            .border({ width: 2, color: this.colorOfCal(t.calKey) })
        }
      }
      .padding({ right: 2 })
      .onClick(() => {
        this.toggleTodo(t);
      })

      Column({ space: 3 }) {
        Text((t.parentUid !== '' ? '∟ ' : '') + (t.title === '' ? '(无标题待办)' : t.title))
          .fontSize(15)
          .fontColor(t.completed ? $r('app.color.text_hint') : $r('app.color.text_primary'))
          .decoration({ type: t.completed ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.todoSubtitle(t) + this.subtaskProgress(t))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      // ⚠️ 不要用 .height('100%')：ListItem 里百分比会参照被拉伸的可用高度，
      //    实测让单条变成 1790px（几乎占满整屏）。
      //    热区扩大改由外层 Row 的 padding 承担（见下方 .padding(10)），
      //    内容区自身不再加 padding，避免内外叠加把行撑高。
      // ⭐ 内容区点击 → 打开编辑（不改变完成状态）
      .onClick(() => {
        this.openTodoEditor(t);
      })
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding(t.parentUid !== ''
      ? { left: 34, right: 10, top: 10, bottom: 10 }
      : { left: 10, right: 10, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 1, color: $r('app.color.shadow_color') })
    .opacity(t.completed ? 0.7 : 1)
  }

  /**
   * 把待办按日历本聚合成组。
   *
   * @param completed true=取已完成；false=取未完成
   * @returns 按"未完成优先、组内按截止时间升序"排好的分组
   *
   * 为什么单独抽出来：视图里直接写 filter + group 会让 build() 里塞逻辑，
   * 而且 ForEach 的 key 需要稳定（用 calKey），抽出来更好维护。
   */
  private todoGroups(completed: boolean): TodoGroup[] {
    const list: DisplayEvent[] = this.todos.filter(
      (t: DisplayEvent): boolean => t.completed === completed);
    const map: Map<string, TodoGroup> = new Map<string, TodoGroup>();
    const order: string[] = [];
    for (const t of list) {
      const key: string = t.calKey === '' ? '__unknown' : t.calKey;
      let g: TodoGroup | undefined = map.get(key);
      if (g === undefined) {
        const ng = new TodoGroup();
        ng.calKey = key;
        ng.name = t.calName !== '' ? t.calName : '其他';
        ng.color = t.color;
        map.set(key, ng);
        order.push(key);
        g = ng;
      }
      g.items.push(t);
    }
    const out: TodoGroup[] = [];
    for (const k of order) {
      const g = map.get(k);
      if (g !== undefined) {
        // 组内按截止时间升序（无截止时间的排最后）
        g.items.sort((a: DisplayEvent, b: DisplayEvent): number => {
          const av: number = a.startTime > 0 ? a.startTime : Number.MAX_SAFE_INTEGER;
          const bv: number = b.startTime > 0 ? b.startTime : Number.MAX_SAFE_INTEGER;
          return av - bv;
        });
        out.push(g);
      }
    }
    // 组之间按"组内最早截止时间"排序，最紧急的本排前面
    out.sort((a: TodoGroup, b: TodoGroup): number => {
      const av: number = a.items.length > 0 && a.items[0].startTime > 0
        ? a.items[0].startTime : Number.MAX_SAFE_INTEGER;
      const bv: number = b.items.length > 0 && b.items[0].startTime > 0
        ? b.items[0].startTime : Number.MAX_SAFE_INTEGER;
      return av - bv;
    });
    return out;
  }

  /**
   * 打开「新建待办」弹层。
   *
   * 与 openTodoEditor 的区别：不预填任何既有数据，todoEditId=0，
   * 并把**所有可写日历本铺开**供用户选择。
   *
   * 默认选中策略：优先 Inbox（多数 CalDAV 服务器把待办收件箱叫 inbox/Inbox/收件箱），
   * 找不到就选第一个可写的本 —— 让用户少点一步，但仍可改。
   */
  private async openTodoCreator(): Promise<void> {
    // ⭐ 改为独立页面（与新建日程一致）：预置参数后跳转
    //    待办默认**没有截止时间**（与日程不同：待办不是"发生在某天的事"，
    //    而是"要完成的事"，多数待办一开始并不确定哪天截止）。
    //    所以不传 pendingTodoDate（0 = 不预填）。
    AppStorage.setOrCreate<number>('pendingTodoId', 0);
    AppStorage.setOrCreate<number>('pendingTodoDate', 0);
    router.pushUrl({ url: 'pages/TodoEditPage' });
  }

  /** 打开待办编辑页（点内容区触发；不会改变完成状态） */
  private openTodoEditor(t: DisplayEvent): void {
    // ⭐ 改为独立页面（与编辑日程一致）：把 id 预置后跳转
    AppStorage.setOrCreate<number>('pendingTodoId', t.id);
    AppStorage.setOrCreate<number>('pendingTodoDate', 0);
    LogUtil.write(`打开待办编辑：id=${t.id} uid=${t.uid} 标题长度=${t.title.length} 本=${t.calKey}`);
    router.pushUrl({ url: 'pages/TodoEditPage' });
    return;
  }

  /** 打开截止时间选择器（把当前值灌进滚轮初值） */
  private openTodoDuePicker(): void {
    const d: Date = this.todoEditHasDue && this.todoEditDueMs > 0
      ? new Date(this.todoEditDueMs) : new Date();
    this.todoEditPickDate = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    this.todoEditPickHour = d.getHours();
    this.todoEditPickMin = d.getMinutes();
    this.todoEditPickShow = true;
  }

  /** 确认截止时间 */
  private confirmTodoDue(): void {
    const d: Date = this.todoEditPickDate;
    this.todoEditDueMs = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
      this.todoEditPickHour, this.todoEditPickMin).getTime();
    this.todoEditHasDue = true;
    this.todoEditPickShow = false;
  }

  /** 保存待办编辑（标题 / 备注 / 截止时间） */
  private async saveTodoEdit(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined || this.todoBusy) {
      return;
    }
    // ⭐ 新建分支：走 createTodo（先 PUT 服务器，成功才落库）
    if (this.todoCreating) {
      await this.saveNewTodo(ctx);
      return;
    }
    if (this.todoEditId <= 0) {
      return;
    }
    if (!this.todoEditWritable) {
      this.getUIContext().getPromptAction().showToast({ message: '该日历本为只读，无法修改' });
      return;
    }
    this.todoBusy = true;
    try {
      // 父任务/附件：编辑页显示什么就保存什么（touch 恒 true，
      // 值来自弹层状态，用户点保存的意图就是让它们生效）
      const ok: boolean = await TodoService.updateTodo(ctx, this.todoEditId,
        this.todoEditTitle, this.todoEditDesc,
        this.todoEditHasDue ? this.todoEditDueMs : 0,
        this.todoEditPriority, this.todoEditCategories, this.todoEditLocation,
        this.todoEditReminders, this.todoEditParentUid, this.todoEditAttachments,
        true, true);
      if (ok) {
        // ⭐ 循环规则单独写：它与"改内容"是两回事，
        //    而且要先有截止时间才有意义（没有 DUE 的循环任务无法算下一次）
        const wantRule: string = this.todoEditRecur !== '' ? `FREQ=${this.todoEditRecur}` : '';
        const dueForRecur: number = this.todoEditHasDue ? this.todoEditDueMs : 0;
        if (dueForRecur > 0) {
          await TodoService.setRecurrence(ctx, this.todoEditId, wantRule, dueForRecur);
        }
        this.todoEditShow = false;
        this.getUIContext().getPromptAction().showToast({ message: '已保存' });
        this.todos = await CalendarDataService.loadTodos(ctx, this.sources);
        this.rebuildPages();
        // ⭐ 卡片是独立实例，必须显式推送；提醒随标题/截止/提醒项变化需重排
        await CardDataService.pushToAllForms(ctx);
        await ReminderService.refreshReminders(ctx);
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: '保存失败：需联网，且该日历本需可写'
        });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请稍后重试' });
    } finally {
      this.todoBusy = false;
    }
  }

  /** 提醒是否选中（0 表示"不提醒"，即列表为空） */
  private todoReminderActive(v: number): boolean {
    if (v === 0) {
      return this.todoEditReminders.length === 0;
    }
    return this.todoEditReminders.indexOf(v) >= 0;
  }

  /** 切换提醒：0=清空（不提醒），其余=多选切换 */
  private toggleTodoReminder(v: number): void {
    if (v === 0) {
      this.todoEditReminders = [];
      return;
    }
    const idx: number = this.todoEditReminders.indexOf(v);
    if (idx >= 0) {
      this.todoEditReminders = this.todoEditReminders.filter((x: number): boolean => x !== v);
    } else {
      this.todoEditReminders = this.todoEditReminders.concat([v]);
    }
  }

  /**
   * 选择附件：DocumentViewPicker → 读二进制 → base64 → 存入 todoEditAttachments。
   *
   * 限制：最多 3 个、单文件 ≤ 5MB。内联 base64 会让 .ics 膨胀，
   * 限制是为了防爆服务器与同步性能。
   */
  private async pickAttachment(ctx: common.Context): Promise<void> {
    if (this.todoAttachBusy) {
      return;
    }
    this.todoAttachBusy = true;
    try {
      const pickerv = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await pickerv.select({
        maxSelectNumber: 3
      });
      if (uris.length === 0) {
        return;
      }
      // 已有附件数 + 新选数不得超过 3
      const existing: AttachMeta[] = IcsUtil.jsonToAttachMeta(this.todoEditAttachments);
      if (existing.length + uris.length > 3) {
        this.getUIContext().getPromptAction().showToast({ message: '最多 3 个附件' });
        uris.splice(0); // 丢弃，不超过限制时已读的部分也不该要
        return;
      }
      const merged: AttachMeta[] = existing.slice();
      for (const uri of uris) {
        const meta: AttachMeta | null = this.readAttach(uri);
        if (meta === null) {
          continue;
        }
        if (meta.base64.length > 5 * 1024 * 1024) {
          this.getUIContext().getPromptAction().showToast({ message: '单文件不超过 5MB' });
          continue;
        }
        merged.push(meta);
      }
      this.todoEditAttachments = IcsUtil.attachMetaToJson(merged);
      if (merged.length > existing.length) {
        this.getUIContext().getPromptAction().showToast({ message: `已添加 ${merged.length - existing.length} 个附件` });
      }
    } catch (err) {
      // 用户取消选择也会走这里（返回空/抛错），不提示错误
      LogUtil.write(`选择附件取消或失败: ${(err as BusinessError).message ?? ''}`);
    } finally {
      this.todoAttachBusy = false;
    }
  }

  /** 读一个文件 URI → AttachMeta（文件名/mime/size/base64）。失败返回 null。 */
  private readAttach(uri: string): AttachMeta | null {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0 || size > 5 * 1024 * 1024) {
        fs.closeSync(file.fd);
        return null;
      }
      // 最多 5MB，一次性读完
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const readLen: number = fs.readSync(file.fd, buf);
      fs.closeSync(file.fd);
      if (readLen <= 0) {
        return null;
      }
      // ArrayBuffer → base64
      const u8 = new Uint8Array(buf);
      let bin: string = '';
      for (let i = 0; i < u8.length; i++) {
        bin += String.fromCharCode(u8[i]);
      }
      const base64: string = new util.Base64Helper().encodeToStringSync(
        new Uint8Array(buf));
      // 文件名：从 URI 末尾解析（去掉 querystring），拿不到就占位
      let name: string = uri.substring(uri.lastIndexOf('/') + 1);
      const q: number = name.indexOf('?');
      if (q >= 0) {
        name = name.substring(0, q);
      }
      if (name === '') {
        name = '附件';
      }
      // mime：按扩展名粗略推断，其余 application/octet-stream
      const m = new AttachMeta();
      m.name = name;
      m.mime = this.mimeOfName(name);
      m.base64 = base64;
      return m;
    } catch (err) {
      LogUtil.write(`读附件失败: ${(err as BusinessError).message ?? ''}`);
      return null;
    }
  }

  /** 按扩展名推断 mime，能覆盖常见文档/图片即可。 */
  private mimeOfName(name: string): string {
    const lower: string = name.toLowerCase();
    if (lower.endsWith('.pdf')) { return 'application/pdf'; }
    if (lower.endsWith('.png')) { return 'image/png'; }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) { return 'image/jpeg'; }
    if (lower.endsWith('.gif')) { return 'image/gif'; }
    if (lower.endsWith('.txt')) { return 'text/plain'; }
    if (lower.endsWith('.csv')) { return 'text/csv'; }
    if (lower.endsWith('.zip')) { return 'application/zip'; }
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return 'application/msword';
    }
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx')) {
      return 'application/vnd.ms-excel';
    }
    return 'application/octet-stream';
  }

  /** 父任务的子任务进度文案「 N/M」，无子任务返回空串。 */
  private subtaskProgress(t: DisplayEvent): string {
    const children: DisplayEvent[] = this.todos.filter(
      (x: DisplayEvent): boolean => x.parentUid === t.uid && x.parentUid !== '');
    if (children.length === 0) {
      return '';
    }
    const done: number = children.filter((x: DisplayEvent): boolean => x.completed).length;
    return ` · ${done}/${children.length}`;
  }

  /** 是否有子任务（按父 uid 找）。 */
  private hasChildren(uid: string): boolean {
    return this.todos.some((x: DisplayEvent): boolean => x.parentUid === uid);
  }

  /** 父任务显示名：按 uid 在 todos 里找；找不到显示「无」。 */
  private parentName(uid: string): string {
    if (uid === '') {
      return '无';
    }
    for (const t of this.todos) {
      if (t.uid === uid) {
        return t.title === '' ? '(无标题)' : t.title;
      }
    }
    return '（已不存在）';
  }

  /** 解析附件 JSON → AttachMeta[]。 */
  private attachList(): AttachMeta[] {
    return IcsUtil.jsonToAttachMeta(this.todoEditAttachments);
  }

  /** 删除第 idx 个附件，回写 JSON。 */
  private removeAttach(idx: number): void {
    const list: AttachMeta[] = this.attachList();
    if (idx < 0 || idx >= list.length) {
      return;
    }
    list.splice(idx, 1);
    this.todoEditAttachments = IcsUtil.attachMetaToJson(list);
  }

  /** 打开父任务选择弹层。候选 = 未完成的顶层任务，且不能是自己或自己的后代。 */
  private openTodoParentPicker(): void {
    this.todoParentPickShow = true;
  }

  /** 当前编辑待办的 uid（自己） */
  private todoEditUid(): string {
    for (const t of this.todos) {
      if (t.id === this.todoEditId) {
        return t.uid;
      }
    }
    return '';
  }

  /** 父任务候选（未完成、顶层、非自身/后代）。 */
  private todoParentCandidates(): DisplayEvent[] {
    const selfUid: string = this.todoEditUid();
    // 收集"自己"及其所有后代的 uid，选父时排除（防成环）
    const selfAndDesc: Set<string> = new Set<string>();
    if (selfUid !== '') {
      selfAndDesc.add(selfUid);
      const queue: string[] = [selfUid];
      let guard = 0;
      while (queue.length > 0 && guard < 200) {
        const cur: string = queue.shift() as string;
        for (const t of this.todos) {
          if (t.parentUid === cur && !selfAndDesc.has(t.uid)) {
            selfAndDesc.add(t.uid);
            queue.push(t.uid);
          }
        }
        guard++;
      }
    }
    const out: DisplayEvent[] = [];
    for (const t of this.todos) {
      if (t.completed) { continue; }
      if (t.parentUid !== '') { continue; } // 只选顶层任务做父
      if (selfAndDesc.has(t.uid)) { continue; } // 不能选自己或后代
      out.push(t);
    }
    return out;
  }

  /** 保存新建的待办 */
  private async saveNewTodo(ctx: common.Context): Promise<void> {
    const title: string = this.todoEditTitle.trim();
    if (title === '') {
      this.getUIContext().getPromptAction().showToast({ message: '请填写待办标题' });
      return;
    }
    const href: string = this.todoBookHrefs.get(this.todoCreateBookKey) ?? '';
    if (href === '') {
      this.getUIContext().getPromptAction().showToast({ message: '请选择日历本' });
      return;
    }
    this.todoBusy = true;
    try {
      const dueMs: number = this.todoEditHasDue ? this.todoEditDueMs : 0;
      // 截止时间只到日（00:00 视为"当天"）→ 用 DATE 值，避免服务器上显示 00:00
      const dateOnly: boolean = dueMs > 0 && this.todoEditDueMs % 86400000 === 0;
      const newId: number = await TodoService.createTodo(ctx, href, title,
        this.todoEditDesc, dueMs, dateOnly,
        this.todoEditPriority, this.todoEditCategories, this.todoEditLocation,
        this.todoEditReminders, this.todoEditParentUid, this.todoEditAttachments);
      if (newId > 0) {
        this.todoEditShow = false;
        this.todoCreating = false;
        this.getUIContext().getPromptAction().showToast({ message: '待办已创建' });
        this.todos = await CalendarDataService.loadTodos(ctx, this.sources);
        this.rebuildPages();
        await CardDataService.pushToAllForms(ctx);
        await ReminderService.refreshReminders(ctx);
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: '创建失败：需联网，且该日历本需可写'
        });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '创建失败，请稍后重试' });
    } finally {
      this.todoBusy = false;
    }
  }

  /** 删除待办（带二次确认） */
  private askDeleteTodo(): void {
    this.getUIContext().showAlertDialog({
      title: '删除待办',
      message: '将从服务器删除这条待办，删除后无法撤销。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.doDeleteTodo();
        }
      }
    });
  }

  private async doDeleteTodo(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined || this.todoBusy || this.todoEditId <= 0) {
      return;
    }
    this.todoBusy = true;
    try {
      const ok: boolean = await TodoService.deleteTodo(ctx, this.todoEditId);
      if (ok) {
        this.todoEditShow = false;
        this.getUIContext().getPromptAction().showToast({ message: '已删除' });
        this.todos = await CalendarDataService.loadTodos(ctx, this.sources);
        this.rebuildPages();
        await CardDataService.pushToAllForms(ctx);
        // 删除后必须重排，否则已删待办的提醒还会响
        await ReminderService.refreshReminders(ctx);
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '删除失败，请稍后重试' });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '删除失败，请稍后重试' });
    } finally {
      this.todoBusy = false;
    }
  }

  /** 待办副标题：截止时间 · 所属日历本（分组后本名仍在，方便跨组辨识） */
  private todoSubtitle(t: DisplayEvent): string {
    const due: string = t.startTime > 0 ? `截止 ${this.fmtDue(t.startTime)}` : '无截止时间';
    const book: string = t.calName !== '' ? ` · ${t.calName}` : '';
    // ⭐ TODO_RECUR_UI 循环标记：让用户一眼看出"这条会重复"
    //    没有这个标记，循环任务看起来和普通待办完全一样，
    //    用户勾完成后发现"又冒出新的"会很困惑。
    const rec: string = t.recurRule !== '' ? ` ↻ ${this.recurLabel(t.recurRule)}` : '';
    return due + rec + book;
  }

  /** RRULE → 中文标签（只处理 FREQ 四种，够用且不会误导） */
  private recurLabel(rrule: string): string {
    const f: string = IcsUtil.freqOfRrule(rrule);
    if (f === 'DAILY') {
      return '每天';
    }
    if (f === 'WEEKLY') {
      return '每周';
    }
    if (f === 'MONTHLY') {
      return '每月';
    }
    if (f === 'YEARLY') {
      return '每年';
    }
    return '循环';
  }

  /** 待办完成状态切换：写回服务器成功后刷新列表；失败保持原状并提示。
   *  ⚠️ 不做"先改界面再回滚"：待办写回要走网络，若先改后失败，
   *  用户会看到状态闪一下又跳回去，容易误以为操作没生效。这里直接等结果。 */
  private async toggleTodo(t: DisplayEvent): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined || this.todoBusy) {
      return;
    }
    this.todoBusy = true;
    try {
      // ⭐ 循环待办勾"完成" = 这一轮做完了，推进到下一个周期（不结束）
      //    非循环 / 取消完成 → 走原来的 setCompleted
      const isRecurring: boolean = t.recurRule !== '';
      let ok: boolean = false;
      let nextDue: number = 0;
      if (isRecurring && !t.completed) {
        nextDue = await TodoService.completeRecurringRound(ctx, t.id);
        ok = nextDue > 0;
      } else {
        ok = await TodoService.setCompleted(ctx, t.id, !t.completed);
        // ⭐ 父任务级联完成子任务（勾父任务→所有子任务一并完成）
        if (ok && !t.completed && this.hasChildren(t.uid)) {
          await TodoService.completeChildren(ctx, t.uid);
        }
      }
      if (ok) {
        if (isRecurring && !t.completed) {
          this.getUIContext().getPromptAction().showToast({
            message: nextDue > 0 ? `这一轮完成，下次 ${this.fmtDue(nextDue)}` : '这一轮已完成'
          });
        } else {
          this.getUIContext().getPromptAction().showToast({
            message: t.completed ? '已标记为未完成' : '已完成'
          });
        }
        // 重新读库刷新列表（服务层已更新 completed）
        this.todos = await CalendarDataService.loadTodos(ctx, this.sources);
        // ⭐ 时间轴上的待办区是快照，勾选后必须重建，否则不消失/不划线（#45）
        this.rebuildDayTimeline();
        if (this.mode === 'agenda') {
          this.agendaTimelines = this.buildAgendaTimelines(this.agendaEvents);
        }
        // ⭐ 桌面卡片是独立实例，必须显式推送，否则停在旧数据
        await CardDataService.pushToAllForms(ctx);
        // 完成/取消完成会改变"该不该提醒"，需要重排
        await ReminderService.refreshReminders(ctx);
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: '更新失败：需联网，且该日历本需可写'
        });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '更新失败，请稍后重试' });
    } finally {
      this.todoBusy = false;
    }
  }

  /** 是否跨天（结束日期晚于开始日期） */
  private spansDays(e: DisplayEvent): boolean {
    if (normalizeSingleDayIfFestival(e.title, e.startTime, e.endTime, e.isAllDay) !== null) {
      return false;
    }
    const effectiveEnd = (e.endTime > e.startTime) ? (e.endTime - 1) : e.startTime;
    return this.startOfDay(effectiveEnd) > this.startOfDay(e.startTime);
  }

  @Builder
  dayCell(cell: MonthCell) {
    Column({ space: 1 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(String(cell.day))
          .fontSize(this.wideLayout ? 12 : 13)
          .fontWeight(cell.isToday || cell.dateMs === this.selectedDate ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(!cell.inMonth
            ? $r('app.color.text_hint')
            : (cell.dateMs === this.selectedDate ? $r('app.color.button_text') : $r('app.color.text_primary')))
          .width(this.wideLayout ? 22 : 24)
          .height(this.wideLayout ? 22 : 24)
          .textAlign(TextAlign.Center)
          .borderRadius(this.wideLayout ? 11 : 12)
          .backgroundColor(cell.dateMs === this.selectedDate
            ? Color.Transparent
            : (cell.isToday ? $r('app.color.today_bg') : Color.Transparent))

        if (cell.holidayBadge !== '') {
          Text(cell.holidayBadge)
            .fontSize(7)
            .fontColor('#FFFFFF')
            .backgroundColor(cell.holidayBadge === '休' ? '#FF3B30' : '#8E8E93')
            .borderRadius(2)
            .padding({ left: 1.5, right: 1.5 })
            .height(10)
            .lineHeight(10)
            .margin({ top: -2, right: -4 })
        }
      }
      if (!this.wideLayout) {
        Text(cell.lunar)
          .fontSize(8)
          // 选中 → 与日期同色（白），保证在同块蓝底上都看得清
          .fontColor(cell.dateMs === this.selectedDate
            ? $r('app.color.button_text') : $r('app.color.text_hint'))
          .maxLines(1)
      }
      // 无事件时圆点透明但仍占位：保证有/无事件的行高完全一致，整月不会跳
      // 选中时圆点也转白（与日期同色），否则浅红压在蓝底上会发灰
      Circle({ width: this.wideLayout ? 4 : 3.5, height: this.wideLayout ? 4 : 3.5 })
        .fill(cell.dateMs === this.selectedDate
          ? $r('app.color.button_text') : $r('app.color.soft_red'))
        .opacity((cell.hasEvent || cell.hasEvents) ? 1 : 0)
    }
    .layoutWeight(1)
    .padding({ top: this.wideLayout ? 2 : 3, bottom: this.wideLayout ? 2 : 1 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.selectDayCell(cell.dateMs);
      if (!cell.inMonth) {
        const d = new Date(cell.dateMs);
        this.displayYear = d.getFullYear();
        this.displayMonth = d.getMonth();
        this.rebuildPages();
        this.swiperGuard = true;
        this.swiperController.changeIndex(1, false);
        this.expandedSwiperController.changeIndex(1, false);
        this.reloadEvents();
      }
    })
  }

  /** 全月展开视图单个日期格子（参考图3：顶部日期与农历，下方展示最多2条日程事项及+N） */
  @Builder
  dayCellExpanded(cell: MonthCell) {
    Column() {
      // 顶部：日期数字与农历
      Row({ space: 2 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Text(String(cell.day))
            .fontSize(12)
            .fontWeight(cell.isToday || cell.dateMs === this.selectedDate ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(!cell.inMonth
              ? $r('app.color.text_hint')
              : (cell.dateMs === this.selectedDate
                ? $r('app.color.button_text')
                : (cell.isToday ? $r('app.color.brand') : $r('app.color.text_primary'))))
            .width(20)
            .height(20)
            .textAlign(TextAlign.Center)
            .borderRadius(10)
            .backgroundColor(cell.dateMs === this.selectedDate
              ? $r('app.color.selected_bg')
              : (cell.isToday ? $r('app.color.today_bg') : Color.Transparent))

          if (cell.holidayBadge !== '') {
            Text(cell.holidayBadge)
              .fontSize(6)
              .fontColor('#FFFFFF')
              .backgroundColor(cell.holidayBadge === '休' ? '#FF3B30' : '#8E8E93')
              .borderRadius(2)
              .padding({ left: 1, right: 1 })
              .height(9)
              .lineHeight(9)
              .margin({ top: -1, right: -2 })
          }
        }

        Text(cell.lunar)
          .fontSize(8)
          .fontColor(!cell.inMonth ? $r('app.color.text_hint') : $r('app.color.text_hint'))
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 2, right: 2, top: 2 })

      // 日程事项列表（格内直接展示具体事项条，参考图3）
      Column({ space: 2 }) {
        ForEach(cell.events.slice(0, 2), (e: DisplayEvent) => {
          Row() {
            // 左侧色彩条
            Row()
              .width(2)
              .height(13)
              .borderRadius(1)
              .backgroundColor(e.color && e.color.length > 0 ? e.color : '#007DFF')

            Text(e.title)
              .fontSize(9)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 3 })
              .layoutWeight(1)
          }
          .width('100%')
          .height(15)
          .padding({ left: 2, right: 2 })
          .borderRadius(2)
          .backgroundColor($r('app.color.card_bg'))
          .opacity(!cell.inMonth ? 0.6 : 1.0)
          .onClick(() => {
            this.selectDayCell(cell.dateMs);
            this.showEventDetail(e);
          })
        }, (e: DisplayEvent) => `${e.isSystem ? 's' : 'l'}${e.id}_${e.startTime}_${e.title}`)

        // 超过2条显示 +N 标记
        if (cell.events.length > 2) {
          Text(`+${cell.events.length - 2}`)
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FF6B00')
            .padding({ left: 4 })
            .margin({ top: 1 })
        }
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .height('100%')
    .padding(2)
    .border({
      width: { right: 0.5, bottom: 0.5 },
      color: $r('app.color.shadow_color')
    })
    .backgroundColor(cell.dateMs === this.selectedDate ? '#0A007DFF' : Color.Transparent)
    .onClick(() => {
      this.selectDayCell(cell.dateMs);
      if (!cell.inMonth) {
        const d = new Date(cell.dateMs);
        this.displayYear = d.getFullYear();
        this.displayMonth = d.getMonth();
        this.rebuildPages();
        this.swiperGuard = true;
        this.swiperController.changeIndex(1, false);
        this.expandedSwiperController.changeIndex(1, false);
        this.reloadEvents();
      }
    })
  }

  /**
   * 月视图日期格（带选中正圆背景）。
   *
   * ⭐ SEL_CIRCLE 为什么套一层 Stack：
   *   Column 是 layoutWeight(1) 撑满格子的**矩形**，无论圆角给多大
   *   都只能是"方块"或"胶囊"，变不成正圆。只有独立的正方形容器
   *   取 50% 圆角才是真正的圆。Stack 居中叠放，圆在格子正中，内容压在上面。
   *
   *   ⚠️ 改过两轮才定下来：
   *     第一版把蓝底铺在 Column 上 → 得到 149×133 的圆角方块（用户不满意）
   *     这一版用 46vp 正方形 → 真正的圆
   */
  // RING_CLEANUP
  /**
   * 月/周视图的日期格。
   *
   * 层级设计（改过好几轮，这里定稿）：
   *   Column                       ← 整格，承接点击
   *     ├ Text(星期)               ← 仅周条有，**在圆外面**
   *     └ Stack
   *         ├ 圆底（选中=实蓝 / 今天=淡蓝，46vp）
   *         └ Column               ← 日期数字 / 农历 / 事件点，圆只包这三个
   *
   * ⚠️ 为什么星期放在 Stack 外面：
   *    放进圆里的话，为了让圆包住它就得把圆撑到 54vp，结果星期也被圈进圆内，
   *    视觉上很怪（用户明确否掉了）。
   *    放外面后圆只包 日期(72)+农历(27)+点(11)+间隙 ≈ 116px，46vp(138px) 够用，
   *    且与月视图完全一致。
   */
  @Builder
  dayCellCircle(cell: MonthCell, showWeekLabel: boolean = false) {
    Column({ space: 1 }) {
      // 星期标签：圆外，仅周条显示（月视图的星期在表头单独一行）
      if (showWeekLabel) {
        Text(WEEK_LABELS[(new Date(cell.dateMs).getDay() + 6) % 7])
          .fontSize(10)
          .fontColor(cell.dateMs === this.selectedDate
            ? $r('app.color.brand_text') : $r('app.color.text_secondary'))
      }
      Stack({ alignContent: Alignment.Center }) {
        // 圆底：选中实蓝、今天淡蓝，尺寸一致
        if (cell.dateMs === this.selectedDate) {
          Column()
            .width(this.wideLayout ? 40 : 46)
            .height(this.wideLayout ? 40 : 46)
            .borderRadius('50%')
            .backgroundColor($r('app.color.selected_bg'))
        } else if (cell.isToday) {
          Column()
            .width(this.wideLayout ? 40 : 46)
            .height(this.wideLayout ? 40 : 46)
            .borderRadius('50%')
            .backgroundColor($r('app.color.today_bg'))
        }
        Column({ space: 1 }) {
          Text(String(cell.day))
            .fontSize(this.wideLayout ? 12 : 13)
            .fontWeight(cell.isToday || cell.dateMs === this.selectedDate
              ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(!cell.inMonth
              ? $r('app.color.text_hint')
              : (cell.dateMs === this.selectedDate
                ? $r('app.color.button_text') : $r('app.color.text_primary')))
            .width(this.wideLayout ? 22 : 24)
            .height(this.wideLayout ? 22 : 24)
            .textAlign(TextAlign.Center)
            .borderRadius(this.wideLayout ? 11 : 12)
            // 背景一律交给底层圆，这里透明（否则"大圆里套小圈"）
            .backgroundColor(Color.Transparent)
          if (!this.wideLayout) {
            // 周条的农历提亮一档（text_secondary），月历保持 text_hint
            Text(cell.lunar)
              .fontSize(showWeekLabel ? 9 : 8)
              .fontColor(cell.dateMs === this.selectedDate
                ? $r('app.color.button_text')
                : (showWeekLabel ? $r('app.color.text_secondary') : $r('app.color.text_hint')))
              .maxLines(1)
          }
          // 事件点：无事件时透明但仍占位，保证行高一致、整月不跳
          Circle({ width: this.wideLayout ? 4 : 3.5, height: this.wideLayout ? 4 : 3.5 })
            .fill(cell.dateMs === this.selectedDate
              ? $r('app.color.button_text') : $r('app.color.soft_red'))
            .opacity(cell.hasEvent ? 1 : 0)
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .layoutWeight(1)
    .padding({ top: this.wideLayout ? 2 : 3, bottom: this.wideLayout ? 2 : 1 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.selectedDate = cell.dateMs;
      // 用户主动点了某天 ⇒ 记住这个日号，作为后续翻月的基准
      this.preferredDay = new Date(cell.dateMs).getDate();
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

/**
 * 列表视图的"待办 + 全天/跨天"区（#68）。
 *
 * 为什么做成独立组件：列表视图每天一张卡片，需要**每天独立折叠**
 * （用户反馈：原来多个卡片共用一个折叠状态，"要收都收、要展都展"）。
 * 独立组件 = 独立 @State topExpanded，天然互不影响。
 *
 * 为什么放在 DayTimelineView 外面：后者内部时间轴是固定高度 viewH()，
 * 在它里面插内容会被挤出去（实测渲染不出来）。
 */
@Component
struct AgendaTopBar {
  @Prop todos: DisplayEvent[] = [];
  @Prop allDay: DisplayEvent[] = [];
  onPick: (e: DisplayEvent) => void = (e: DisplayEvent): void => {
  };
  onToggleTodo: (t: DisplayEvent) => void = (t: DisplayEvent): void => {
  };

  /** 本卡片的折叠状态（每天独立） */
  @State private expanded: boolean = false;

  /** 合并条目：待办在前、全天在后 */
  private items(): TopBarItem[] {
    const out: TopBarItem[] = [];
    for (const td of this.todos) {
      const it = new TopBarItem();
      it.isTodo = true;
      it.ev = td;
      out.push(it);
    }
    for (const ev of this.allDay) {
      const it = new TopBarItem();
      it.isTodo = false;
      it.ev = ev;
      out.push(it);
    }
    return out;
  }

  private total(): number {
    return this.todos.length + this.allDay.length;
  }

  private visible(): TopBarItem[] {
    const all: TopBarItem[] = this.items();
    if (this.expanded || all.length <= 3) {
      return all;
    }
    return all.slice(0, 3);
  }

  build() {
    Column() {
      if (this.total() > 0) {
      Column({ space: 4 }) {
        ForEach(this.visible(), (item: TopBarItem) => {
          if (item.isTodo) {
            Row({ space: 8 }) {
              Stack() {
                if (item.ev.completed) {
                  Path()
                    .width(18)
                    .height(18)
                    .commands('M5 9.5 L7.5 12.5 L13 6.5')
                    .stroke('#FFFFFF')
                    .strokeWidth(2)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
                    .fill(Color.Transparent)
                }
              }
              .width(18)
              .height(18)
              .borderRadius(9)
              .backgroundColor(item.ev.completed ? item.ev.color : 'rgba(0,0,0,0)')
              .border({ width: 1.5, color: item.ev.color })
              .onClick(() => {
                this.onToggleTodo(item.ev);
              })
              Text(item.ev.title === '' ? '(无标题待办)' : item.ev.title)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .decoration({
                  type: item.ev.completed ? TextDecorationType.LineThrough : TextDecorationType.None
                })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .height(24)
            .padding({ left: 8, right: 8 })
            .borderRadius(6)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.5, color: $r('app.color.shadow_color') })
          } else {
            Row({ space: 6 }) {
              Text(item.ev.isAllDay ? '全天' : '跨天')
                .fontSize(9)
                .fontColor('#FFFFFF')
                .backgroundColor('#26000000')
                .borderRadius(6)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              Text(item.ev.title === '' ? '(无标题)' : item.ev.title)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .height(24)
            .padding({ left: 8, right: 8 })
            .borderRadius(6)
            .backgroundColor(item.ev.color)
            .onClick(() => this.onPick(item.ev))
          }
        }, (item: TopBarItem) => `ab_${item.isTodo ? 't' : 'a'}_${item.ev.id}_${item.ev.completed ? 1 : 0}`)

        if (this.total() > 3) {
          Row({ space: 4 }) {
            Text(this.expanded ? '收起' : `还有 ${this.total() - 3} 条`)
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
            Text(this.expanded ? '⌃' : '⌄')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
          }
          .width('100%')
          .height(18)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.expanded = !this.expanded;
          })
        }
      }
      .width('100%')
      .padding({ bottom: 4 })
      }
    }
    .width('100%')
  }
}

/**
 * 顶部固定区（全天日程 + 待办）的一个条目（#68）。
 * ArkTS 不允许内联对象字面量类型，必须用命名 class。
 */
class TopBarItem {
  isTodo: boolean = false;   // true=待办（带勾选圈） false=全天/跨天日程（色块）
  ev: DisplayEvent = new DisplayEvent();
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
  onToggleTodo: (t: DisplayEvent) => void = (t: DisplayEvent): void => {}; // 勾选待办回调
  private scroller: Scroller = new Scroller();
  @State private viewportH: number = 0; // 滚动视口高度（由 Scroll 实测，用于把"当前时刻"居中）
  /** ⭐ 顶部固定区（全天日程 + 待办）是否展开（#68）
   *  默认折叠：最多显示 3 条，超出显示向下箭头。折叠是为了避免浮动区盖住大片时间轴视野。 */
  @State private topExpanded: boolean = false;
  /** 顶部"全天/跨天"区高度 —— #68 起该区移出 Scroll（浮动固定），
   *  不再参与滚动偏移计算，恒为 0。保留字段仅为兼容旧引用。 */
  @State private allDayH: number = 0;
  private pendingScroll: boolean = false;

  aboutToAppear(): void {
    this.scrollToNow();
  }

  /** 显示日变为"今天"（或从今天切走）时触发；切到今天则自动定位到当前时刻 */
  private onShowNowLine(): void {
    this.scrollToNow();
  }

  /**
   * 顶部固定区要显示的条目（#68）：**待办在前、全天/跨天在后**，合并成一个列表。
   * 合并而不是分两块，是为了统一"最多显示 3 条"的限制 —— 否则两块各自 3 条会变 6 条。
   */
  private topItems(): TopBarItem[] {
    const out: TopBarItem[] = [];
    for (const td of this.timeline.todos) {
      const it = new TopBarItem();
      it.isTodo = true;
      it.ev = td;
      out.push(it);
    }
    for (const ev of this.timeline.allDay) {
      const it = new TopBarItem();
      it.isTodo = false;
      it.ev = ev;
      out.push(it);
    }
    return out;
  }

  /** 顶部固定区总条数 */
  private topCount(): number {
    return this.timeline.todos.length + this.timeline.allDay.length;
  }

  /** 折叠时最多显示 3 条（#68）；展开后显示全部 */
  private topLimit(): number {
    return this.topExpanded ? this.topCount() : 3;
  }

  /** 折叠时是否还有被藏起来的条目（决定要不要画展开箭头） */
  private topHasMore(): boolean {
    return this.topCount() > 3;
  }

  /** 取前 N 条（展开状态由 topLimit 决定） */
  private topVisible(): TopBarItem[] {
    const all: TopBarItem[] = this.topItems();
    const lim: number = this.topLimit();
    return all.length > lim ? all.slice(0, lim) : all;
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
    // #68：全天/待办区已移出 Scroll（浮动固定），偏移里不再加 allDayH。
    // 时间轴只从 viewTop 开始 → 直接用比例换算即可。
    const y: number = (TimelineUtil.nowRatio(this.nowMs) - this.viewTop()) * this.totalH() - vp / 2;
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
      // ⭐ 顶部固定区（待办 + 全天/跨天）#68：放在 Scroll **之外** → 不随时间轴滚动。
      //    原来它在 timelineBody 里，会被"自动滚到当前时刻"带走，
      //    导致下午 16 点打开时全天日程看不见。
      //    ⚠️ 只对 scrollable（周/月视图）做固定区：
      //    列表视图（scrollable=false）的卡片高度由"按日程起止截断的时间轴"决定，
      //    在里面再插一个固定区会被固定高度的 timelineBody 挤到卡片外（实测红块跑到 y=620）。
      //    列表视图逐天展开、不存在"自动滚到当前时刻"的问题，所以它继续把
      //    待办+全天放在 timelineBody 内部跟随内容即可。
      // ⭐ 顶部固定区（待办 + 全天/跨天）#68。
      //    周/月视图：放在 Scroll 之外 → 不随时间轴滚动，保持固定。
      //    列表视图：交给下面 else 分支（timelineBody 之前）渲染，那里才有正确的高度上下文。
      if (this.scrollable) {
        this.topBar()
      }
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
        // 列表视图：待办 + 全天/跨天（#68）。放在 timelineBody 之前，
        // 这里的高度上下文才正确（放根 Column 第一位会被 ListItem 裁掉）。
        this.topBar()
        this.timelineBody()
      }
    }
    .width('100%')
    // 自带滚动（月/周视图）：占满父容器剩余高度；平铺（列表视图）：按内容自适应高度
    // —— 列表里每天需要的高度不同（视窗已按日程起止截断），必须让外层随内容伸缩，否则会显示不全
    .layoutWeight(this.scrollable ? 1 : 0)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 顶部固定区（#68）：待办 + 全天/跨天日程，**不随时间轴滚动**。
   *
   * 为什么加这个区：原来它们排在时间轴最前面，但打开日视图会自动滚到当前时刻
   * （比如下午 16 点），于是全天日程被滚上去看不见了。改成浮动固定后，
   * 不管时间轴怎么滚，它们都贴在日期行下方。
   *
   * 折叠机制（用户提的折中方案）：全天+待办合计**最多显示 3 条**，
   * 超出时显示向下箭头，点一下展开全部；避免条数多时盖住大片视野。
   */
  /**
   * 顶部区：待办 + 全天/跨天（#68）。
   *
   * @param render 是否真的渲染。ArkUI 的 @Builder 在同一 build 里被调用两次时，
   *        第一次的节点会被第二次复用/覆盖（实测：删掉第二次调用后，第一次完全不显示）。
   *        所以这里保留两次调用位：Scroll 分支前那次传 false（占位不渲染），
   *        非滚动分支传 true（真正渲染），避免"显示两遍"。
   */
  @Builder
  private topBar() {
    if (this.topCount() > 0) {
      Column({ space: 4 }) {
        ForEach(this.topVisible(), (item: TopBarItem) => {
          if (item.isTodo) {
            // ---- 待办行：勾选圈 + 标题 ----
            Row({ space: 8 }) {
              // 矢量勾（#50）：字符 ✓ 依赖字体，粗细/居中不稳定
              Stack() {
                if (item.ev.completed) {
                  Path()
                    .width(18)
                    .height(18)
                    .commands('M5 9.5 L7.5 12.5 L13 6.5')
                    .stroke('#FFFFFF')
                    .strokeWidth(2)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
                    .fill(Color.Transparent)
                }
              }
              .width(18)
              .height(18)
              .borderRadius(9)
              .backgroundColor(item.ev.completed ? item.ev.color : 'rgba(0,0,0,0)')
              .border({ width: 1.5, color: item.ev.color })
              .onClick(() => {
                this.onToggleTodo(item.ev);
              })
              Text(item.ev.title === '' ? '(无标题待办)' : item.ev.title)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .decoration({
                  type: item.ev.completed ? TextDecorationType.LineThrough : TextDecorationType.None
                })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .height(24)
            .padding({ left: 8, right: 8 })
            .borderRadius(6)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.5, color: $r('app.color.shadow_color') })
          } else {
            // ---- 全天/跨天日程：色块 ----
            Row({ space: 6 }) {
              Text(item.ev.isAllDay ? '全天' : '跨天')
                .fontSize(9)
                .fontColor('#FFFFFF')
                .backgroundColor('#26000000')
                .borderRadius(6)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              if (!item.ev.writable) {
                Text('只读')
                  .fontSize(9)
                  .fontColor('#FFFFFF')
                  .border({ width: 0.5, color: '#FFFFFF' })
                  .borderRadius(4)
                  .padding({ left: 4, right: 4, top: 0, bottom: 0 })
              }
              Text(item.ev.title === '' ? '(无标题)' : item.ev.title)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (item.ev.location !== '') {
                Text(item.ev.location)
                  .fontSize(10)
                  .fontColor('#D9FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 100 })
              }
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .height(24)
            .padding({ left: 8, right: 8 })
            .borderRadius(6)
            .backgroundColor(item.ev.color)
            .onClick(() => this.onPick(item.ev))
          }
        }, (item: TopBarItem) => `tb_${this.timeline.dateKey}_${item.isTodo ? 't' : 'a'}_${item.ev.id}_${item.ev.completed ? 1 : 0}`)

        // 展开/收起箭头（合计超过 3 条时才出现）
        if (this.topHasMore()) {
          Row({ space: 4 }) {
            Text(this.topExpanded ? '收起' : `还有 ${this.topCount() - 3} 条`)
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
            Text(this.topExpanded ? '⌃' : '⌄')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
          }
          .width('100%')
          .height(18)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.topExpanded = !this.topExpanded;
          })
        }
      }
      .width('100%')
      .padding({ bottom: 6 })
    }
  }

  /** 时间轴主体：左侧小时刻度 + 右侧按冲突组分行、组内按列并排（顶部固定区已移出，#68） */
  @Builder
  private timelineBody() {
    Column() {
      // 待办+全天区由 build() 负责渲染（#68），这里只有时间轴本体。
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
              .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.grid_line') } })
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
        .border({ width: { left: 0.5 }, color: { left: $r('app.color.grid_line') } })
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
          .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.grid_line') } })
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