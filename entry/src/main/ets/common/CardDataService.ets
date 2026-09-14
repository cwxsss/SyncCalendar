// entry/src/main/ets/common/CardDataService.ets
// 服务卡片数据：从本地库取"今天起"的日程（含 RRULE 展开），输出 JSON 给卡片渲染
import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { CalendarDataService, DisplayEvent } from './CalendarDataService';
import { LunarUtil } from './LunarUtil';
import { LogUtil } from './LogUtil';

/** 卡片单条日程（按天分组：组内全天事件在前、有时间的按开始时间排序） */
export class CardItem {
  title: string = '';
  time: string = '';      // 开始时间 '08:30' / '全天'
  endTime: string = '';   // 结束时间 '10:00'（全天事件为空）
  date: string = '';      // '9月15日'
  showDate: boolean = false; // 是否为当天分组的第一条（卡片上渲染日期头）
  calName: string = '';   // 所属日历本名（右侧显示，颜色同日历色）
  color: string = '#007DFF';
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
}

export class CardDataService {
  private static readonly MAX_ITEMS: number = 50;
  // 已添加卡片的 formId 注册表（同进程内有效）
  private static formIds: string[] = [];
  // formIds 持久化（App 重启后内存注册表会清空，从 preferences 恢复，保证推送不丢卡片）
  private static readonly PREF_STORE: string = 'card_form_ids';
  private static readonly PREF_KEY: string = 'form_ids';

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
    const data: CardData = await CardDataService.buildCardData(context);
    const binding: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(data);
    const stale: string[] = [];
    for (const formId of CardDataService.formIds) {
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
  static async buildCardData(context: common.Context): Promise<CardData> {
      const data = new CardData();
      try {
        LogUtil.init(context);
        const now = new Date();
        const weekCn: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
        const fullWeekCn: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
        data.dateText = `${now.getMonth() + 1}月${now.getDate()}日 ${weekCn[now.getDay()]}`;
        data.lunarText = LunarUtil.lunarDayText(now.getTime());
        // 2x2 卡片强化字段：月-日（x月x日，年份冗余省略）、星期全名、今日日程条数
        data.dateMd = `${now.getMonth() + 1}月${now.getDate()}日`;
        data.weekday = fullWeekCn[now.getDay()];
      const start: number = CardDataService.startOfDay(now.getTime());
      const end: number = start + 60 * 86400000;
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
          item.calName = e.calName;
          item.color = e.color;
          items.push(item);
        }
      }
      data.eventsJson = JSON.stringify(items);
      // 今日日程条数：item.date === '今天' 的均为今天分组（含全天/跨天进行中）
      data.todayCount = items.filter((i: CardItem): boolean => i.date === '今天').length;
      LogUtil.write(`卡片数据刷新：${items.length} 条，今日 ${data.todayCount} 条`);
    } catch (err) {
      LogUtil.write(`卡片数据刷新失败: ${JSON.stringify(err)}`);
    }
    return data;
  }
}
