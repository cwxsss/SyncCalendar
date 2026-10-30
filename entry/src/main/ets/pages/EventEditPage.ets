// entry/src/main/ets/pages/EventEditPage.ets
// 日程编辑页：新建 / 修改 / 删除日程（一律属于某个 CalDAV 日历本，不再支持"本机"日程）
import { curves, router, KeyboardAvoidMode } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { DavAccount, AccountStore, CalSource, BookPalette, LOCAL_CAL_KEY } from '../common/AccountStore';
import { EventDb, LocalEvent } from '../common/EventDb';
import { AppSettings } from '../common/AppSettings';
import { DavClient } from '../common/DavClient';
import { SyncEngine } from '../common/SyncEngine';
import { ReminderService } from '../common/ReminderService';
import { SystemCalendarMirror } from '../common/SystemCalendarMirror';
import { CardDataService } from '../common/CardDataService';
import { LogUtil } from '../common/LogUtil';
import { IcsUtil } from '../common/IcsUtil';
import { RruleUtil } from '../common/RruleUtil';
import { PlaceSuggest, PlaceItem } from '../common/PlaceSuggest';

/** 重复系列某次发生的前后边界（用于 EXDATE / UNTIL / 拆分） */
class SeriesBounds {
  thisOcc: number = 0;    // 本次目标的（原始）发生时刻
  beforeThis: number = 0; // 此次之前一点（截断 UNTIL 用），= 上一次与本次的中点或本次-1s
  nextOcc: number = 0;    // 下一次发生时刻（0 = 已是最后一次）
}

/** 可选的日历本 */
class BookChoice {
  calKey: string = '';
  href: string = '';
  name: string = '';
  color: string = '#007DFF';
}

@Entry
@Component
struct EventEditPage {
  @State title: string = '';
  @State location: string = '';
  /**
   * ⭐ 地点补全（鸿蒙 Map Kit / Site Kit）：
   *   placeItems   —— 候选数据（**不参与页面布局**，由 bindPopup 渲染成浮层）
   *   placeLoading —— 是否正在请求，浮层内显示"搜索中"
   *   placeOpen    —— 浮层是否弹出（绑在输入框上，向上弹）
   *   placeHint    —— 无结果/地图能力不可用时的提示（不阻塞手输地点）
   *
   * ⚠️ 为什么必须是浮层而不是内联列表：内联列表改变表单高度 ⇒ 输入框跟着移动 ⇒
   *    每次"搜索中/出结果/结果变少"都要滚动纠正 ⇒ 用户看到输入框反复上下跳。
   */
  @State placeItems: PlaceItem[] = [];
  @State placeLoading: boolean = false;
  @State placeOpen: boolean = false;
  @State placeHint: string = '';
  /** 用户是否已从候选里选中（选中后不再自动弹候选，避免"选完又弹出"） */
  private placePicked: boolean = false;
  /**
   * 最后一次**程序写入**输入框的文本（选中候选后回写的地址）。
   * TextInput 的 text 被程序改写同样会触发 onChange；用它精确识别"这次 onChange
   * 不是用户打字造成的"，从而不重复发起搜索。
   */
  private lastAppliedText: string = '';
  /** 地点输入框当前是否聚焦（仅用于日志/状态，不再驱动滚动） */
  private placeFocused: boolean = false;
  /** 输入防抖定时器 */
  private placeTimer: number = -1;
  /** 表单滚动控制器（键盘避让由系统 RESIZE 模式负责，这里不再主动滚） */
  private formScroller: Scroller = new Scroller();
  @State description: string = '';
  @State allDay: boolean = false;
  @State startMs: number = 0;
  @State endMs: number = 0;
  @State books: BookChoice[] = [];
  @State chosenKey: string = '';
  @State isSaving: boolean = false;
  /**
   * 表单状态行文字。
   * ⚠️ 它渲染在表单**最底部**（"删除日程"按钮上方），用户在顶部点"保存"时根本看不见。
   *    所以它只能作为"事后可复查的记录"，**不能**作为唯一的错误反馈手段 ——
   *    真正的提醒必须走 showFormError()：Toast（必可见）+ 字段标红 + 滚到出错字段。
   */
  @State statusMsg: string = '';
  /**
   * ⭐ 哪个字段校验没过（'' = 没有）。
   * 用途：把对应输入框描红并显示一条紧贴字段的红字说明，
   * 让用户一眼看到"哪儿错了"，而不是在一屏之外找一行小字。
   * 取值：'title' | 'time' | ''
   */
  @State errorField: string = '';
  @State isExisting: boolean = false;
  @State repeatMode: string = 'none'; // none|daily|workday|weekly|monthly|yearly|custom
  /**
   * ⭐ 重复的"结束条件"（新建与编辑都可用）：
   *   never  永不结束
   *   until  重复到某个日期为止（界面上选具体日期）
   *   count  重复固定次数
   */
  @State repeatEnd: string = 'never';
  @State repeatUntil: number = 0;   // 截止日期（当天 0 点毫秒）
  @State repeatCount: number = 10;  // 重复次数
  /** ⭐ 编辑时载入的原始 RRULE：用于判断"新建的结束条件是否会覆盖已有规则" */
  private originalRrule: string = '';
  /** ⭐ 发生时刻是否由调用方传入（true=用户点的是某一次，false=用户点的是主事件本身） */
  private occProvided: boolean = false;
  @State reminderList: number[] = []; // 提前提醒分钟数（多选），空 = 不提醒
  /**
   * ⭐ 底部弹层：**整个页面只能挂一个 `bindSheet`**。
   *  ArkUI 里同一组件挂多个 bindSheet 时，后一个会覆盖前一个 —— 实测表现就是
   *  "时间选择框白框一闪而过、什么都没出来"（范围弹层把时间弹层顶掉了）。
   *  因此这里用一个状态 + 一个模式来复用同一个弹层：
   *    sheetMode = 'picker' → 日期/时间选择
   *    sheetMode = 'scope'  → 重复日程范围选择
   */
  @State sheetShow: boolean = false;
  @State sheetMode: string = 'picker';
  @State pickerIsEnd: boolean = false;
  @State pickDate: Date = new Date();
  @State pickHour: number = 9;
  @State pickMin: number = 0;
  /** ⭐ 重复日程编辑范围：'one' 仅此次 / 'future' 此次及以后 / 'all' 全部 */
  @State scope: string = 'all';
  private pendingDelete: boolean = false;     // 该弹层是"保存"还是"删除"流程
  /**
   * ⭐ 载入时的**原始行快照**（不可变）。
   * `doSave` 会就地改写 `this.event` 的 calKey/href/startTime 等字段，
   * 而"重复系列"的范围计算（EXDATE / UNTIL / 拆系列）必须依据**原始**的
   * 系列标识（原 calKey、原 href、原发生时刻），否则会算错。
   */
  private original: LocalEvent | null = null;
  /** 本次编辑的"目标发生时刻"（未改期时 = 原发生时刻；用户改了开始时间 → 新时刻） */
  private occStartMs: number = 0;
  private event: LocalEvent | null = null;

  aboutToAppear(): Promise<void> {
    // 键盘避让不阻塞页面加载：拿窗口是异步的，失败也只是少一层滚动校正
    this.setupKeyboardAvoid();
    return this.initPage();
  }

  /** 页面销毁：清掉地点补全的防抖定时器 */
  aboutToDisappear(): void {
    this.cancelSuggestTimer();
  }

  /**
   * ⭐ 键盘避让：改成 RESIZE 模式。
   * 默认 OFFSET 是「整页上移」，页面上移后表单底部（地点/备注/按钮）会被顶出屏幕。
   * RESIZE 是「把页面高度压缩到键盘上沿」，滚动区域随之变矮，
   * 聚焦的输入框由系统自动滚入可见区，**无需再手动 scrollBy**。
   *
   * ⚠️ 曾经写过"手动量矩形 + scrollBy 对齐"的方案，是错的方向：
   *    ① getRectangleById 返回 px、scrollBy 收 vp，单位混用会把输入框推飞；
   *    ② 更根本的是——只要候选参与布局，位置就会反复变化，
   *       靠"事后纠正"必然表现为抖动。所以候选改成了浮层（见 placePopup）。
   */
  private setupKeyboardAvoid(): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`设置键盘避让模式失败: ${e.message}`);
    }
  }

  private async initPage(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    // 收集可写入的日历本：只取 **CalDAV** 可写日历本（"本机"不再出现在选择里）；
    // 只读日历本同样不出现
    const sources: CalSourceWithHref[] = await CalendarDataBridge.loadWritableDavSources(context);
    const choices: BookChoice[] = [];
    for (const s of sources) {
      const b = new BookChoice();
      b.calKey = s.calKey;
      b.href = s.href;
      b.name = s.name;
      b.color = s.color;
      choices.push(b);
    }
    this.books = choices;
    if (choices.length === 0) {
      // 没有可写入的 CalDAV 日历本 → 日程无处可写，给明确指引（保存时也会再拦一次）
      this.statusMsg = '还没有可写入的 CalDAV 日历本，请先到「更多 → 账号管理」添加账号';
    }

    // 编辑既有事件
    const pendingId: number | undefined = AppStorage.get<number>('pendingEventId');
    if (pendingId !== undefined && pendingId > 0) {
      const loaded = await EventDb.getById(context, pendingId);
      if (loaded !== null) {
        this.event = loaded;
        // ⭐ 原始行快照：series 范围计算必须用"载入时"的值（doSave 会改写 this.event）。
        //    ⚠️ 必须是**完整**拷贝 —— 曾经漏了 title/description/location/reminders，
        //    导致"只改这一次"时把这一行还原成空标题（BUG：已有标题被删没）。
        const snap = new LocalEvent();
        snap.id = loaded.id;
        snap.uid = loaded.uid;
        snap.calKey = loaded.calKey;
        snap.href = loaded.href;
        snap.remotePath = loaded.remotePath;
        snap.title = loaded.title;
        snap.description = loaded.description;
        snap.location = loaded.location;
        snap.startTime = loaded.startTime;
        snap.endTime = loaded.endTime;
        snap.recurrenceId = loaded.recurrenceId;
        snap.rrule = loaded.rrule;
        snap.exdate = loaded.exdate;
        snap.isAllDay = loaded.isAllDay;
        snap.recurring = loaded.recurring;
        snap.deleted = loaded.deleted;
        snap.reminder = loaded.reminder;
        snap.reminders = loaded.reminders.slice();
        this.original = snap;
        this.originalRrule = loaded.rrule;
        this.isExisting = true;
        this.title = loaded.title;
        this.location = loaded.location;
        this.description = loaded.description;
        this.allDay = loaded.isAllDay;
        this.startMs = loaded.startTime;
        this.endMs = loaded.endTime;
        this.chosenKey = loaded.calKey;
        // ⭐ 若这条日程所属的日历本不在"可写日历本"列表里（例如该本被标记只读、
        //    或服务器写权限探测暂时失败），把它补进选择列表，保证 chosenBook() 一定能解析到 ——
        //    否则保存会被拦下，用户永远进不到"重复日程范围选择"这一步。
        if (loaded.calKey !== LOCAL_CAL_KEY
          && !choices.some((c: BookChoice): boolean => c.calKey === loaded.calKey)) {
          const info: BookLookup | null =
            await CalendarDataBridge.lookupBook(context, loaded.calKey, loaded.href);
          if (info !== null) {
            const b = new BookChoice();
            b.calKey = info.calKey;
            b.href = info.href;
            b.name = info.name;
            b.color = info.color;
            this.books = this.books.concat([b]);
          }
        }
        // 历史遗留的"本机"日程：本应用已不再支持本机日程，改为引导用户挑一个 CalDAV 日历本
        // （保存时 calKey/href 会改写为该日历本，事件随后被推送到服务器）
        if (loaded.calKey === LOCAL_CAL_KEY) {
          this.statusMsg = '这条日程原先只存在「本机」（不同步）。请选一个 CalDAV 日历本，保存后即会同步到服务器。';
        }
        this.repeatMode = loaded.rrule !== '' ? this.modeFromRrule(loaded.rrule) : 'none';
        this.parseRepeatEnd(loaded.rrule);
        this.reminderList = loaded.reminders.length > 0 ? loaded.reminders
          : (loaded.reminder > 0 ? [loaded.reminder] : []);
        // ⭐ 目标发生时刻（"仅这一次"要排除/覆盖的那一次）：
        //  ① 覆盖行 → 用 RECURRENCE-ID（原始发生时刻）
        //  ② 调用方显式传入了"用户点的是哪一次" → 用它（列表里点开的某次发生，行的 id 是主事件 id，
        //     若不传，就会把"主事件的第一次发生"当成目标 → 表现出来就是"选仅这一次却改了全部"）
        //  ③ 兜底才用行本身的开始时间
        const occFromCaller: number | undefined = AppStorage.get<number>('pendingOccurrenceTs');
        if (loaded.recurrenceId > 0) {
          this.occStartMs = loaded.recurrenceId;
        } else if (occFromCaller !== undefined && occFromCaller > 0) {
          this.occStartMs = occFromCaller;
          this.occProvided = true;
        } else {
          this.occStartMs = loaded.startTime;
        }
        // ⭐ 用户点开的是"某一次发生"时，编辑页必须显示**那一次**的实际时间，
        //    而不是重复主事件第一次发生的时间（否则时间框显示错误，用户改时间也改错基准）。
        if (this.occProvided && this.occStartMs > 0) {
          const dur: number = Math.max(0, loaded.endTime - loaded.startTime);
          this.startMs = this.occStartMs;
          this.endMs = this.allDay ? this.occStartMs + 86399999 : this.occStartMs + dur;
        }
        // 消费后立即清掉，避免影响下一次新建/编辑
        AppStorage.setOrCreate<number>('pendingOccurrenceTs', 0);
        return;
      }
    }
    // 新建：日期取所选日（未选则今天），时间取当前时刻；结束 = 开始 + 1 小时
    const base: number = AppStorage.get<number>('pendingEventDate') ?? Date.now();
    const dayStart = new Date(new Date(base).getFullYear(), new Date(base).getMonth(),
      new Date(base).getDate()).getTime();
    const now = new Date();
    this.startMs = dayStart + now.getHours() * 3600000 + now.getMinutes() * 60000;
    this.endMs = this.startMs + 3600000;
    if (choices.length > 0) {
      this.chosenKey = choices[0].calKey;
    }
  }

  // ==================== 地点补全（鸿蒙 Map Kit / Site Kit） ====================

  /**
   * 输入防抖：停止输入 350ms 后才真正发请求。
   * 好处：① 不把服务端配额/网络浪费在"每敲一个字"上；② 避免结果闪烁。
   * ⚠️ 这里只用「关键词补全」这一种能力（不需要定位权限），
   *    所以**不需要**申请 LOCATION 权限，符合"权限只在用户主动点该功能时申请"的约束。
   */
  private scheduleSuggest(v: string): void {
    this.cancelSuggestTimer();
    const q: string = v.trim();
    if (q.length < 1) {
      this.closePlacePopup();
      return;
    }
    this.placeTimer = setTimeout(() => {
      this.placeTimer = -1;
      this.runSuggest(q, false);
    }, 350);
  }

  private cancelSuggestTimer(): void {
    if (this.placeTimer !== -1) {
      clearTimeout(this.placeTimer);
      this.placeTimer = -1;
    }
  }

  private async runSuggest(q: string, forceOpen: boolean): Promise<void> {
    if (this.placePicked && !forceOpen) {
      return;
    }
    if (PlaceSuggest.isUnavailable()) {
      // 地图服务没开通：给一次明确提示，然后永久静默（不阻塞手输）
      this.placeHint = '地图服务不可用，可直接手动输入地点';
      this.placeItems = [];
      this.placeOpen = true;
      return;
    }
    // ⭐ 浮层一直保持展开（从"搜索中"过渡到结果），中间不收起、不重弹 ——
    //    收起再弹会让浮层闪一下，看起来像"消失了又出现"。
    this.placeLoading = true;
    this.placeHint = '';
    this.placeOpen = true;
    try {
      const c = this.getUIContext().getHostContext();
      const ctx: common.Context | undefined = c;
      // 先补全；补全空则内部会自动退到关键字搜索
      let items: PlaceItem[] = await PlaceSuggest.query(q, ctx);
      if (items.length === 0 && !PlaceSuggest.isUnavailable()) {
        items = await PlaceSuggest.search(q, ctx);
      }
      // ⭐ 丢弃过期结果：用户又改了输入框，就别再覆盖成旧候选
      if (q !== this.location.trim()) {
        return;
      }
      this.placeItems = items.slice(0, 6);
      if (this.placeItems.length === 0) {
        this.placeHint = PlaceSuggest.isUnavailable()
          ? '地图服务不可用，可直接手动输入地点'
          : '没有找到匹配地点，可直接手动输入';
        // 无结果也留在浮层里给提示；用户再输入会被下一次请求覆盖
        this.placeOpen = true;
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`地点补全异常: ${e.message}`);
      this.placeItems = [];
      this.placeHint = '地点搜索失败，可直接手动输入';
      this.placeOpen = true;
    } finally {
      this.placeLoading = false;
    }
  }

  /**
   * ⭐ 候选浮层（bindPopup）的内容。
   *
   * 为什么是浮层而不是内联列表：
   *   内联列表会改变表单高度 ⇒ 输入框位置随之变化 ⇒ 每次"搜索中/出结果/结果变少"
   *   都要靠滚动去纠正 ⇒ 用户看到的就是**输入框上下跳好几次**。
   *   浮层不参与布局，出现与消失**完全不移动输入框**，这是唯一能根治该问题的结构。
   *
   * 为什么向上弹（Placement.Top）：
   *   输入框在表单下部、键盘又在下方，向下弹必然被键盘盖住；
   *   向上弹则整块候选都落在输入框与标题之间的空白区。
   */
  @Builder
  placePopup() {
    Column({ space: 0 }) {
      if (this.placeLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color($r('app.color.text_hint'))
          Text('搜索中…')
            .fontSize(13)
            .fontColor($r('app.color.text_hint'))
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      } else if (this.placeItems.length > 0) {
        // 限高 + 内部滚动：候选最多 6 条，一次全铺开会顶到屏幕顶部
        List() {
          ForEach(this.placeItems, (it: PlaceItem, idx: number) => {
            ListItem() {
              Column({ space: 2 }) {
                Text(it.title)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Start)
                if (it.subtitle !== '') {
                  Text(it.subtitle)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            }
            .onClick(() => {
              this.applyPlace(it);
            })
          }, (it: PlaceItem, idx: number) => `${it.siteId}_${idx}`)
        }
        .width('100%')
        .constraintSize({ maxHeight: 216 })
        .scrollBar(BarState.Auto)
        .divider({ strokeWidth: 0.5, color: $r('app.color.shadow_color') })
      } else {
        Text(this.placeHint !== '' ? this.placeHint : '没有找到匹配地点，可直接手动输入')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  /** 选中一条候选：写进地点输入框并收起列表 */
  private applyPlace(it: PlaceItem): void {
    // ⭐ 顺序很关键：先收起浮层，再写文本。
    //    TextInput 的 text 被程序改写会触发 onChange，若此时 placePicked 已被
    //    onChange 重置为 false，就会**重新发起一次搜索** → 用户看到
    //    "候选框消失了一下又冒出来一次"。用 lastAppliedText 精确识别这类回写。
    this.cancelSuggestTimer();
    this.closePlacePopup();
    this.placePicked = true;
    this.lastAppliedText = it.locationText;
    this.location = it.locationText;
  }

  /** 收起候选浮层（统一入口，保证 placePicked 之外的状态都被清干净） */
  private closePlacePopup(): void {
    this.placeOpen = false;
    this.placeLoading = false;
    this.placeItems = [];
    this.placeHint = '';
  }

  /** 打开系统地图选点页（可搜索、可周边、可拖图钉） */
  private async pickOnMap(): Promise<void> {
    const c = this.getUIContext().getHostContext();
    if (c === undefined) {
      return;
    }
    const it: PlaceItem | null = await PlaceSuggest.pickOnMap(c as common.UIAbilityContext);
    if (it === null) {
      // 用户取消，或地图服务不可用
      if (PlaceSuggest.isUnavailable()) {
        this.placeHint = '地图服务不可用，可直接手动输入地点';
      }
      return;
    }
    this.applyPlace(it);
  }

  private chosenBook(): BookChoice | null {
    const found = this.books.find((b: BookChoice): boolean => b.calKey === this.chosenKey);
    if (found !== undefined) {
      return found;
    }
    // ⭐ 兜底：编辑既有日程时，若它的日历本恰好不在"可写日历本"列表里
    //    （例如该本被标记只读、或服务器写权限探测暂时失败），
    //    仍然用这条日程自己的 calKey/href 构造一个目标 —— 否则 chosenBook() 返回 null，
    //    保存会被直接拦下，用户只看到一行错误提示，永远进不到"重复日程范围选择"。
    if (this.event !== null && this.event.calKey !== '' && this.event.calKey === this.chosenKey) {
      const b = new BookChoice();
      b.calKey = this.event.calKey;
      b.href = this.event.href;
      b.name = '';
      return b;
    }
    return null;
  }

  private fmtDate(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  private fmtTime(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  /** 重复模式 → RRULE 字符串（RruleUtil 已支持这些规则） */
  private rruleForMode(mode: string): string {
    if (mode === 'daily') {
      return 'FREQ=DAILY';
    }
    if (mode === 'workday') {
      return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    }
    if (mode === 'weekly') {
      return 'FREQ=WEEKLY';
    }
    if (mode === 'monthly') {
      return 'FREQ=MONTHLY';
    }
    if (mode === 'yearly') {
      return 'FREQ=YEARLY';
    }
    return '';
  }

  /** RRULE → 重复模式（无法识别的规则归为 custom，保存时保留原规则） */
  private modeFromRrule(rrule: string): string {
    const u: string = rrule.toUpperCase();
    if (u.includes('FREQ=DAILY')) {
      return 'daily';
    }
    if (u.includes('FREQ=WEEKLY')) {
      const hasWeekday: boolean = u.includes('MO') && u.includes('TU') && u.includes('WE')
        && u.includes('TH') && u.includes('FR');
      return hasWeekday ? 'workday' : 'weekly';
    }
    if (u.includes('FREQ=MONTHLY')) {
      return 'monthly';
    }
    if (u.includes('FREQ=YEARLY')) {
      return 'yearly';
    }
    return 'custom';
  }

  /** 从已有 RRULE 解析出"结束条件"（用于编辑时回显"重复到某天/共几次"） */
  private parseRepeatEnd(rrule: string): void {
    if (rrule === '') {
      this.repeatEnd = 'never';
      return;
    }
    const u: string = rrule.toUpperCase();
    // COUNT=n
    const cm = /COUNT=(\d+)/.exec(u);
    if (cm !== null) {
      this.repeatEnd = 'count';
      this.repeatCount = Number(cm[1]) > 0 ? Number(cm[1]) : 10;
      return;
    }
    // UNTIL=yyyymmddThhmmssZ 或 yyyymmdd
    const um = /UNTIL=(\d{8})(T\d{6}Z?)?/.exec(u);
    if (um !== null) {
      this.repeatEnd = 'until';
      const y: number = Number(um[1].substring(0, 4));
      const mo: number = Number(um[1].substring(4, 6));
      const d: number = Number(um[1].substring(6, 8));
      this.repeatUntil = new Date(y, mo - 1, d).getTime();
      return;
    }
    this.repeatEnd = 'never';
  }

  /** 把当前"重复模式 + 结束条件"合成 RRULE 字符串 */
  private buildRrule(): string {
    const base: string = this.rruleForMode(this.repeatMode);
    if (base === '' || this.repeatMode === 'custom') {
      return ''; // custom 由调用方保留原规则
    }
    if (this.repeatEnd === 'count') {
      return `${base};COUNT=${Math.max(1, Math.round(this.repeatCount))}`;
    }
    if (this.repeatEnd === 'until' && this.repeatUntil > 0) {
      // UNTIL 用"截止日当天 23:59:59"（本地时区），避免把当天那次排除掉
      const d = new Date(this.repeatUntil);
      const end: number = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59).getTime();
      return `${base};UNTIL=${IcsUtil.fmtIcsTime(end, false)}`;
    }
    return base; // 永不结束
  }

  /**
   * ⭐ 编辑既有重复日程时：用户在界面上调整了"结束条件"才覆盖原 RRULE；
   * 没动过就原样保留（防止把服务器上的复杂规则简单化掉）。
   */
  private effectiveRrule(): string {
    if (this.repeatMode === 'custom') {
      return this.originalRrule;
    }
    const built: string = this.buildRrule();
    if (this.originalRrule === '') {
      return built;
    }
    // 原有规则的 FREQ 与当前模式一致、且用户没有显式改结束条件 → 保留原规则
    const freqOf = (m: string): string => this.modeFromRrule(m);
    if (freqOf(this.originalRrule) === this.repeatMode
      && this.repeatEndMatches(this.originalRrule)) {
      return this.originalRrule;
    }
    return built;
  }

  /** 原 RRULE 的结束条件是否与界面当前选择一致 */
  private repeatEndMatches(rrule: string): boolean {
    const u: string = rrule.toUpperCase();
    if (this.repeatEnd === 'never') {
      return !u.includes('COUNT=') && !u.includes('UNTIL=');
    }
    if (this.repeatEnd === 'count') {
      const m = /COUNT=(\d+)/.exec(u);
      return m !== null && Number(m[1]) === Math.round(this.repeatCount);
    }
    if (this.repeatEnd === 'until') {
      const m = /UNTIL=(\d{8})/.exec(u);
      if (m === null) {
        return false;
      }
      const y = Number(m[1].substring(0, 4));
      const mo = Number(m[1].substring(4, 6));
      const d = Number(m[1].substring(6, 8));
      const a = new Date(y, mo - 1, d);
      const b = new Date(this.repeatUntil);
      return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
        && a.getDate() === b.getDate();
    }
    return false;
  }

  /** 打开"重复结束条件"日期选择弹层（复用唯一的底部弹层） */
  private openRepeatUntilPicker(): void {
    const base = this.repeatUntil > 0 ? new Date(this.repeatUntil) : new Date(this.startMs);
    this.pickDate = new Date(base.getFullYear(), base.getMonth(), base.getDate());
    this.sheetMode = 'repeatEnd';
    this.sheetShow = true;
  }

  private reminderLabel(m: number): string {
    if (m === 0) {
      return '不提醒';
    }
    if (m < 60) {
      return `提前${m}分钟`;
    }
    if (m < 1440) {
      return `提前${m / 60}小时`;
    }
    return `提前${m / 1440}天`;
  }

  /** 打开时间选择弹层：日期 + 时间一次选完 */
  private openPicker(isEnd: boolean): void {
    this.pickerIsEnd = isEnd;
    const base = new Date(isEnd ? this.endMs : this.startMs);
    this.pickDate = new Date(base.getFullYear(), base.getMonth(), base.getDate());
    this.pickHour = base.getHours();
    this.pickMin = base.getMinutes();
    this.sheetMode = 'picker';
    this.sheetShow = true;
  }

  private applyPicker(): void {
    const d = this.pickDate;
    const picked: number = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
      this.pickHour, this.pickMin).getTime();
    if (this.pickerIsEnd) {
      // 全天日程的结束存为"当天 23:59:59.999"（排他日期前 1 毫秒）
      this.endMs = this.allDay ? picked + 86399999 : picked;
    } else {
      // 设定开始时间后，结束时间自动跟随 = 开始 + 1 小时
      this.startMs = picked;
      this.endMs = this.allDay ? picked + 86399999 : picked + 3600000;
    }
  }

  private toggleAllDay(): void {
    this.allDay = !this.allDay;
    if (this.allDay) {
      const s = new Date(this.startMs);
      const dayStart: number = new Date(s.getFullYear(), s.getMonth(), s.getDate()).getTime();
      this.startMs = dayStart;
      this.endMs = dayStart + 86399999;
    } else {
      const s = new Date(this.startMs);
      this.startMs = s.getTime() + 9 * 3600000;
      this.endMs = this.startMs + 3600000;
    }
  }

  /**
   * ⭐ 统一的表单错误提示（**唯一的错误出口**）。
   *
   * 为什么需要专门做这件事：
   *   校验提示原本只写进 `statusMsg`，而它渲染在表单最底部（"删除日程"按钮上方）。
   *   用户在顶部点"保存"时，那行红字远在屏幕之外 —— 看起来就是"点了没反应"。
   *
   * 三件事一起做，保证用户一定看得见、也知道该改哪儿：
   *   ① **Toast**：系统级浮在屏幕中上部，不受滚动位置影响，必定可见；
   *   ② **字段标红**：给对应输入框加红框 + 紧贴字段的红字说明；
   *   ③ **滚回出错字段并聚焦**：把视野直接带到问题所在（标题 → 打光标；时间 → 滚到时间卡片）。
   *
   * @param msg   给用户看的话术（要具体，说清"该做什么"，不要只说"错误"）
   * @param field 'title' | 'time' | ''（'' 表示没有具体字段，只弹 Toast）
   */
  private showFormError(msg: string, field: string): void {
    this.statusMsg = msg;
    this.errorField = field;
    // ① Toast：不走布局，无论滚到哪儿都能看到
    try {
      this.getUIContext().getPromptAction().showToast({
        message: msg,
        duration: 2500,
        bottom: '70%'   // 抬到屏幕偏上方，避免被键盘/底部按钮遮挡
      });
    } catch (err) {
      // Toast 失败也不影响其它两种提示
    }
    // ③ 滚回出错位置：延时一帧，等状态刷新（标红后高度可能变化）后再滚
    setTimeout(() => {
      try {
        if (field === 'title') {
          this.formScroller.scrollEdge(Edge.Top);
          try {
            this.getUIContext().getFocusController().requestFocus('titleInput');
          } catch (e2) {
            // 聚焦失败（例如输入法正在切换）不阻塞流程
          }
        } else if (field === 'time') {
          // 时间卡片在表单上部，滚到顶基本就能看到；再留一点余量
          this.formScroller.scrollEdge(Edge.Top);
        } else {
          this.formScroller.scrollEdge(Edge.Top);
        }
      } catch (err2) {
        const e = err2 as BusinessError;
        LogUtil.write(`错误提示定位失败: ${e.message}`);
      }
    }, 60);
  }

  private validate(): boolean {
    if (this.title.trim() === '') {
      this.showFormError('请先填写日程标题', 'title');
      return false;
    }
    if (this.endMs < this.startMs) {
      this.showFormError('结束时间不能早于开始时间', 'time');
      return false;
    }
    // 通过校验：清掉上一轮的错误标记
    this.errorField = '';
    return true;
  }

  /**
   * 当前编辑的是不是一个"重复系列中的某一次发生"？
   * - 主事件行（rrule 非空）：用户点开的可能就是第一次发生或其展开实例 → 需要询问范围
   * - 覆盖实例行（recurring && rrule==''）：明确就是被单独改写过的那一次 → 需要询问范围
   * 非重复的普通日程返回 false，直接按原逻辑保存/删除。
   */
  private isSeriesOccurrence(): boolean {
    const src: LocalEvent | null = this.original ?? this.event;
    if (src === null) {
      return false;
    }
    return src.recurring || src.rrule !== '';
  }

  /** 取本系列的主事件行（带 RRULE 的那行；找不到则退回当前行）。
   *  ⚠️ 必须按**原始** calKey/uid 查找（doSave 会改写 this.event 的 calKey）。 */
  private async loadMaster(context: common.Context): Promise<LocalEvent | null> {
    const src: LocalEvent | null = this.original ?? this.event;
    if (src === null) {
      return null;
    }
    const rows: LocalEvent[] = await EventDb.queryByUid(context, src.calKey, src.uid);
    for (const r of rows) {
      if (r.rrule !== '') {
        return r;
      }
    }
    return src;
  }

  /** 该次发生之前一次发生与之后一次发生的边界（用于 EXDATE / UNTIL / 拆分）。
   *  ⭐ 会用展开结果**校正 occStartMs**：调用方传来的时刻可能带秒/毫秒偏差
   *  （列表里点开的那次发生时间是精确的，但主事件运行到卡片等路径可能有偏差），
   *  必须吸附到"真实存在的那一次"，否则 EXDATE 写出的时刻匹配不上任何发生 →
   *  表现为"选了仅这一次，却把所有次都改了"。 */
  private async seriesBoundaries(context: common.Context): Promise<SeriesBounds> {
    const b = new SeriesBounds();
    let occ: number = this.occStartMs;
    b.thisOcc = occ;
    const master: LocalEvent | null = await this.loadMaster(context);
    if (master === null || master.rrule === '') {
      b.beforeThis = occ - 1000;
      b.nextOcc = 0;
      return b;
    }
    const exNums: number[] = [];
    if (master.exdate !== '') {
      for (const raw of master.exdate.split(';')) {
        const t = IcsUtil.parseTime(raw, !raw.includes('T'));
        if (t !== null) {
          exNums.push(t.time);
        }
      }
    }
    // 展开窗口：主事件开始 ~ "该次"之后一年（覆盖主事件的首次发生）
    const winEnd: number = Math.max(occ, master.startTime) + 366 * 86400000;
    const occs: number[] = RruleUtil.expand(master.rrule, master.startTime,
      master.startTime, winEnd, exNums, 3000);
    // ⭐ 吸附：找与 occ 最接近的那一次真实发生（容差 12 小时，足以跨时区/跨日误差）
    let snapped: number = 0;
    let bestDiff: number = -1;
    for (const o of occs) {
      const d: number = Math.abs(o - occ);
      if (bestDiff < 0 || d < bestDiff) {
        bestDiff = d;
        snapped = o;
      }
    }
    if (snapped > 0 && bestDiff <= 12 * 3600000) {
      occ = snapped;
      b.thisOcc = snapped;
      this.occStartMs = snapped; // 回写，保证后续 EXDATE / 覆盖行用同一时刻
    } else if (!this.occProvided && master.startTime > 0) {
      // 没有可信的"点选时刻"时，退回主事件的首次发生（至少是真实存在的一次）
      occ = master.startTime;
      b.thisOcc = occ;
      this.occStartMs = occ;
    }
    let prev: number = 0;
    let next: number = 0;
    for (const o of occs) {
      if (o < occ) {
        prev = o;
      } else if (o > occ) {
        next = o;
        break;
      }
    }
    b.beforeThis = prev > 0 ? (prev + occ) / 2 : (occ - 1000);
    b.nextOcc = next;
    return b;
  }

  /**
   * ⭐ 按用户选择的"重复日程编辑范围"落库：
   * - all    ：原逻辑，直接改这一行（若是覆盖实例则改覆盖行），整系列由 pushSeries 重建
   * - one    ：单次改写 ——
   *              · 原行是覆盖实例 → 直接更新它
   *              · 原行是主事件（用户点开了系列）→ 为主事件加 EXDATE 排除该次，另插一条覆盖行
   * - future ：此次及以后 —— 先把主事件的 RRULE 截断到"此次之前"（加 UNTIL），
   *              再把"此次及以后"的内容作为**新的独立系列**（新 uid）插入。
   */
  private async applySeriesEdit(context: common.Context, e: LocalEvent, isNew: boolean,
    scope: string): Promise<void> {
    const target: LocalEvent = e;
    // ⚠️ 用**原始快照**判据：doSave 已把 e（= this.event）的 calKey/href/startTime 改成新值，
    //    直接用 this.event 会把"改后的日期/日历本"当成原系列，导致 EXDATE / UNTIL 算错。
    const cur: LocalEvent | null = this.original;
    // 用户点开的是"某一次发生"（occProvided=true）时，list/周视图里的行 id 是**主事件 id**，
    // 所以"改全部"也必须给用户明确的确认——但语义上就是改整条系列：
    //   · 点开的是主事件行本身（occProvided=false）→ 直接改这一行就是改整个系列，无需特殊处理
    //   · 点开的是某一次发生 且选了"全部" → 把改动写到主事件行上（整系列平移/改名）
    if (isNew || cur === null || !this.isSeriesOccurrence()) {
      if (isNew) {
        await EventDb.insertLocal(context, target);
      } else {
        await EventDb.updateLocal(context, target);
      }
      return;
    }
    const bounds: SeriesBounds = await this.seriesBoundaries(context);
    if (scope === 'all') {
      // 全部：改到**主事件行**上（整系列一起改）。
      // ⚠️ 不能直接 updateLocal(target)：target 是"用户点开的那一行"，
      //    当用户点的是某次发生、而该行其实是主事件行时没问题；
      //    但若这一行是覆盖实例（rrule=''），把整系列的属性写进覆盖行只会改到那一次。
      const masterForAll: LocalEvent | null = await this.loadMaster(context);
      if (masterForAll !== null && masterForAll.rrule !== '') {
        // 把编辑内容写到主事件行（保留主事件的 uid / rrule / exdate）
        masterForAll.title = target.title;
        masterForAll.description = target.description;
        masterForAll.location = target.location;
        masterForAll.startTime = target.startTime;
        masterForAll.endTime = target.endTime;
        masterForAll.isAllDay = target.isAllDay;
        masterForAll.reminders = target.reminders;
        masterForAll.reminder = target.reminder;
        await EventDb.updateLocal(context, masterForAll);
        return;
      }
      await EventDb.updateLocal(context, target);
      return;
    }
    if (scope === 'one') {
      if (cur.rrule === '' && cur.recurrenceId > 0) {
        // 已经是覆盖实例 → 直接改它（保留 recurrenceId）
        target.recurrenceId = cur.recurrenceId;
        await EventDb.updateLocal(context, target);
        return;
      }
      // 主事件上的"仅此次"：加 EXDATE 排除该次 + 插入覆盖行
      const master: LocalEvent | null = await this.loadMaster(context);
      if (master === null) {
        return;
      }
      // ⚠️ **顺序很重要**：先把主事件行还原为原值（用户在编辑页改的标题/时间只属于"这一次"，
      //    不能污染主事件），**再**写 EXDATE。反过来会被还原操作覆盖掉 EXDATE
      //    （快照里存的是旧的 exdate），导致排除失效 → 原时间残留一条、看起来"没删掉/改错了"。
      if (cur.rrule !== '' && master.id === cur.id) {
        await EventDb.restoreRowById(context, master.id, cur);
      }
      const exList: string[] = cur.exdate === '' ? [] : cur.exdate.split(';');
      const occIcs: string = IcsUtil.fmtIcsTime(bounds.thisOcc, master.isAllDay);
      if (!exList.includes(occIcs)) {
        exList.push(occIcs);
      }
      await EventDb.setExdate(context, master.id, exList.join(';'));
      // 覆盖行：uid 同主事件、DTSTART=改到的新时间、RECURRENCE-ID=原始发生时刻
      const ov = new LocalEvent();
      ov.uid = master.uid;
      ov.calKey = master.calKey;
      ov.href = master.href;
      ov.remotePath = master.remotePath;
      ov.title = target.title;
      ov.description = target.description;
      ov.location = target.location;
      ov.startTime = target.startTime;
      ov.endTime = target.endTime;
      ov.isAllDay = target.isAllDay;
      ov.recurring = true;
      ov.rrule = '';
      ov.recurrenceId = bounds.thisOcc;
      ov.reminders = target.reminders;
      ov.reminder = target.reminder;
      await EventDb.insertLocal(context, ov);
      return;
    }
    // scope === 'future'
    const master: LocalEvent | null = await this.loadMaster(context);
    if (master === null) {
      return;
    }
    // 主事件本身被改期 → "此次及以后"里包含主事件（第一次发生）本身，
    // 需要让新系列从"改到的时间"开始（否则原 DTSTART 会被原系列继续展开）。
    // ⚠️ 判据要用**原始主事件的开始时间**（cur.startTime 是"载入时的行时间"，
    //    对主事件行而言就是它的第一次发生时刻）。
    const startedAtThis: boolean =
      (cur.rrule !== '' && Math.abs(cur.startTime - bounds.thisOcc) < 1000);
    // 1) 先把"此次及以后"的覆盖实例行搬到新 uid（主事件行 recurrenceId=0，不受影响）
    const newUid: string = `syncal-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const newPath: string = encodeURIComponent(newUid) + '.ics';
    await EventDb.reassignOverridesFrom(context, master.calKey, master.uid,
      newUid, newPath, bounds.thisOcc);
    // 2) 创建新系列主事件（本次编辑内容）
    const newMaster = new LocalEvent();
    newMaster.uid = newUid;
    newMaster.calKey = master.calKey;
    newMaster.href = master.href;
    newMaster.remotePath = newPath;
    newMaster.title = target.title;
    newMaster.description = target.description;
    newMaster.location = target.location;
    newMaster.startTime = target.startTime;
    newMaster.endTime = target.endTime;
    newMaster.isAllDay = target.isAllDay;
    newMaster.recurring = true;
    // 新的重复规则：优先用界面上设置的（含"重复到某天 / 共几次"），
    // 否则沿用原系列的重复节奏，保持"此次及以后"不变
    newMaster.rrule = target.rrule !== '' ? target.rrule : master.rrule;
    newMaster.reminders = target.reminders;
    newMaster.reminder = target.reminder;
    await EventDb.insertLocal(context, newMaster);
    // 3) 原主事件系列截断到"此次之前"。
    //    若主事件本身就代表"此次"（第一次发生且被改期）→ 原系列整个让位给新系列，
    //    直接标记原主事件删除（pushSeries 会 DELETE 原资源），避免旧时间残留成幽灵日程。
    if (startedAtThis) {
      await EventDb.markDeleted(context, master.id);
    } else {
      // ⚠️ 顺序：先还原主事件行（本次编辑只属于"此次及以后"的新系列，
      //    不能留在原主事件上），**再**截断 RRULE；反过来会被还原覆盖掉截断结果。
      if (cur.rrule !== '' && master.id === cur.id) {
        await EventDb.restoreRowById(context, master.id, cur);
      }
      const truncated: string = IcsUtil.rruleWithUntil(master.rrule, bounds.beforeThis);
      await EventDb.setRruleForUid(context, master.calKey, master.uid, truncated);
    }
  }

  private async save(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    // 便于诊断：记录这次保存走了哪条分支（标题已脱敏）
    LogUtil.write(`保存判定：isExisting=${this.isExisting} recurring=${this.original !== null ? this.original.recurring : '?'} rrule=${this.original !== null && this.original.rrule !== '' ? '有' : '无'} 选本=${this.books.length} chosenKey=${this.chosenKey}`);
    // ⭐ 重复日程：**先让用户选择范围（仅这一次 / 此次及以后 / 全部）**，再校验与落库。
    //    必须放在最前面 —— 与"删除"路径保持一致。若把校验/日历本检查放在前面，
    //    任一条件不满足就会提前 return，用户看到的只是表单底部一行小字，
    //    永远等不到范围选择弹层（表现为"编辑重复日程没有那三个选项"）。
    if (this.isSeriesOccurrence()) {
      this.pendingDelete = false;
      this.sheetMode = 'scope';
      this.sheetShow = true;
      LogUtil.write('保存判定：重复系列 → 弹出范围选择');
      return;
    }
    if (!this.validate()) {
      LogUtil.write(`保存判定：校验未通过（${this.statusMsg}）`);
      return;
    }
    // 日程必须落在某个 CalDAV 日历本上（"本机"不再是可选目标）——没选到就直接拦下
    const book = this.chosenBook();
    if (book === null) {
      // 这也是"必填项缺失"，同样要弹 Toast + 滚到对应字段，不能只写底部状态行
      this.showFormError(this.books.length === 0
        ? '还没有可写入的 CalDAV 日历本，请先到「更多 → 账号管理」添加账号'
        : '请选择要同步到的 CalDAV 日历本', 'book');
      LogUtil.write(`保存判定：日历本解析失败（选本=${this.books.length} chosenKey=${this.chosenKey}）`);
      return;
    }
    await this.doSave('all');
  }

  /** 真正执行保存（scope 已被用户确认） */
  private async doSave(scope: string): Promise<void> {
    if (this.isSaving) {
      return;
    }
    // ⭐ 范围确认后回到这里再校验一次：范围弹层打开时并未跳过校验，
    //    只是把它推迟到"选完范围"之后（失败时弹层已关闭，错误用 showFormError 强提示）。
    if (!this.validate()) {
      return;
    }
    const book = this.chosenBook();
    if (book === null) {
      this.showFormError(this.books.length === 0
        ? '还没有可写入的 CalDAV 日历本，请先到「更多 → 账号管理」添加账号'
        : '请选择要同步到的 CalDAV 日历本', 'book');
      return;
    }
    this.isSaving = true;
    this.statusMsg = '';
    this.errorField = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const e = this.event ?? new LocalEvent();
      const isNew: boolean = this.event === null;
      e.title = this.title.trim();
      e.location = this.location.trim();
      e.description = this.description.trim();
      e.startTime = this.startMs;
      e.endTime = this.allDay ? this.startMs + 86399999 : this.endMs;
      e.isAllDay = this.allDay;
      // 一律写入所选 CalDAV 日历本（新建/编辑/从「本机」迁过来都一样）
      e.calKey = book.calKey;
      e.href = book.href;
      // 重复规则与提醒（含"重复到某天 / 共几次"的结束条件）
      e.rrule = this.effectiveRrule();
      e.recurring = e.rrule !== '';
      e.reminders = EventDb.normalizeReminders(this.reminderList);
      e.reminder = e.reminders.length > 0 ? e.reminders[0] : 0;
      if (isNew) {
        e.uid = `syncal-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
        e.remotePath = encodeURIComponent(e.uid) + '.ics';
        await EventDb.insertLocal(context, e);
      } else {
        // 重复系列的"仅此次/此次及以后"需要特殊落库（EXDATE / UNTIL / 拆分）
        await this.applySeriesEdit(context, e, false, scope);
      }
      // 立即推送（尽力而为，失败不打断，下次同步会再推）
      if (e.href !== '') {
        const accounts: DavAccount[] = await AccountStore.loadAll(context);
        const eNorm: string = DavClient.normalizeHref(e.href);
        const acc = accounts.find((a: DavAccount): boolean =>
          a.calendarHrefs.some((h: string): boolean => DavClient.normalizeHref(h) === eNorm));
        if (acc !== undefined) {
          const auth: string = DavClient.authHeader(acc.username, acc.password);
          await SyncEngine.pushDirtyForAccount(context, acc, auth);
        }
      } else {
        await SyncEngine.settleLocalEvents(context);
      }
      // 日志仅记录 uid 与提醒/重复设置，不落盘日程标题（避免隐私内容进入可备份的 sync.log）
      LogUtil.write(`本地保存日程（标题已脱敏）uid=${e.uid} 范围=${scope} 提醒=${e.reminders.join('/')}分钟 重复=${e.rrule === '' ? '否' : e.rrule}`);
      // 设置了提醒 → 此刻才申请通知权限（用户刚主动使用了依赖通知的功能，
      // 符合《审核指南》7.17"在用户主动点击对应功能时申请"，不随 App 启动自动弹窗）
      if (e.reminders.length > 0) {
        await this.ensureNotifyPermission();
      }
      // 立即刷新提醒（不等下一轮同步），保证刚保存的提醒马上生效
      try {
        await ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (err) {
        // 刷新失败不影响保存
      }
      this.getUIContext().getPromptAction().showToast({ message: '日程已保存' });
      router.back();
    } catch (err) {
      const ex = err as BusinessError;
      LogUtil.write(`保存日程流程失败（数据已存本地待重试）：${ex.message}`);
      this.statusMsg = `保存失败：${ex.message}（已保存到本地，稍后同步会重试）`;
      // ⭐ 这里紧接着会 router.back()，底部状态行根本来不及被看到 → 必须用 Toast
      try {
        this.getUIContext().getPromptAction().showToast({
          message: '已保存到本地，同步到服务器失败，稍后会自动重试',
          duration: 3000,
          bottom: '70%'
        });
      } catch (e2) {
        // Toast 失败不影响返回
      }
      // 数据仍在本地且带 dirty 标记，不会丢
      router.back();
    }
    this.isSaving = false;
  }

  /**
   * 确认通知权限已开启 —— 仅"用户保存了带提醒的日程"这条路径会调用。
   * 日程提醒依赖系统通知，用户刚主动设置了提醒，此时申请权限与其使用目的完全一致。
   * ⚠️ 严禁在 App 启动 / 首次打开时调用（《审核指南》7.17：不得提前弹窗申请权限）。
   */
  private async ensureNotifyPermission(): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        return;
      }
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
    } catch (err) {
      // 用户拒绝或未弹窗：日程照常保存，只是提醒可能不弹出（设置页可再开启）
    }
  }

  /**
   * 删除前二次确认。
   * 删除日程不可撤销，且会同时从本地库与服务器（DAV）移除，故破坏性操作前必须显式确认，
   * 避免"删除日程"按钮点击即删的误触。
   */
  private askRemoveEvent(): void {
    if (this.event === null || this.isSaving) {
      return;
    }
    // ⭐ 重复日程：先让用户选择"删这一次 / 此次及以后 / 全部"
    if (this.isSeriesOccurrence()) {
      this.pendingDelete = true;
      this.sheetMode = 'scope';
      this.sheetShow = true;
      return;
    }
    const label: string = this.title.trim() === '' ? '该日程' : `「${this.title.trim()}」`;
    this.getUIContext().showAlertDialog({
      title: '删除日程',
      message: `确定删除${label}吗？\n\n删除后该日程将从本地与服务器日历中一并移除，且不可撤销。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.removeEvent('all');
        }
      }
    });
  }

  /**
   * ⭐ 按范围删除：one = 仅此次（EXDATE 排除该次发生）/ future = 此次及以后（截断 RRULE）/
   * all = 删除全部（DELETE 整个系列资源）。
   */
  private async removeEvent(scope: string): Promise<void> {
    if (this.event === null || this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const cur: LocalEvent = this.original ?? this.event;
      const isSeries: boolean = this.isSeriesOccurrence();
      if (!isSeries || scope === 'all') {
        // 普通日程 / 删除全部：整系列所有行标记删除（由 pushSeries 发出 DELETE 资源并本地清库）
        if (isSeries) {
          await EventDb.markDeletedByUid(context, cur.calKey, cur.uid);
        } else {
          await EventDb.markDeleted(context, cur.id);
        }
      } else if (scope === 'one') {
        // 仅此次：
        // ⭐ 吸附校准目标发生时刻，确保生成的 EXDATE 绝对对齐
        const bounds: SeriesBounds = await this.seriesBoundaries(context);
        const master: LocalEvent | null = await this.loadMaster(context);
        if (master !== null) {
          const exList: string[] = master.exdate === '' ? [] : master.exdate.split(';');
          const occIcs: string = IcsUtil.fmtIcsTime(bounds.thisOcc, master.isAllDay);
          if (!exList.includes(occIcs)) {
            exList.push(occIcs);
          }
          await EventDb.setExdate(context, master.id, exList.join(';'));
          // 若该次此前被单独改写过（存在覆盖行），只清理对应发生时刻的那一行
          const rows: LocalEvent[] = await EventDb.queryByUid(context, cur.calKey, cur.uid);
          for (const r of rows) {
            if (r.rrule === '' && r.recurrenceId > 0 && Math.abs(r.recurrenceId - bounds.thisOcc) < 12 * 3600000) {
              await EventDb.markDeleted(context, r.id);
            }
          }
        } else if (cur.rrule === '' && cur.recurrenceId > 0) {
          await EventDb.markDeleted(context, cur.id);
        }
      } else {
        // 此次及以后：主事件 RRULE 截断到"此次之前"；该次及以后的本地行物理删除
        const master: LocalEvent | null = await this.loadMaster(context);
        if (master !== null) {
          const bounds: SeriesBounds = await this.seriesBoundaries(context);
          const truncated: string = IcsUtil.rruleWithUntil(master.rrule, bounds.beforeThis);
          await EventDb.setRruleForUid(context, master.calKey, master.uid, truncated);
          await EventDb.purgeByUidFrom(context, master.calKey, master.uid, bounds.thisOcc);
        }
      }
      if (cur.href !== '') {
        const accounts: DavAccount[] = await AccountStore.loadAll(context);
        const curNorm: string = DavClient.normalizeHref(cur.href);
        const acc = accounts.find((a: DavAccount): boolean =>
          a.calendarHrefs.some((h: string): boolean => DavClient.normalizeHref(h) === curNorm));
        if (acc !== undefined) {
          const auth: string = DavClient.authHeader(acc.username, acc.password);
          await SyncEngine.pushDirtyForAccount(context, acc, auth);
        }
      } else {
        await SyncEngine.settleLocalEvents(context);
      }
      // 日志不落盘日程标题，仅以 uid 追踪
      LogUtil.write(`本地删除日程（标题已脱敏）uid=${cur.uid} 范围=${scope}`);
      // 立即刷新提醒（取消已发布但日程已删的提醒）
      try {
        await ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (err) {
        // 刷新失败不影响删除
      }
      // 联动清理系统日历中的镜像事件
      try {
        if (await AppSettings.getMirrorEnabled(context) && await SystemCalendarMirror.hasPermission()) {
          SystemCalendarMirror.syncNow(context).catch((err: Error) => {
            LogUtil.write(`编辑页删除后同步清理系统日历失败: ${err.message}`);
          });
        }
      } catch (err) {
        // 忽略
      }
      // 联动刷新桌面服务卡片
      try {
        CardDataService.pushToAllForms(context);
      } catch (err) {
        // 忽略
      }
      this.getUIContext().getPromptAction().showToast({ message: '日程已删除' });
      router.back();
    } catch (err) {
      const ex = err as BusinessError;
      this.statusMsg = `删除失败：${ex.message}`;
      try {
        this.getUIContext().getPromptAction().showToast({
          message: `删除失败：${ex.message}`,
          duration: 3000
        });
      } catch (e2) {
        // Toast 失败不影响
      }
    }
    this.isSaving = false;
  }

  build() {
    Column({ space: 14 }) {
      // 顶部（与内容区左右对齐，避免贴边误触）
      Row({ space: 6 }) {
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            router.back();
          })
        Blank()
        Text(this.isExisting ? '编辑日程' : '新建日程')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('保存')
          .fontSize(16)
          .fontColor(this.isSaving ? $r('app.color.text_hint') : $r('app.color.brand'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Scroll(this.formScroller) {
        Column({ space: 14 }) {
          // 标题（必填）
          // ⭐ 校验失败时：输入框描红 + 紧贴下方一条红字说明。
          //    只在 errorField === 'title' 时出现，用户开始输入即自动清除。
          TextInput({ text: this.title, placeholder: '标题（必填）' })
            .height(46)
            .fontSize(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            // 显式指定文字/提示/光标颜色：TextInput 默认取系统主题色，
            // 深色模式下会变成浅色文字 → 与卡片底色撞色而"看不清"
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            // 标红：用边框而不是背景，深色/浅色主题下都醒目且不难看
            .border({
              width: this.errorField === 'title' ? 1.5 : 0,
              color: $r('app.color.error')
            })
            .onChange((v: string) => {
              this.title = v;
              // 用户开始填写就把红框撤掉，避免"改了还一直红着"
              if (v.trim() !== '' && this.errorField === 'title') {
                this.errorField = '';
                this.statusMsg = '';
              }
            })
            .id('titleInput')

          if (this.errorField === 'title') {
            Text('请填写标题后再保存')
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .width('100%')
              .padding({ left: 4 })
          }

          // 全天
          Row() {
            Text('全天')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.allDay })
              .selectedColor($r('app.color.brand'))
              .onChange(() => {
                this.toggleAllDay();
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 时间卡片（单击任一行：底部弹层中日期+时间一次选完）
          Column({ space: 10 }) {
            this.timeRow('开始', true)
            Divider().color($r('app.color.shadow_color'))
            this.timeRow('结束', false)
          }
          .width('100%')
          .padding(6)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          // 时间顺序错误时整卡描红，用户一眼能看到问题在这个卡片里
          .border({
            width: this.errorField === 'time' ? 1.5 : 0,
            color: $r('app.color.error')
          })

          if (this.errorField === 'time') {
            Text('结束时间不能早于开始时间')
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .width('100%')
              .padding({ left: 4 })
          }

          // 重复
          Column({ space: 8 }) {
            Text('重复')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              this.repeatChip('none', '不重复')
              this.repeatChip('daily', '每天')
              this.repeatChip('workday', '工作日')
              this.repeatChip('weekly', '每周')
              this.repeatChip('monthly', '每月')
              this.repeatChip('yearly', '每年')
              if (this.repeatMode === 'custom') {
                // 服务器来的复杂规则（INTERVAL/COUNT 等）标记为自定义，保存时原样保留
                this.repeatChip('custom', '自定义')
              }
            }
            .width('100%')
            // ⭐ 结束条件：永不结束 / 重复到某天 / 共重复几次
            //    （新建与编辑都可用；编辑时会回显服务器上已有的 COUNT / UNTIL）
            if (this.repeatMode !== 'none' && this.repeatMode !== 'custom') {
              Divider().color($r('app.color.shadow_color'))
              Text('结束条件')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                this.repeatEndChip('never', '永不结束')
                this.repeatEndChip('until', '重复到某天')
                this.repeatEndChip('count', '共几次')
              }
              .width('100%')
              if (this.repeatEnd === 'until') {
                Row({ space: 8 }) {
                  Text('截止日期')
                    .fontSize(14)
                    .fontColor($r('app.color.text_secondary'))
                  Text(this.repeatUntil > 0 ? this.fmtDate(this.repeatUntil) : '请选择')
                    .fontSize(15)
                    .fontColor($r('app.color.brand'))
                    .layoutWeight(1)
                  Text('›')
                    .fontSize(16)
                    .fontColor($r('app.color.text_hint'))
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 10, bottom: 10 })
                .onClick(() => {
                  this.openRepeatUntilPicker();
                })
              }
              if (this.repeatEnd === 'count') {
                Row({ space: 8 }) {
                  Text('重复次数')
                    .fontSize(14)
                    .fontColor($r('app.color.text_secondary'))
                  Blank()
                  Text('−')
                    .fontSize(20)
                    .fontColor($r('app.color.brand'))
                    .padding({ left: 14, right: 14 })
                    .onClick(() => {
                      this.repeatCount = Math.max(1, Math.round(this.repeatCount) - 1);
                    })
                  Text(String(Math.round(this.repeatCount)))
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                    .width(44)
                    .textAlign(TextAlign.Center)
                  Text('＋')
                    .fontSize(18)
                    .fontColor($r('app.color.brand'))
                    .padding({ left: 14, right: 14 })
                    .onClick(() => {
                      this.repeatCount = Math.min(999, Math.round(this.repeatCount) + 1);
                    })
                  Text('次')
                    .fontSize(14)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 提醒
          Column({ space: 8 }) {
            Text('提醒（可多选）')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              this.reminderChip(0)
              this.reminderChip(5)
              this.reminderChip(10)
              this.reminderChip(15)
              this.reminderChip(30)
              this.reminderChip(60)
              this.reminderChip(1440)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 日历本选择：两列等宽对齐（每项固定 48% 宽 + 两端对齐），只列 CalDAV 可写日历本
          Column({ space: 8 }) {
            Row({ space: 6 }) {
              Text('日历本')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text('同步到 CalDAV')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')

            if (this.books.length === 0) {
              // 没有可写入的 CalDAV 日历本：说明原因 + 给替代方案（本机日程请用系统「日历」）
              Text('没有可写入的 CalDAV 日历本。请先到「更多 → 账号管理」添加账号；'
                + '这条日程需要同步到服务器。若只想记在本机，请使用系统「日历」应用。')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .width('100%')
            } else {
              if (this.chosenBook() === null) {
                // 未选中任何日历本（如历史遗留的"本机"日程）→ 就地提示，别让用户找不到原因
                Text(this.chosenKey === LOCAL_CAL_KEY
                  ? '这条日程原先只存在「本机」（不同步）。请选一个日历本，保存后即会同步到服务器。'
                  : '请选择一个日历本，日程会同步到服务器。')
                  .fontSize(12)
                  .fontColor($r('app.color.brand_text'))
                  .width('100%')
              }
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(this.books, (b: BookChoice) => {
                  Row({ space: 6 }) {
                    Circle().width(8).height(8).fill(b.color)
                    Text(b.name)
                      .fontSize(12)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor(this.chosenKey === b.calKey
                        ? $r('app.color.button_text') : $r('app.color.text_primary'))
                  }
                  .width('48%')
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .borderRadius(14)
                  .margin({ bottom: 8 })
                  .backgroundColor(this.chosenKey === b.calKey ? b.color : $r('app.color.chip_off_bg'))
                  .onClick(() => {
                    this.chosenKey = b.calKey;
                    // 选了日历本就把红框撤掉
                    if (this.errorField === 'book') {
                      this.errorField = '';
                      this.statusMsg = '';
                    }
                  })
                }, (b: BookChoice) => b.calKey)
              }
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          // 日历本未选且用户点了保存 → 描红，提示"必填"
          .border({
            width: this.errorField === 'book' ? 1.5 : 0,
            color: $r('app.color.error')
          })
          .backgroundColor($r('app.color.card_bg'))

          // 地点（输入几个字 → 系统地图服务补全候选）
          // ⭐ 候选列表**不在布局流里**：它通过 bindPopup 挂在输入框上、向**上方**弹出。
          //    这样候选的出现/消失完全不改变输入框位置 —— 从根上消除"输入框上下跳"。
          Row({ space: 8 }) {
            TextInput({ text: this.location, placeholder: '地点（可选，输入几个字可搜索）' })
              .height(44)
              .layoutWeight(1)
              .fontSize(14)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_hint'))
              .caretColor($r('app.color.brand'))
              .onChange((v: string) => {
                // ⭐ 程序改写 text（选中候选后回写地址）也会触发 onChange。
                //    精确比对最后一次程序写入值：命中就不再发起搜索，
                //    否则会"选完 → 候选框消失 → 又冒出来一次"。
                if (v === this.lastAppliedText) {
                  this.lastAppliedText = '';
                  this.location = v;
                  return;
                }
                this.lastAppliedText = '';
                this.location = v;
                // 用户重新输入时解除"已选中"状态，恢复自动补全
                this.placePicked = false;
                this.scheduleSuggest(v);
              })
              .onSubmit(() => {
                // 回车：立刻搜一次（不等防抖）
                this.cancelSuggestTimer();
                this.runSuggest(this.location, true);
              })
              .onFocus(() => {
                // 键盘避让交给系统（RESIZE 已保证光标可见）；
                // 候选是浮层，不需要再滚动页面去给它腾位置
                this.placeFocused = true;
              })
              .onBlur(() => {
                // 失焦（点"地图"按钮、点别处、收起键盘）→ 收起候选浮层
                this.placeFocused = false;
                this.closePlacePopup();
              })
              .bindPopup($$this.placeOpen, {
                builder: (): void => {
                  this.placePopup()
                },
                placement: Placement.Top,
                popupColor: $r('app.color.card_bg'),
                enableArrow: false,
                showInSubWindow: false,
                focusable: false,
                autoCancel: true,
                radius: 12,
                onStateChange: (e: PopupStateChangeParam) => {
                  // 用户点浮层外部/floating 自动关闭时，同步状态，避免下次不弹
                  if (!e.isVisible && this.placeOpen) {
                    this.placeOpen = false;
                  }
                }
              })
              .id('placeAnchor')
            // 在地图上选点（系统地图界面，可选可搜可周边）
            Text('地图')
              .fontSize(13)
              .fontColor($r('app.color.brand_text'))
              .padding({ left: 12, right: 12 })
              .height(44)
              .textAlign(TextAlign.Center)
              .borderRadius(12)
              .backgroundColor($r('app.color.card_bg'))
              .onClick(() => {
                this.pickOnMap();
              })
          }
          .width('100%')
          .id('placeRow')

          // 描述
          TextArea({ text: this.description, placeholder: '备注（可选）' })
            .height(90)
            .fontSize(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            .onChange((v: string) => {
              this.description = v;
            })

          // 状态行：只用于"保存失败/账号未配置"这类**系统级**信息，且必须有 Toast 同时提示。
          // ⚠️ 校验类错误不走这里 —— 它们已经在对应字段旁就地显示，
          //    再在这里重复一遍只会让用户以为有两处不同的问题。
          if (this.statusMsg !== '' && this.errorField === '') {
            Text(this.statusMsg)
              .fontSize(13)
              .fontColor($r('app.color.error'))
              .width('100%')
          }

          // 删除
          if (this.isExisting) {
            Button('删除日程')
              .fontSize(15)
              .fontColor($r('app.color.error'))
              .backgroundColor($r('app.color.error_bg'))
              .width('100%')
              .height(44)
              .borderRadius(12)
              .enabled(!this.isSaving)
              .onClick(() => {
                // 二次确认后再执行删除
                this.askRemoveEvent();
              })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 30 })
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 12 })
    .backgroundColor($r('app.color.page_bg'))
    // 沉浸式：背景延伸到状态栏/导航条区域（只扩绘制、不移动子组件）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // ⚠️ 整个页面**只允许一个 bindSheet**：挂两个时后者会覆盖前者，
    //    表现为"时间选择框白框一闪而过"（范围弹层顶掉了它）。
    //    这里用 sheetMode 在同一个弹层里切换内容。
    .bindSheet($$this.sheetShow, this.bottomSheet(), {
      height: this.sheetMode === 'scope' ? 320 : (this.sheetMode === 'repeatEnd' ? 340 : 380),
      showClose: false,
      dragBar: true,
      backgroundColor: $r('app.color.card_bg')
    })
  }

  /** ⭐ 唯一的底部弹层：按 sheetMode 切换显示"时间选择"/"重复范围选择"/"重复截止日期" */
  @Builder
  bottomSheet() {
    if (this.sheetMode === 'scope') {
      this.scopeSheet()
    } else if (this.sheetMode === 'repeatEnd') {
      this.repeatEndSheet()
    } else {
      this.dateTimePickerSheet()
    }
  }

  /** 重复"截止日期"选择弹层（只选日期） */
  @Builder
  repeatEndSheet() {
    Column({ space: 14 }) {
      Text('重复到哪一天')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12 })
      DatePicker({
        start: new Date(2000, 0, 1),
        end: new Date(2060, 11, 31),
        selected: this.pickDate
      })
        .onDateChange((value: Date) => {
          this.pickDate = value;
        })
        .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
        .selectedTextStyle({
          color: $r('app.color.text_primary'),
          font: { size: 16, weight: FontWeight.Medium }
        })
        .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
        .layoutWeight(1)
        .height(210)
        .width('100%')
      Button('确定')
        .width('100%')
        .height(44)
        .borderRadius(12)
        .fontSize(15)
        .backgroundColor($r('app.color.brand'))
        .onClick(() => {
          const d = this.pickDate;
          this.repeatUntil = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
          this.sheetShow = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }

  /** ⭐ 重复日程"作用范围"选择弹层：保存/删除前让用户明确改哪几次 */
  @Builder
  scopeSheet() {
    Column({ space: 8 }) {
      Text(this.pendingDelete ? '删除重复日程' : '修改重复日程')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 4 })
      Text('这是一个重复日程，请选择作用的范围')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 6 })
      this.scopeOption('one', this.pendingDelete ? '仅删除这一次' : '仅修改这一次',
        '只影响所选日期的这一次，其余保持不变')
      this.scopeOption('future', this.pendingDelete ? '删除此次及以后' : '修改此次及以后',
        '从这一次开始到最后一次都' + (this.pendingDelete ? '删除' : '修改'))
      this.scopeOption('all', this.pendingDelete ? '删除全部' : '修改全部',
        '整条重复日程的所有发生都' + (this.pendingDelete ? '删除' : '修改'))
      Text('取消')
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 16 })
        .onClick(() => {
          this.sheetShow = false;
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  scopeOption(mode: string, title: string, desc: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)
      Text(desc)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('app.color.chip_off_bg'))
    .onClick(() => {
      this.sheetShow = false;
      if (this.pendingDelete) {
        this.removeEvent(mode);
      } else {
        this.doSave(mode);
      }
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


  @Builder
  timeRow(label: string, isStart: boolean) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width(36)
      Text(this.allDay
        ? this.fmtDate(isStart ? this.startMs : this.endMs)
        : `${this.fmtDate(isStart ? this.startMs : this.endMs)} ${this.fmtTime(isStart ? this.startMs : this.endMs)}`)
        .fontSize(15)
        .fontColor($r('app.color.brand'))
        .layoutWeight(1)
      Text('›')
        .fontSize(16)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .onClick(() => {
      // 注意：timeRow 的参数是 isStart，openPicker 的参数是 isEnd，语义相反必须取反
      this.openPicker(!isStart);
    })
  }

  @Builder
  repeatChip(mode: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.repeatMode === mode
        ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .backgroundColor(this.repeatMode === mode ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .onClick(() => {
        this.repeatMode = mode;
        // 切换到"重复"时给个合理默认：永不结束（用户可按需改为到某天/共几次）
        if (mode !== 'none' && this.repeatEnd === '') {
          this.repeatEnd = 'never';
        }
      })
  }

  /** 结束条件 chip：永不结束 / 重复到某天 / 共几次 */
  @Builder
  repeatEndChip(mode: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.repeatEnd === mode
        ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .backgroundColor(this.repeatEnd === mode ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .onClick(() => {
        this.repeatEnd = mode;
        if (mode === 'until' && this.repeatUntil <= 0) {
          // 默认给"从开始时间起 3 个月后"
          const s = new Date(this.startMs);
          this.repeatUntil = new Date(s.getFullYear(), s.getMonth() + 3, s.getDate()).getTime();
        }
      })
  }

  /** 提醒 chip 是否选中：0 = 不提醒（列表为空时选中）；其余按是否已选 */
  private chipOn(minutes: number): boolean {
    if (minutes === 0) {
      return this.reminderList.length === 0;
    }
    return this.reminderList.includes(minutes);
  }

  /** 切换提醒：0 = 清空全部；其余多选切换 */
  private toggleReminder(minutes: number): void {
    if (minutes === 0) {
      this.reminderList = [];
      return;
    }
    const list: number[] = [...this.reminderList];
    const idx: number = list.indexOf(minutes);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(minutes);
    }
    this.reminderList = list;
  }

  @Builder
  reminderChip(minutes: number) {
    Text(this.reminderLabel(minutes))
      .fontSize(12)
      .fontColor(this.chipOn(minutes)
        ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .backgroundColor(this.chipOn(minutes) ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .onClick(() => {
        this.toggleReminder(minutes);
      })
  }

  /** 开始/结束时间选择弹层：左侧日期、右侧时间（全天时只有日期），一次确定 */
  @Builder
  dateTimePickerSheet() {
    Column({ space: 14 }) {
      Text(this.pickerIsEnd ? '选择结束时间' : '选择开始时间')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12 })
      Row({ space: 6 }) {
        DatePicker({
          start: new Date(2000, 0, 1),
          end: new Date(2050, 11, 31),
          selected: this.pickDate
        })
          .onDateChange((value: Date) => {
            this.pickDate = value;
          })
          // 滚轮文字显式指定颜色：默认取系统主题色，深色模式下与弹层底色撞色会"看不清"
          .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
          .selectedTextStyle({
            color: $r('app.color.text_primary'),
            font: { size: 16, weight: FontWeight.Medium }
          })
          .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
          .layoutWeight(1)
          .height(210)
        if (!this.allDay) {
          TimePicker({
            selected: new Date(2000, 0, 1, this.pickHour, this.pickMin)
          })
            .onChange((value: TimePickerResult) => {
              this.pickHour = value.hour;
              this.pickMin = value.minute;
            })
            .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
            .selectedTextStyle({
              color: $r('app.color.text_primary'),
              font: { size: 16, weight: FontWeight.Medium }
            })
            .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
            .layoutWeight(1)
            .height(210)
        }
      }
      .width('100%')

      Button(this.allDay ? '确定日期' : '确定')
        .width('100%')
        .height(44)
        .borderRadius(12)
        .fontSize(15)
        .backgroundColor($r('app.color.brand'))
        .onClick(() => {
          this.applyPicker();
          this.sheetShow = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }
}

/**
 * 桥接：从账号存储拿**可写入且能同步**的日历本（只取 CalDAV 日历本），并附上 href。
 *
 * ⚠️ 刻意**不返回"本机"（calKey='local'）**：本应用新建/编辑的日程一律写入某个 CalDAV
 *    日历本并同步到服务器；纯本机日程请用户改用系统「日历」应用完成
 *    （本应用也没有申请写系统日历本地的权限，做不到）。
 */
class CalendarDataBridge {
  static async loadWritableDavSources(context: common.Context): Promise<CalSourceWithHref[]> {
    const result: CalSourceWithHref[] = [];
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    const manualKeys: string[] = await AppSettings.getManualReadonlyKeys(context);
    for (const acc of accounts) {
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        // 只读日历本（服务器无写权限，或用户手动标记只读）不可选
        const detected: boolean = acc.calendarWritable.length > i
          ? acc.calendarWritable[i] !== '0' : true;
        if (!detected || manualKeys.includes(`${acc.id}_${i}`)) {
          continue;
        }
        const s = new CalSourceWithHref();
        s.calKey = `${acc.id}_${i}`;
        let name: string = i < acc.calendarNames.length ? acc.calendarNames[i] : '';
        if (name === '') {
          name = acc.calendarHrefs.length === 1 ? acc.name : `日历本 ${i + 1}`;
        }
        s.name = `${acc.name} · ${name}`;
        let color: string = i < acc.calendarColors.length ? AccountStore.normalizeColor(acc.calendarColors[i]) : '';
        s.color = color !== '' ? color : BookPalette.colorForHref(acc.calendarHrefs[i]);
        s.href = acc.calendarHrefs[i];
        s.writable = true;
        result.push(s);
      }
    }
    return result;
  }

  /**
   * ⭐ 按 calKey（必要时回退按 href 匹配）解析一个日历本的基本信息，
   * 用于"编辑既有日程时，它的日历本不在可写清单里"的兜底补全。
   * 找不到时返回 null（界面会给出明确提示，不静默失败）。
   */
  static async lookupBook(context: common.Context, calKey: string,
    href: string): Promise<BookLookup | null> {
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    for (const acc of accounts) {
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const key: string = `${acc.id}_${i}`;
        if (key !== calKey && !(href !== '' && acc.calendarHrefs[i] === href)) {
          continue;
        }
        const out = new BookLookup();
        out.calKey = key;
        out.href = acc.calendarHrefs[i];
        let name: string = i < acc.calendarNames.length ? acc.calendarNames[i] : '';
        if (name === '') {
          name = acc.calendarHrefs.length === 1 ? acc.name : `日历本 ${i + 1}`;
        }
        out.name = `${acc.name} · ${name}`;
        let color: string = i < acc.calendarColors.length
          ? AccountStore.normalizeColor(acc.calendarColors[i]) : '';
        out.color = color !== '' ? color : BookPalette.colorForHref(acc.calendarHrefs[i]);
        return out;
      }
    }
    return null;
  }
}

/** lookupBook 的返回值（命名 class：ArkTS 不许用内联对象字面量类型） */
class BookLookup {
  calKey: string = '';
  href: string = '';
  name: string = '';
  color: string = '#007DFF';
}

class CalSourceWithHref extends CalSource {
  href: string = '';
}