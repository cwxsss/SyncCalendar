// entry/src/main/ets/common/CardDataService.ets
// 服务卡片数据：从本地库取"今天起"的日程（含 RRULE 展开），输出 JSON 给卡片渲染
import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { CalendarDataService, DisplayEvent } from './CalendarDataService';
import { AppSettings } from './AppSettings';
import { LunarUtil } from './LunarUtil';
import { LogUtil } from './LogUtil';
import { TimelineUtil, DayTimeline, TimelineBlock } from './TimelineUtil';

/** 卡片单条日程（按天分组：组内全天事件在前、有时间的按开始时间排序） */
export class CardItem {
  title: string = '';
  time: string = '';      // 开始时间 '08:30' / '全天'
  endTime: string = '';   // 结束时间 '10:00'（全天事件为空）
  date: string = '';      // '9月15日'
  calName: string = '';   // 所属日历本名称（列表模式卡片右侧展示，颜色同日历本）
  showDate: boolean = false; // 是否为当天分组的第一条（卡片上渲染日期头）
  color: string = '#007DFF';
  // 当前时间红线：start/end 为日程实际起止毫秒（用于定位"现在"位置）；
  // showNowLine 表示该日程上方应绘制红线，isNow 表示该日程正在进行中
  startMs: number = 0;
  endMs: number = 0;
  showNowLine: boolean = false; // 红线画在该日程上方
  isNow: boolean = false;       // 该日程正在进行中
  nowLineBelow: boolean = false; // 今天所有有时间日程已结束：红线画在最后一条下方
}

/** 卡片「全天/跨天」日程（**必须带 eventKey**，否则卡片侧 ForEach 的 key 会重复 → 只渲染出第一条） */
export class CardAllDay {
  eventKey: string = '';
  title: string = '';
  color: string = '#007DFF';
  isAllDay: boolean = true;
}

/** 待办卡片单条（4x4 / 6x4 列表用，带 localId 以支持卡片内直接打勾） */
export class TodoCardItem {
  /** 本地库主键 —— 卡片"打勾完成"时靠它定位要改哪一行 */
  id: number = 0;
  title: string = '';
  /** 截止时间文字：'今天 18:00' / '明天' / '无日期' */
  dueText: string = '';
  /**
   * 副行文字：截止时间 · 日历本（与 App 内 todoSubtitle 同款呈现）。
   * 在数据侧拼好，卡片侧直接显示，避免各卡片各拼一遍导致不一致。
   */
  subText: string = '';
  color: string = '#007DFF';
  calName: string = '';
  /** 是否已完成（已完成的不出现在待办卡片列表里，此字段留作扩展） */
  completed: boolean = false;
}

/** 卡片整体数据 */
export class CardData {
  eventsJson: string = '[]';
  dateText: string = '';
  lunarText: string = '';
  // 2x2 卡片强化：月-日（x月x日，年份冗余故省略）/ 星期 / 今日日程条数
  dateMd: string = '';
  weekday: string = '';
  todayCount: number = 0;
  ongoingCount: number = 0; // 此刻正在进行的日程条数（2x2 卡片红点提示用）
  // 2x4 卡片右侧「正在进行」列表：与 eventsJson 同结构（CardItem[]），只含此刻进行中/下一个日程
  ongoingJson: string = '[]';
  // 4x4 / 6x4 卡片：今日 0-23 时间轴（TimelineBlock[] JSON）与当前时间纵向比例
  timelineJson: string = '[]';
  nowRatio: number = 0;    // 当前时间在当天时间轴上的比例（0~1），卡片画红线用
  nowLabel: string = '';   // 当前时间文字（如 '14:05'）
  allDayJson: string = '[]'; // 全天/跨天日程（CardAllDay[] JSON，卡片画在最上方）
  // 列表模式：当前显示日的"行"式日程（CardItem[]，按全天在前、时间升序；无红线）
  listJson: string = '[]';
  // 日程显示方式：'timeline' | 'list'（与 App 内设置联动；列表模式卡片不画红线）
  displayStyle: string = 'timeline';
  // ===== 卡片翻页（上一天 / 下一天 / 回到今天）=====
  dayOffset: number = 0;    // 相对今天的天数偏移（0=今天）
  isToday: boolean = true;  // 当前显示的是否为今天（非今天不画红线）
  selectedDate: number = 0; // 当前卡片显示的那一天 0 点毫秒（点卡片进入日历时定位到这一天）
  dayCount: number = 0;     // 当前显示日的日程条数（含全天）
  // ===== 待办卡片专用字段（isTodoCard=true 时才有效）=====
  /** 待办卡片列表：TodoCardItem[] JSON（按截止时间升序，未完成在前） */
  todoListJson: string = '[]';
  /** 未完成待办总数（2x2 / 2x4 卡片大数字） */
  todoCount: number = 0;
  /** 今日到期待办数（卡片副标题用） */
  todoTodayCount: number = 0;
  /** 是否待办卡片（卡片侧据此切换渲染分支） */
  isTodoCard: boolean = false;
}

export class CardDataService {
  private static readonly MAX_ITEMS: number = 50;
  // 已添加卡片的 formId 注册表（同进程内有效）
  private static formIds: string[] = [];
  // formIds 持久化（App 重启后内存注册表会清空，从 preferences 恢复，保证推送不丢卡片）
  private static readonly PREF_STORE: string = 'card_form_ids';
  private static readonly PREF_KEY: string = 'form_ids';
  // 每张卡片的"翻页偏移"（formId → 相对今天的天数）。卡片不能滚动，靠翻页看别的日期。
  // 放在这里是为了让 FormExtension（按钮翻页）与 App 内刷新共用同一份状态。
  private static offsets: Map<string, number> = new Map<string, number>();

  static setDayOffset(formId: string, off: number): void {
    CardDataService.offsets.set(formId, off);
  }
  static getDayOffset(formId: string): number {
    return CardDataService.offsets.get(formId) ?? 0;
  }
  static clearDayOffset(formId: string): void {
    CardDataService.offsets.delete(formId);
  }

  /** 注册卡片：内存 + 持久化 */
  static async registerForm(context: common.Context, formId: string): Promise<void> {
    if (formId !== '' && !CardDataService.formIds.includes(formId)) {
      CardDataService.formIds.push(formId);
    }
    await CardDataService.saveFormIds(context);
  }

  /** 注销卡片：内存 + 持久化 */
  static async unregisterForm(context: common.Context, formId: string): Promise<void> {
    CardDataService.formIds = CardDataService.formIds.filter((id: string): boolean => id !== formId);
    await CardDataService.saveFormIds(context);
  }

  private static async saveFormIds(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, CardDataService.PREF_STORE);
      await store.put(CardDataService.PREF_KEY, CardDataService.formIds.join(','));
      await store.flush();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存 formIds 失败: ${e.message}`);
    }
  }

  private static async loadPersistedFormIds(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, CardDataService.PREF_STORE);
      const raw: string = await store.get(CardDataService.PREF_KEY, '') as string;
      for (const id of raw.split(',')) {
        if (id !== '' && !CardDataService.formIds.includes(id)) {
          CardDataService.formIds.push(id);
        }
      }
    } catch (err) {
      // 读取失败则仅用内存注册表
    }
  }

  /** App 内同步完成后调用：刷新所有已添加的卡片 */
  /**
   * 把待办数据合并进日程数据对象。
   *
   * ⭐ 抽出来的原因： EntryFormAbility.pushData 与 CardDataService.pushToAllForms
   * 是两条独立的推送路径，之前只有前者做了合并，后者漏了 ⇒
   * 待办卡片永远显示 0 条（todoCount 停在默认值）。
   * 两处共用同一段逻辑，避免再出现"改一处忘一处"。
   */
  private static mergeTodoInto(ev: CardData, td: CardData): void {
    ev.todoListJson = td.todoListJson;
    ev.todoCount = td.todoCount;
    ev.todoTodayCount = td.todoTodayCount;
  }

  /**
   * @param excludeTodoId 乐观更新用：临时把该待办从**所有卡片**的列表与计数中排除
   *                      （只影响卡片显示，不动数据库）。0 表示不排除。
   */
  static async pushToAllForms(context: common.Context, excludeTodoId: number = 0): Promise<void> {
    // 先恢复持久化的 formId（App 重启后内存注册表为空）
    await CardDataService.loadPersistedFormIds(context);
    if (CardDataService.formIds.length === 0) {
      return;
    }
    // ⭐ 待办数据与 dayOffset 无关（待办不翻页），只构建一次
    let todoData: CardData | null = null;
    try {
      todoData = await CardDataService.buildTodoCardData(context, excludeTodoId);
    } catch (err) {
      console.error(`待办卡片数据构建失败: ${(err as BusinessError).message}`);
    }
    // 各卡片可能翻到了不同日期 → 按偏移分组构建，避免把用户翻走的日期拽回今天
    const cache: Map<number, formBindingData.FormBindingData> =
      new Map<number, formBindingData.FormBindingData>();
    const fallbackData: CardData = await CardDataService.buildCardData(context, 0);
    if (todoData !== null) {
      CardDataService.mergeTodoInto(fallbackData, todoData);
    }
    const fallback: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(fallbackData);
    cache.set(0, fallback);
    const stale: string[] = [];
    for (const formId of CardDataService.formIds) {
      const off: number = CardDataService.getDayOffset(formId);
      let binding: formBindingData.FormBindingData | undefined = cache.get(off);
      if (binding === undefined) {
        const d: CardData = await CardDataService.buildCardData(context, off);
        if (todoData !== null) {
          CardDataService.mergeTodoInto(d, todoData);
        }
        binding = formBindingData.createFormBindingData(d);
        cache.set(off, binding);
      }
      try {
        await formProvider.updateForm(formId, binding);
      } catch (err) {
        const e = err as BusinessError;
        console.error(`卡片 ${formId} 刷新失败(移除注册): ${e.message}`);
        stale.push(formId);
      }
    }
    for (const id of stale) {
      CardDataService.formIds = CardDataService.formIds.filter((x: string): boolean => x !== id);
    }
    if (stale.length > 0) {
      await CardDataService.saveFormIds(context);
    }
  }

  private static startOfDay(ms: number): number {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  }

  /** 组装卡片数据（异步：查询本地库） */
  /** 构建卡片数据。
   *  @param dayOffset 相对"今天"的天数偏移（卡片翻页用：负数=过去，0=今天，正数=未来）
   *                   非今天时不输出 nowRatio（红线不显示）。 */
  static async buildCardData(context: common.Context, dayOffset: number = 0): Promise<CardData> {
      const data = new CardData();
      try {
        LogUtil.init(context);
        const now = new Date();
        const weekCn: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
        const fullWeekCn: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
        const todayStart: number = CardDataService.startOfDay(now.getTime());
        const baseStart: number = todayStart + dayOffset * 86400000; // 当前卡片显示的"那一天"0 点
        const base: Date = new Date(baseStart);
        const prefix: string = dayOffset === 0 ? '今天 ' : (dayOffset === 1 ? '明天 ' :
          (dayOffset === -1 ? '昨天 ' : ''));
        data.dateText = `${prefix}${base.getMonth() + 1}月${base.getDate()}日 ${weekCn[base.getDay()]}`;
        data.lunarText = LunarUtil.lunarDayText(baseStart);
        data.dateMd = `${base.getMonth() + 1}月${base.getDate()}日`;
        data.weekday = fullWeekCn[base.getDay()];
        data.dayOffset = dayOffset;
        data.isToday = dayOffset === 0;
        data.selectedDate = baseStart; // 卡片当前显示日 0 点毫秒（点卡片进入日历时定位用）
      const start: number = baseStart < todayStart ? baseStart : todayStart;
      const end: number = (baseStart > todayStart ? baseStart : todayStart) + 60 * 86400000;
      const sources = await CalendarDataService.loadSources(context);
      const events: DisplayEvent[] = await CalendarDataService.loadEvents(context, start, end, sources);
      // 1) 过滤：保留"今天 0 点以来"的日程（今天已结束的也显示，否则重复日程的
      //    第一次发生会被隐藏，表现为"第一次不显示、第二次及以后显示"）；
      // 2) 按天分组，组内全天在前、有时间按开始时间排序；
      // 3) 平铺输出并给每组第一条打 showDate 标记（日期头只跟在自己日期前面）
      // 跨天日程：已开始未结束的归到"今天"、按全天显示，不再从开始那天重复显示
      const todayKey: number = CardDataService.startOfDay(now.getTime());
      const upcoming: DisplayEvent[] = events
        .filter((e: DisplayEvent): boolean => e.endTime >= todayKey);

      const dayKey = (ms: number): number => CardDataService.startOfDay(ms);
      const spansDays = (e: DisplayEvent): boolean =>
        dayKey(e.endTime) > dayKey(e.startTime);
      // 已开始的跨天日程按全天展示（不参与时间轴定位）
      const isDayLong = (e: DisplayEvent): boolean => e.isAllDay || spansDays(e);
      const groups = new Map<number, DisplayEvent[]>();
      for (const e of upcoming) {
        // 跨天且已开始：归今天；其余归开始日
        const key: number = spansDays(e) && dayKey(e.startTime) < todayKey
          ? todayKey : dayKey(e.startTime);
        const arr = groups.get(key);
        if (arr === undefined) {
          groups.set(key, [e]);
        } else {
          arr.push(e);
        }
      }
      const dayKeys: number[] = Array.from(groups.keys()).sort((a: number, b: number): number => a - b);

      const items: CardItem[] = [];
      const p = (n: number): string => n < 10 ? '0' + n : String(n);
      outer:
      for (const key of dayKeys) {
        // 日期头文字由分组日期生成（与列表视图一致：第一天就是"今天"），
        // 不能用事件的 startTime——跨天日程归组到今天后，日期头仍是开始日会造成"从开始显示"的假象
        const gd = new Date(key);
        const dateLabel: string = key === todayKey
          ? '今天'
          : `${gd.getMonth() + 1}月${gd.getDate()}日`;
        const list = groups.get(key) as DisplayEvent[];
        const allDay = list.filter((e: DisplayEvent): boolean =>
          e.isAllDay || spansDays(e)); // 跨天日程按全天展示
        const timed = list.filter((e: DisplayEvent): boolean =>
          !e.isAllDay && !spansDays(e))
          .sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
        const ordered: DisplayEvent[] = allDay.concat(timed);
        for (let i = 0; i < ordered.length; i++) {
          if (items.length >= CardDataService.MAX_ITEMS) {
            break outer;
          }
          const e = ordered[i];
          const isDayLong: boolean = e.isAllDay || spansDays(e);
          const d = new Date(e.startTime);
          const item = new CardItem();
          item.title = e.title === '' ? '(无标题)' : e.title;
          item.time = isDayLong ? '全天' : `${p(d.getHours())}:${p(d.getMinutes())}`;
          if (isDayLong) {
            item.endTime = '';
          } else {
            const de = new Date(e.endTime);
            item.endTime = `${p(de.getHours())}:${p(de.getMinutes())}`;
          }
          item.date = dateLabel;
          item.showDate = i === 0; // 当天分组第一条 → 卡片上显示日期头
          item.color = e.color;
          // 红线定位：记录实际起止毫秒（用于卡片渲染时判断"现在"位置）
          item.startMs = e.startTime;
          item.endMs = e.endTime;
          items.push(item);
        }
      }
      // 红线逻辑：仅对"今天"分组、且为"有时间"的日程生效（全天/跨天按全天展示，不参与时间轴定位）
      const nowMs: number = Date.now();
      let linePlaced: boolean = false;
      // 1) 正在进行的日程（start<=now<end）→ 红线画在其上方，并标记 isNow
      for (const it of items) {
        if (it.date === '今天' && it.time !== '全天' && it.startMs <= nowMs && nowMs < it.endMs) {
          it.isNow = true;
          it.showNowLine = true;
          linePlaced = true;
          break;
        }
      }
      // 2) 否则：红线画在"下一个尚未开始"的有时间日程上方
      if (!linePlaced) {
        for (const it of items) {
          if (it.date === '今天' && it.time !== '全天' && it.startMs > nowMs) {
            it.showNowLine = true;
            linePlaced = true;
            break;
          }
        }
      }
      // 3) 否则：今天所有有时间日程均已结束 → 红线画在最后一条下方（标记"今日已结束"）
      if (!linePlaced) {
        for (let k = items.length - 1; k >= 0; k--) {
          const it = items[k];
          if (it.date === '今天' && it.time !== '全天') {
            it.nowLineBelow = true;
            linePlaced = true;
            break;
          }
        }
      }
      // 进行中条数：用于 2x2 卡片红点提示
      data.ongoingCount = items.filter((i: CardItem): boolean => i.isNow).length;
      data.eventsJson = JSON.stringify(items);
      // 今日日程条数：item.date === '今天' 的均为今天分组（含全天/跨天进行中）
      data.todayCount = items.filter((i: CardItem): boolean => i.date === '今天').length;

      // ===== 2x4 卡片右侧：**当前时间之后最近的若干条**日程（卡片可滚动，最多 15 条）=====
      // 规则：只取"还没开始"的有时间日程（startTime >= now），
      //      **排除全天 / 跨天**，按开始时间升序取前 2 条。
      //      不再区分"进行中 / 即将开始" —— 卡片上不再显示这些字样。
      const upcomingNext: DisplayEvent[] = upcoming
        .filter((e: DisplayEvent): boolean => !isDayLong(e) && e.startTime >= nowMs)
        .sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
      // ⭐ 上限 15 条：卡片可滚动，不必再为了"放得下"而截断到 2 条。
      //    15 是经验值 —— 再多则用户更该进 App 看，而不是在卡片里翻。
      const ongoingPick: DisplayEvent[] = upcomingNext.slice(0, 15);
      const ongoingItems: CardItem[] = [];
      for (const e of ongoingPick) {
        const dayLong: boolean = isDayLong(e);
        const ds = new Date(e.startTime);
        const de = new Date(e.endTime);
        const oi = new CardItem();
        oi.title = e.title === '' ? '(无标题)' : e.title;
        oi.time = dayLong ? '全天' : `${p(ds.getHours())}:${p(ds.getMinutes())}`;
        oi.endTime = dayLong ? '' : `${p(de.getHours())}:${p(de.getMinutes())}`;
        oi.color = e.color;
        oi.startMs = e.startTime;
        oi.endMs = e.endTime;
        oi.isNow = false;
        ongoingItems.push(oi);
      }
      data.ongoingJson = JSON.stringify(ongoingItems);
      // ===== 4x4 / 6x4 卡片：**当前显示日**的时间轴（色块按时间平铺，冲突分列）=====
      const dayEvents: DisplayEvent[] = events.filter((e: DisplayEvent): boolean =>
        e.startTime < baseStart + 86400000 && e.endTime > baseStart);
      const tl: DayTimeline = TimelineUtil.build(dayEvents, baseStart);
      TimelineUtil.markNow(tl.blocks, nowMs);
      data.timelineJson = JSON.stringify(tl.blocks);
      // 注意：不能直接 stringify(DisplayEvent) —— 它没有 eventKey 字段，
      // 卡片侧 ForEach 会拿到 undefined 导致 key 重复（表现为"全天只显示一条"）
      const allDayItems: CardAllDay[] = [];
      for (const e of tl.allDay) {
        const ad = new CardAllDay();
        ad.eventKey = TimelineUtil.keyOf(e);
        ad.title = e.title === '' ? '(无标题)' : e.title;
        ad.color = e.color;
        ad.isAllDay = e.isAllDay;
        allDayItems.push(ad);
      }
      data.allDayJson = JSON.stringify(allDayItems);
      // 只有"今天"才给红线比例；翻到别的日期时给 -1（卡片侧 nowR<0 → 不画红线）
      data.nowRatio = data.isToday ? TimelineUtil.nowRatio(nowMs) : -1;
      data.nowLabel = TimelineUtil.nowLabel(nowMs);
      data.dayCount = tl.blocks.length + tl.allDay.length;
      // 列表模式数据：当前显示日的"行"式日程（全天在前、有时间按开始时间升序）。
      // 进行中（仅今天的有时间日程）用 isNow 标记 → 卡片上以红条 + "进行中"呈现，**不画横线红线**。
      const dayList: CardItem[] = [];
      const dayAllDay: DisplayEvent[] = tl.allDay;
      const dayTimed: DisplayEvent[] = tl.blocks
        .filter((b: TimelineBlock): boolean => b.ev !== null)
        .map((b: TimelineBlock): DisplayEvent => b.ev as DisplayEvent)
        .sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
      for (const e of dayAllDay.concat(dayTimed)) {
        const li = new CardItem();
        li.title = e.title === '' ? '(无标题)' : e.title;
        const isDayLong: boolean = e.isAllDay || spansDays(e);
        const ds: Date = new Date(e.startTime);
        const de: Date = new Date(e.endTime);
        li.time = isDayLong ? '全天' : `${p(ds.getHours())}:${p(ds.getMinutes())}`;
        li.endTime = isDayLong ? '' : `${p(de.getHours())}:${p(de.getMinutes())}`;
        li.color = e.color;
        li.calName = e.calName;
        li.isNow = data.isToday && !isDayLong && e.startTime <= nowMs && nowMs < e.endTime;
        dayList.push(li);
      }
      data.listJson = JSON.stringify(dayList);
      // 显示方式：与 App 内设置联动（列表模式卡片不画当前时间红线）
      data.displayStyle = await AppSettings.getDisplayStyle(context);
      LogUtil.write(`卡片数据刷新：${items.length} 条，今日 ${data.todayCount} 条，进行中 ${ongoingItems.length} 条，时间轴 ${tl.blocks.length} 块，显示方式 ${data.displayStyle}`);
    } catch (err) {
      LogUtil.write(`卡片数据刷新失败: ${JSON.stringify(err)}`);
    }
    return data;
  }

  /**
   * 卡片列表最多输出多少条待办。
   * ⭐ 统一为 15：所有待办卡片都已改为可滚动（List + 虚拟化），
   *    不必再为了"一屏放得下"而按卡片尺寸给不同上限。
   */
  private static readonly MAX_TODO_ITEMS: number = 15;

  /**
   * 构建**待办卡片**数据。
   *
   * 与 buildCardData 的区别：不查日程，只查 VTODO；输出 todoListJson + 统计数字。
   * 复用同一个 CardData 类，靠 isTodoCard 标记，卡片侧据此走不同渲染分支
   *（这样 FormExtension 的推送逻辑不用区分两种卡片，一套 binding 推所有卡片即可）。
   */
  /** @param excludeId 乐观更新用：临时把该 localId 从列表与计数中排除（不动数据库） */
  static async buildTodoCardData(context: common.Context, excludeId: number = 0): Promise<CardData> {
    const data = new CardData();
    data.isTodoCard = true;
    try {
      LogUtil.init(context);
      const now = new Date();
      const weekCn: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
      const fullWeekCn: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
      data.dateText = `今天 ${now.getMonth() + 1}月${now.getDate()}日 ${weekCn[now.getDay()]}`;
      data.lunarText = LunarUtil.lunarDayText(now.getTime());
      data.dateMd = `${now.getMonth() + 1}月${now.getDate()}日`;
      data.weekday = fullWeekCn[now.getDay()];
      data.dayOffset = 0;
      data.isToday = true;
      data.selectedDate = CardDataService.startOfDay(now.getTime());

      const sources = await CalendarDataService.loadSources(context);
      const todos: DisplayEvent[] = await CalendarDataService.loadTodos(context, sources);

      // 只保留未完成；excludeId>0 时额外剔除该条（乐观更新，仅影响卡片显示）
      const undone: DisplayEvent[] = todos.filter((e: DisplayEvent): boolean =>
        !e.completed && (excludeId <= 0 || e.id !== excludeId));
      const todayStart: number = CardDataService.startOfDay(now.getTime());
      const todayEnd: number = todayStart + 86400000;

      // 排序：有截止时间在前按升序；无截止时间在后（新建的在前）
      const withDue: DisplayEvent[] = undone
        .filter((e: DisplayEvent): boolean => e.endTime > 0)
        .sort((a: DisplayEvent, b: DisplayEvent): number => a.endTime - b.endTime);
      const noDue: DisplayEvent[] = undone
        .filter((e: DisplayEvent): boolean => e.endTime <= 0)
        .sort((a: DisplayEvent, b: DisplayEvent): number => b.id - a.id);

      const orderedList: DisplayEvent[] = withDue.concat(noDue);
      const p2 = (n: number): string => n < 10 ? '0' + n : String(n);

      const items: TodoCardItem[] = [];
      for (const e of orderedList) {
        if (items.length >= CardDataService.MAX_TODO_ITEMS) {
          break;
        }
        const it = new TodoCardItem();
        it.id = e.id;
        it.title = e.title === '' ? '(无标题)' : e.title;
        it.color = e.color;
        it.calName = e.calName;
        it.completed = e.completed;
        // 截止时间文字：今天 / 明天 / 昨天 / 逾期 / 具体日期 / 无日期
        if (e.endTime <= 0) {
          it.dueText = '无日期';
        } else {
          const due = new Date(e.endTime);
          const dueDay: number = CardDataService.startOfDay(e.endTime);
          const diffDays: number = Math.round((dueDay - todayStart) / 86400000);
          const hm: string = `${p2(due.getHours())}:${p2(due.getMinutes())}`;
          // 是否为"当天 0 点整" —— 只有日期的待办，不显示 00:00
          const dateOnly: boolean = due.getHours() === 0 && due.getMinutes() === 0;
          const timePart: string = dateOnly ? '' : ' ' + hm;
          if (diffDays === 0) {
            it.dueText = '今天' + timePart;
          } else if (diffDays === 1) {
            it.dueText = '明天' + timePart;
          } else if (diffDays === -1) {
            it.dueText = '昨天' + timePart;
          } else if (diffDays < -1) {
            it.dueText = `逾期 ${Math.abs(diffDays)} 天`;
          } else if (diffDays > 1 && diffDays <= 7) {
            it.dueText = `${due.getMonth() + 1}月${due.getDate()}日${timePart}`;
          } else {
            it.dueText = `${due.getMonth() + 1}/${due.getDate()}${timePart}`;
          }
        }
        // 副行：截止时间 · 日历本（本名为空时只显示截止时间）
        it.subText = it.calName !== '' ? `${it.dueText} · ${it.calName}` : it.dueText;
        items.push(it);
      }

      data.todoListJson = JSON.stringify(items);
      data.todoCount = undone.length;
      data.todoTodayCount = withDue.filter((e: DisplayEvent): boolean =>
        e.endTime >= todayStart && e.endTime < todayEnd).length;
      // 今日到期条数也塞进 todayCount，让 2x2/2x4 复用同一套大数字排版
      data.todayCount = data.todoCount;
      LogUtil.write(`待办卡片数据刷新：未完成 ${undone.length} 条，今日到期 ${data.todoTodayCount} 条，列表输出 ${items.length} 条`);
    } catch (err) {
      LogUtil.write(`待办卡片数据刷新失败: ${JSON.stringify(err)}`);
    }
    return data;
  }
}
