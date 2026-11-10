// entry/src/main/ets/common/CardDataService.ets
// 服务卡片数据：从本地库取"今天起"的日程（含 RRULE 展开），输出 JSON 给卡片渲染
import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { CalendarDataService, DisplayEvent } from './CalendarDataService';
import { AppSettings } from './AppSettings';
import { LunarUtil, isSolarTerm } from './LunarUtil';
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
  location: string = '';        // 地点
  dateTag: string = '';         // '今天' | '明天' | '后天' | '10/31' (多日显示用)
}

/** 卡片按天分组数据（3天 / 7天 多日日历卡片使用） */
export class CardDayGroup {
  dateKey: number = 0;          // 当天 0 点毫秒
  dateLabel: string = '';       // '今天 · 10月30日' / '明天 · 10月31日'
  shortDate: string = '';       // '10月30日'
  weekday: string = '';         // '周五'
  lunar: string = '';           // '九月三十'
  isToday: boolean = false;
  count: number = 0;            // 当天日程数
  items: CardItem[] = [];       // 当天日程列表（全天在前、时间升序）
}

/** 卡片「全天/跨天」日程（**必须带 eventKey**，否则卡片侧 ForEach 的 key 会重复 → 只渲染出第一条） */
export class CardAllDay {
  eventKey: string = '';
  title: string = '';
  color: string = '#007DFF';
  isAllDay: boolean = true;
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
  // ===== 3天 / 7天 多日卡片 =====
  cardDays: number = 1;      // 1 | 3 | 7
  daysRangeText: string = ''; // '10月30日 - 11月1日' / '未来3天'
  rangeCount: number = 0;    // 当前所选天数范围内的全部日程总数
  multiDayJson: string = '[]'; // CardDayGroup[] JSON（供多日列表渲染）
  nextRefreshMinutes: number = 30; // 智能计算的下次最佳刷新间隔（分钟，紧贴下一日程起止时刻）
}

interface FormOffsetInfo {
  offset: number;
  setAt: number;
  dayStartMs: number;
}

export class CardDataService {
  private static readonly MAX_ITEMS: number = 50;
  // 已添加卡片的 formId 注册表（同进程内有效）
  private static formIds: string[] = [];
  // formIds 持久化（App 重启后内存注册表会清空，从 preferences 恢复，保证推送不丢卡片）
  private static readonly PREF_STORE: string = 'card_form_ids';
  private static readonly PREF_KEY: string = 'form_ids';
  // 每张卡片的"翻页偏移"（formId → 相对今天的天数）。带时间戳与所属日期，防跨天滞留显示昨天。
  private static offsetMap: Map<string, FormOffsetInfo> = new Map<string, FormOffsetInfo>();

  static setDayOffset(formId: string, off: number): void {
    if (off === 0) {
      CardDataService.offsetMap.delete(formId);
      return;
    }
    const now = Date.now();
    CardDataService.offsetMap.set(formId, {
      offset: off,
      setAt: now,
      dayStartMs: CardDataService.startOfDay(now)
    });
  }

  static getDayOffset(formId: string): number {
    const info = CardDataService.offsetMap.get(formId);
    if (info === undefined) {
      return 0;
    }
    const now = Date.now();
    const todayStart = CardDataService.startOfDay(now);
    // 1. 如果已跨天，翻页偏移自动失效，重置回今天（避免隔天打开仍然显示"昨天"）
    if (info.dayStartMs !== todayStart) {
      CardDataService.offsetMap.delete(formId);
      return 0;
    }
    // 2. 如果翻页不是今天（offset !== 0），超过 15 分钟无操作，自动归位回今天
    if (now - info.setAt > 15 * 60 * 1000) {
      CardDataService.offsetMap.delete(formId);
      return 0;
    }
    return info.offset;
  }

  static clearDayOffset(formId: string): void {
    CardDataService.offsetMap.delete(formId);
  }

  /** 计算卡片下一次应当刷新的时间间隔（分钟）：紧贴下一个日程的开始、结束时刻或保底 30 分钟 / 跨天午夜 */
  static calcNextRefreshMinutes(events: DisplayEvent[]): number {
    const now = Date.now();
    const dNow = new Date(now);
    // 次日凌晨 00:00:30
    const tomorrowMidnight = new Date(dNow.getFullYear(), dNow.getMonth(), dNow.getDate() + 1, 0, 0, 30).getTime();

    // 默认保底：30 分钟后或午夜
    let targetMs = Math.min(now + 30 * 60 * 1000, tomorrowMidnight);

    for (const e of events) {
      if (e.isAllDay) {
        continue;
      }
      // 任何定时日程的开始时刻（即将变为"进行中"）
      if (e.startTime > now && e.startTime < targetMs) {
        targetMs = e.startTime;
      }
      // 任何定时日程的结束时刻（即将结束"进行中"）
      if (e.endTime > now && e.endTime < targetMs) {
        targetMs = e.endTime;
      }
    }

    const diffMs = targetMs - now;
    // 鸿蒙系统限制：formProvider.setFormNextRefreshTime 要求 waitMinutes >= 5
    return Math.max(5, Math.ceil(diffMs / 60000));
  }

  /**
   * 智能预约下一次卡片刷新时间点，确保在日程开始、日程结束、跨天或保底周期触发
   */
  static scheduleNextRefresh(formId: string, minutes: number = 30): void {
    if (!formId || formId === '') {
      return;
    }
    const waitMinutes = Math.max(5, minutes);
    try {
      formProvider.setFormNextRefreshTime(formId, waitMinutes).then((): void => {
        LogUtil.write(`卡片 ${formId} 已预约智能刷新：${waitMinutes} 分钟后（预计 ${new Date(Date.now() + waitMinutes * 60000).toLocaleTimeString()}）`);
      }).catch((err: BusinessError): void => {
        LogUtil.write(`卡片 ${formId} 预约刷新异常: code=${err.code ?? ''} message=${err.message}`);
        if (err.code === 16501001) {
          CardDataService.formIds = CardDataService.formIds.filter((id: string): boolean => id !== formId);
        }
      });
    } catch (err) {
      // 容错
    }
  }

  // 每张卡片的日程显示天数跨度（formId → 1 | 3 | 7）
  private static formDays: Map<string, number> = new Map<string, number>();

  static setCardDays(formId: string, days: number): void {
    CardDataService.formDays.set(formId, days);
  }
  static getCardDays(formId: string): number {
    return CardDataService.formDays.get(formId) ?? 0;
  }
  static clearCardDays(formId: string): void {
    CardDataService.formDays.delete(formId);
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
  static async pushToAllForms(context: common.Context): Promise<void> {
    // 先恢复持久化的 formId（App 重启后内存注册表为空）
    await CardDataService.loadPersistedFormIds(context);
    if (CardDataService.formIds.length === 0) {
      return;
    }
    // 各卡片可能翻到了不同日期 → 按偏移分组构建，避免把用户翻走的日期拽回今天
    const cache: Map<string, formBindingData.FormBindingData> =
      new Map<string, formBindingData.FormBindingData>();
    const dataCache: Map<string, CardData> = new Map<string, CardData>();
    const fallbackData: CardData = await CardDataService.buildCardData(context, 0);
    const fallback: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(fallbackData);
    cache.set('0_1', fallback);
    dataCache.set('0_1', fallbackData);
    const stale: string[] = [];
    for (const formId of CardDataService.formIds) {
      const off: number = CardDataService.getDayOffset(formId);
      const days: number = CardDataService.getCardDays(formId);
      const cacheKey: string = `${off}_${days}`;
      let binding: formBindingData.FormBindingData | undefined = cache.get(cacheKey);
      let cardDataObj: CardData | undefined = dataCache.get(cacheKey);
      if (binding === undefined || cardDataObj === undefined) {
        cardDataObj = await CardDataService.buildCardData(context, off, days);
        binding = formBindingData.createFormBindingData(cardDataObj);
        cache.set(cacheKey, binding);
        dataCache.set(cacheKey, cardDataObj);
      }
      try {
        await formProvider.updateForm(formId, binding);
        CardDataService.scheduleNextRefresh(formId, cardDataObj.nextRefreshMinutes);
      } catch (err) {
        const e = err as BusinessError;
        LogUtil.write(`卡片 ${formId} 刷新失败: code=${e.code ?? ''} message=${e.message}`);
        // 只有错误码明确为 16501001 (卡片不存在/已被用户移除) 时才剔除注册；
        // 其它临时错误（如锁屏、IPC连接超时 16500050/16500060、内部错误等）保留卡片注册，下次重试
        if (e.code === 16501001) {
          stale.push(formId);
        }
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
  static async buildCardData(context: common.Context, dayOffset: number = 0, targetDays: number = 0): Promise<CardData> {
      const data = new CardData();
      if (targetDays <= 0) {
        targetDays = await AppSettings.getCardDaysRange(context);
      }
      if (targetDays !== 3 && targetDays !== 7) {
        targetDays = 1;
      }
      data.cardDays = targetDays;
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
      const showTodos: boolean = await AppSettings.getShowTodosInCalendar(context);
      if (showTodos) {
        const todos: DisplayEvent[] = await CalendarDataService.loadTodos(context, sources);
        for (const t of todos) {
          if (t.startTime > 0 && !t.completed) {
            events.push(t);
          }
        }
      }
      // 1) 过滤：保留"今天 0 点以来"的日程（今天已结束的也显示，否则重复日程的
      //    第一次发生会被隐藏，表现为"第一次不显示、第二次及以后显示"）；
      //    ⚠️ 必须严格 > todayKey，或者当天开始的日程。排他性结束于今天 00:00:00 的日程属于昨天，切勿混入今天！
      const todayKey: number = CardDataService.startOfDay(now.getTime());
      const upcoming: DisplayEvent[] = events
        .filter((e: DisplayEvent): boolean => e.endTime > todayKey || (e.startTime >= todayKey && e.endTime >= e.startTime));

      const dayKey = (ms: number): number => CardDataService.startOfDay(ms);
      const spansDays = (e: DisplayEvent): boolean => {
        if (isSolarTerm(e.title)) {
          return false;
        }
        const effectiveEnd = (e.endTime > e.startTime) ? (e.endTime - 1) : e.startTime;
        return dayKey(effectiveEnd) > dayKey(e.startTime);
      };
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

      // ===== 3天 / 7天 多日日历数据组装 =====
      const multiDayGroups: CardDayGroup[] = [];
      const numDays: number = targetDays > 1 ? targetDays : 1;
      const endDayDate = new Date(baseStart + (numDays - 1) * 86400000);
      if (numDays === 3) {
        data.daysRangeText = dayOffset === 0
          ? `未来3天 (${base.getMonth() + 1}/${base.getDate()}-${endDayDate.getMonth() + 1}/${endDayDate.getDate()})`
          : `${base.getMonth() + 1}月${base.getDate()}日-${endDayDate.getMonth() + 1}月${endDayDate.getDate()}日`;
      } else if (numDays === 7) {
        data.daysRangeText = dayOffset === 0
          ? `未来7天 (${base.getMonth() + 1}/${base.getDate()}-${endDayDate.getMonth() + 1}/${endDayDate.getDate()})`
          : `${base.getMonth() + 1}月${base.getDate()}日-${endDayDate.getMonth() + 1}月${endDayDate.getDate()}日`;
      } else {
        data.daysRangeText = data.dateText;
      }

      for (let di = 0; di < numDays; di++) {
        const curDayStart: number = baseStart + di * 86400000;
        const curDayEnd: number = curDayStart + 86400000;
        const cd: Date = new Date(curDayStart);
        const grp = new CardDayGroup();
        grp.dateKey = curDayStart;
        grp.isToday = (curDayStart === todayStart);
        grp.shortDate = `${cd.getMonth() + 1}月${cd.getDate()}日`;
        grp.weekday = weekCn[cd.getDay()];
        grp.lunar = LunarUtil.lunarDayText(curDayStart);
        if (grp.isToday) {
          grp.dateLabel = `今天 · ${grp.shortDate} ${grp.weekday}`;
        } else if (curDayStart === todayStart + 86400000) {
          grp.dateLabel = `明天 · ${grp.shortDate} ${grp.weekday}`;
        } else if (curDayStart === todayStart + 2 * 86400000) {
          grp.dateLabel = `后天 · ${grp.shortDate} ${grp.weekday}`;
        } else {
          grp.dateLabel = `${grp.shortDate} ${grp.weekday}`;
        }

        const dayEvs: DisplayEvent[] = events.filter((e: DisplayEvent): boolean => {
          const startDay = CardDataService.startOfDay(e.startTime);
          let endDay = startDay;
          if (isSolarTerm(e.title)) {
            endDay = startDay;
          } else {
            const effectiveEnd = (e.endTime > e.startTime) ? (e.endTime - 1) : e.startTime;
            endDay = CardDataService.startOfDay(effectiveEnd);
          }
          return curDayStart >= startDay && curDayStart <= endDay;
        });
        const dayAllDay = dayEvs.filter((e: DisplayEvent): boolean => e.isAllDay || spansDays(e));
        const dayTimed = dayEvs.filter((e: DisplayEvent): boolean => !e.isAllDay && !spansDays(e))
          .sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);

        for (const e of dayAllDay.concat(dayTimed)) {
          const isDayLong: boolean = e.isAllDay || spansDays(e);
          const ds = new Date(e.startTime);
          const de = new Date(e.endTime);
          const it = new CardItem();
          it.title = e.title === '' ? '(无标题)' : e.title;
          it.time = isDayLong ? '全天' : `${p(ds.getHours())}:${p(ds.getMinutes())}`;
          it.endTime = isDayLong ? '' : `${p(de.getHours())}:${p(de.getMinutes())}`;
          it.date = grp.dateLabel;
          it.calName = e.calName;
          it.color = e.color;
          it.location = e.location;
          it.startMs = e.startTime;
          it.endMs = e.endTime;
          it.isNow = grp.isToday && !isDayLong && e.startTime <= nowMs && nowMs < e.endTime;
          it.dateTag = grp.isToday ? '今天' : (curDayStart === todayStart + 86400000 ? '明天' : (curDayStart === todayStart + 2 * 86400000 ? '后天' : `${cd.getMonth() + 1}/${cd.getDate()}`));
          grp.items.push(it);
        }
        grp.count = grp.items.length;
        // ⭐ 优化：显示未来7天和未来3天时（numDays > 1），如果没有日程和待办（grp.count === 0），
        // 则不显示该天日期（不加入 multiDayGroups），彻底节省卡片有限的空间！
        if (numDays <= 1 || grp.count > 0) {
          multiDayGroups.push(grp);
        }
      }
      data.multiDayJson = JSON.stringify(multiDayGroups);
      data.rangeCount = multiDayGroups.reduce((acc: number, g: CardDayGroup): number => acc + g.count, 0);

      // ===== 2x4 卡片右侧：**当前时间之后最近的 2 条**日程 =====
      // 规则：只取"还没开始"的有时间日程（startTime >= now），
      //      **排除全天 / 跨天**，按开始时间升序取前 2 条。
      //      不再区分"进行中 / 即将开始" —— 卡片上不再显示这些字样。
      const upcomingNext: DisplayEvent[] = upcoming
        .filter((e: DisplayEvent): boolean => !isDayLong(e) && e.startTime >= nowMs)
        .sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
      let ongoingPick: DisplayEvent[] = [];
      if (targetDays > 1) {
        const rangeEndMs: number = baseStart + numDays * 86400000;
        const futureEvs: DisplayEvent[] = events
          .filter((e: DisplayEvent): boolean => e.endTime >= (baseStart <= todayStart ? nowMs : baseStart) && e.startTime < rangeEndMs)
          .sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
        ongoingPick = futureEvs.slice(0, 15);
      } else {
        ongoingPick = upcomingNext.slice(0, 15);
      }
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
        const eDayStart: number = CardDataService.startOfDay(e.startTime);
        const isOngoingCrossDay = eDayStart < todayStart && e.endTime > todayStart;
        oi.dateTag = isOngoingCrossDay ? '今天' : (eDayStart === todayStart ? '今天' : (eDayStart === todayStart + 86400000 ? '明天' : (eDayStart === todayStart + 2 * 86400000 ? '后天' : `${ds.getMonth() + 1}/${ds.getDate()}`)));
        oi.calName = e.calName;
        oi.location = e.location;
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
        li.startMs = e.startTime;
        li.endMs = e.endTime;
        li.isNow = data.isToday && !isDayLong && e.startTime <= nowMs && nowMs < e.endTime;
        dayList.push(li);
      }
      data.listJson = JSON.stringify(dayList);
      // 显示方式：与 App 内设置联动（列表模式卡片不画当前时间红线）
      data.displayStyle = await AppSettings.getDisplayStyle(context);
      data.nextRefreshMinutes = CardDataService.calcNextRefreshMinutes(events);
      LogUtil.write(`卡片数据刷新：${items.length} 条，跨度 ${data.cardDays} 天(${data.rangeCount} 条)，今日 ${data.todayCount} 条，进行中 ${ongoingItems.length} 条，时间轴 ${tl.blocks.length} 块，下次刷新 ${data.nextRefreshMinutes} 分钟后`);
    } catch (err) {
      LogUtil.write(`卡片数据刷新失败: ${JSON.stringify(err)}`);
    }
    return data;
  }
}
