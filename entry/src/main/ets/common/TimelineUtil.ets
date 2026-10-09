// entry/src/main/ets/common/TimelineUtil.ets
// 时间轴布局：把"某一天"的日程按真实时间平铺到 0-23 小时的纵向格子上。
//
// 设计约定（与用户确认）：
//  - 时间粒度 1 小时 = 1 格（0 点到 23 点，共 24 格），色块高度按实际时长换算。
//  - 同一时间重叠（冲突）的日程横向平分宽度：1 条 = 100%，2 条 = 50%，3 条 ≈ 33.3%…
//  - 色块背景色 = 所属日历本颜色。
//  - 全天/跨天日程不占时间轴，单独返回，由视图画在最上方（0 点之前）。
//  - 当前时间红线按"现在"在时间轴上的纵向比例定位（hoursFromDayStart / 24）。
//
// ArkTS 约束：所有"多字段返回值"必须是命名 class，不能用内联对象字面量类型。
import { DisplayEvent } from './CalendarDataService';

/** 时间轴上的一个日程色块（位置/尺寸都用相对比例，视图侧乘以实际高度即可） */
export class TimelineBlock {
  eventKey: string = '';   // 与视图 ForEach key 一致
  title: string = '';
  timeText: string = '';   // '09:00 - 10:30'
  location: string = '';   // 地点（第 2/3 行显示）
  color: string = '#007DFF';
  writable: boolean = true; // 所属日历本是否可写（false → 色块标题后挂白框「只读」小标）
  topRatio: number = 0;    // 距 0 点的比例 0~1（乘时间轴总高）
  heightRatio: number = 0; // 高度比例（最小高度由视图侧兜底）
  leftRatio: number = 0;   // 横向起始比例 0~1（冲突平分）
  widthRatio: number = 1;  // 横向宽度比例
  groupIndex: number = 0;  // 冲突组序号（时间上连通重叠的一簇，视图侧按组分行）
  laneIndex: number = 0;   // 组内的"列号"（贪心分列结果，列号相同的日程互不重叠、可复用一列）
  isNow: boolean = false;  // 正在进行中（视图侧可高亮）
  // 原始时间，点击/详情使用
  ev: DisplayEvent | null = null;
}

/** 一天的完整时间轴布局结果 */
export class DayTimeline {
  dateKey: number = 0;            // 该天 0 点毫秒（ForEach key 去重 / 调试用）
  allDay: DisplayEvent[] = [];    // 全天 / 跨天（画在 0 点之前）
  blocks: TimelineBlock[] = [];   // 时间轴色块
  hasTimed: boolean = false;      // 当天是否有有时间日程
}

/** 冲突分组：一组时间上互相重叠的日程（用于横向平分宽度） */
class OverlapGroup {
  items: DisplayEvent[] = [];
  endMax: number = 0;
}

/** 视图/卡片渲染用的"冲突组"：一组互相重叠的日程横向平分宽度，每条各占一"列"(lane)。
 *  纵向：组本身占据 [startRatio, endRatio] 一段，组内每条按自己的 topRatio 定位。
 *  不同组在时间上互不重叠（由分组算法保证），因此可以按时间顺序自上而下排列。 */
export class TimelineGroup {
  startRatio: number = 0;        // 组内最早开始（距 0 点比例 0~1）
  endRatio: number = 0;          // 组内最晚结束
  laneCount: number = 1;         // 列数 = 组内"最大同时重叠数"（贪心分列结果，不是组内条数）
  gapBeforeRatio: number = 0;    // 与上一个组（或 0 点）之间的空隙比例
  blocks: TimelineBlock[] = [];  // 组内全部色块（按开始时间升序）
  lanes: TimelineBlock[][] = []; // 按列组织：lanes[i] = 第 i 列上的色块（同列互不重叠，纵向依次排列）
}

/** 视窗范围（小时）：按当天日程的起止截断，"今天"还要容纳当前时刻 */
export class ViewRange {
  startHour: number = 0;
  endHour: number = 0;
}

export class TimelineUtil {
  /** 单个格子的高度（vp）：调用方（视图/卡片）用同一个常量换算 */
  static readonly HOUR_UNIT: number = 44;

  /** 0 点毫秒 */
  static startOfDay(ms: number): number {
    const d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  }

  private static spansDays(e: DisplayEvent): boolean {
    return TimelineUtil.startOfDay(e.endTime) > TimelineUtil.startOfDay(e.startTime);
  }

  /** 日程唯一 key（与列表 ForEach 保持一致） */
  static keyOf(e: DisplayEvent): string {
    return `${e.isSystem ? 's' : 'l'}${e.id}_${e.startTime}`;
  }

  private static fmtTime(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  // ---- 只读外观 ------------------------------------------------------------
  // 只读不再用"灰蒙版底色"（观感不好，已撤），改为在色块标题后挂一个**白框白字**的「只读」小标
  // （见 Index 的 roTag()/卡片内的同名小标）。这里只负责把可写标记带出来。

  /**
   * 构建某一天的时间轴布局。
   * @param events 与 dateMs 这一天相交的全部日程
   * @param dateMs 该天 0 点毫秒
   */
  static build(events: DisplayEvent[], dateMs: number): DayTimeline {
    const res = new DayTimeline();
    const dayStart: number = TimelineUtil.startOfDay(dateMs);
    const dayEnd: number = dayStart + 86400000;
    res.dateKey = dayStart;

    // 1) 分类：全天 → 顶部；有时间 → 时间轴（无论是否当天开始，都按与本日的交集定位）
    //    注意：多日日程由上层"逐天展开"后传入，这里只需按交集裁切即可，不能再整条丢到顶部，
    //    否则跨天日程的时间段会全部消失（曾导致"除全天外一条都看不到"）。
    const timed: DisplayEvent[] = [];
    for (const e of events) {
      if (e.isAllDay) {
        res.allDay.push(e);
      } else if (e.startTime <= dayStart && e.endTime >= dayEnd) {
        // 覆盖整天（多日日程的中间日）：占满整列会挡住别的日程 → 放顶部"跨天"条
        res.allDay.push(e);
      } else if (e.endTime > dayStart && e.startTime < dayEnd) {
        // 与"本日 0 点~24 点"有真实时间交集 → 画在时间轴上（起始/结束按交集裁切）
        timed.push(e);
      }
    }
    res.allDay.sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
    res.hasTimed = timed.length > 0;
    if (timed.length === 0) {
      return res;
    }

    // 2) 时间轴色块：按开始时间排序，划分"冲突组"（互相重叠的归为一组）
    timed.sort((a: DisplayEvent, b: DisplayEvent): number => a.startTime - b.startTime);
    const groups: OverlapGroup[] = [];
    for (const e of timed) {
      const last: OverlapGroup | undefined = groups.length > 0 ? groups[groups.length - 1] : undefined;
      if (last !== undefined && e.startTime < last.endMax) {
        last.items.push(e);
        last.endMax = Math.max(last.endMax, e.endTime);
      } else {
        const g = new OverlapGroup();
        g.items = [e];
        g.endMax = e.endTime;
        groups.push(g);
      }
    }

    // 3) 组内"贪心分列"（区间图着色）：按开始时间升序，每条放进"结束时间 <= 它开始时间"的
    //    **编号最小**的那一列。列数 = 该组"最大同时重叠数"，而不是组内条数。
    //    例：A 7:30-9:30、B 8:20-9:00、C 9:15-9:55 —— B 与 C 并不重叠，可共用同一列，
    //    因此只需 2 列（旧算法按"传递性重叠"把三者归为一组 → 错误地分成 3 列）。
    let groupIdx: number = 0;
    for (const g of groups) {
      const laneEnd: number[] = []; // 每列当前的最后结束时间（毫秒）
      const laneOf: number[] = [];  // 每条日程分配到的列号
      for (const e of g.items) {
        let lane: number = -1;
        for (let i = 0; i < laneEnd.length; i++) {
          if (laneEnd[i] <= e.startTime) {
            lane = i;
            break;
          }
        }
        if (lane < 0) {
          lane = laneEnd.length;
          laneEnd.push(e.endTime);
        } else {
          laneEnd[lane] = e.endTime;
        }
        laneOf.push(lane);
      }
      const n: number = laneEnd.length > 0 ? laneEnd.length : 1; // 列数 = 最大同时重叠数
      for (let i = 0; i < g.items.length; i++) {
        const e = g.items[i];
        const b = new TimelineBlock();
        b.eventKey = TimelineUtil.keyOf(e);
        b.groupIndex = groupIdx;
        b.title = e.title === '' ? '(无标题)' : e.title;
        b.timeText = `${TimelineUtil.fmtTime(e.startTime)} - ${TimelineUtil.fmtTime(e.endTime)}`;
        b.location = e.location;
        b.writable = e.writable;
        b.color = e.color;
        // 与今天的交集（跨天日程已排除，这里都是日内）
        const s: number = Math.max(e.startTime, dayStart);
        const en: number = Math.min(e.endTime, dayEnd);
        b.topRatio = (s - dayStart) / 86400000;
        b.heightRatio = Math.max((en - s) / 86400000, 1 / 96); // 最短约 15 分钟，避免零高
        b.laneIndex = laneOf[i];
        b.widthRatio = 1 / n;
        b.leftRatio = laneOf[i] / n;
        b.isNow = false;
        b.ev = e;
        res.blocks.push(b);
      }
      groupIdx++;
    }
    // 兜底：保证 blocks 严格按 topRatio 升序，供视图侧 Blank 间隙求差无累积漂移
    res.blocks.sort((a: TimelineBlock, b: TimelineBlock): number => a.topRatio - b.topRatio);
    return res;
  }

  /**
   * 由平坦的色块列表重建"冲突分组"：视图 / 卡片按组分行、组内按列（lane）并排渲染。
   * 依赖 TimelineBlock.groupIndex / leftRatio / topRatio / heightRatio。
   * 卡片侧只拿到 timelineJson（TimelineBlock[] 序列化，含 groupIndex），因此用它同样能重建。
   */
  static groupsOf(blocks: TimelineBlock[]): TimelineGroup[] {
    const map: Map<number, TimelineBlock[]> = new Map<number, TimelineBlock[]>();
    for (const b of blocks) {
      const arr: TimelineBlock[] | undefined = map.get(b.groupIndex);
      if (arr === undefined) {
        map.set(b.groupIndex, [b]);
      } else {
        arr.push(b);
      }
    }
    const idxs: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    const out: TimelineGroup[] = [];
    let prevEnd: number = 0;
    for (const gi of idxs) {
      const bs: TimelineBlock[] = map.get(gi) ?? [];
      // 按开始时间升序（同开始时间则长的在前，保证分列稳定）
      bs.sort((a: TimelineBlock, b: TimelineBlock): number => {
        if (a.topRatio !== b.topRatio) {
          return a.topRatio - b.topRatio;
        }
        return b.heightRatio - a.heightRatio;
      });
      // 贪心分列：每条放进"结束时间 <= 它开始时间"的编号最小的列 → 列数 = 最大同时重叠数
      // 这里用比例而非原始毫秒重算，卡片侧（只有序列化后的 timelineJson）也能正确分列。
      const lanes: TimelineBlock[][] = [];
      const laneEnd: number[] = [];
      for (const b of bs) {
        let li: number = -1;
        for (let i = 0; i < laneEnd.length; i++) {
          if (laneEnd[i] <= b.topRatio + 0.0000001) {
            li = i;
            break;
          }
        }
        const be: number = b.topRatio + b.heightRatio;
        if (li < 0) {
          li = lanes.length;
          lanes.push([b]);
          laneEnd.push(be);
        } else {
          lanes[li].push(b);
          laneEnd[li] = be;
        }
        b.laneIndex = li;
      }
      const lc: number = lanes.length > 0 ? lanes.length : 1;
      for (const b of bs) {
        b.widthRatio = 1 / lc;
        b.leftRatio = b.laneIndex / lc;
      }
      const g = new TimelineGroup();
      g.blocks = bs;
      g.lanes = lanes;
      g.laneCount = lc;
      let s: number = 1;
      let e: number = 0;
      for (const b of bs) {
        if (b.topRatio < s) {
          s = b.topRatio;
        }
        const be: number = b.topRatio + b.heightRatio;
        if (be > e) {
          e = be;
        }
      }
      g.startRatio = s;
      g.endRatio = e;
      g.gapBeforeRatio = s - prevEnd < 0 ? 0 : s - prevEnd;
      prevEnd = e;
      out.push(g);
    }
    return out;
  }

  /** 时间轴"基准可视区"的起止小时：8:00 ~ 18:00 **恒定显示**（与用户确认）。 */
  static readonly BASE_START_HOUR: number = 8;
  static readonly BASE_END_HOUR: number = 18;

  /**
   * 计算"需要显示的小时区间"（视窗截断）。规则（与用户确认）：
   *  - **8:00 ~ 18:00 恒定显示**（即使当天没有任何日程，也至少显示这一段，避免"只有一条日程
   *    就只显示那 1 小时"的奇怪观感）；
   *  - 若某天在 **8 点之前**有日程 → 起点向前扩到最早日程所在整点；否则 8 点之前的刻度不显示；
   *  - 若某天在 **18 点之后**有日程 → 终点向后扩到最晚日程结束时刻向上取整；否则 18 点之后的刻度不显示。
   *  - includeNowHour=true（今天）时，把当前时刻所在小时并进来以保证红线可见 —— 但**仍遵守上面的
   *    "无日程则不显示"约束**：只有当该侧本来就有日程（起点已 <8 / 终点已 >18）时才允许继续向外扩，
   *    否则不会因为"当前时刻"而把 8 点前 / 18 点后的空档重新显示出来。
   * 视图渲染与"列表视图按天计算卡片高度"共用这一份逻辑，避免两边算法漂移。
   */
  static viewRange(blocks: TimelineBlock[], includeNowHour: boolean, nowMs: number): ViewRange {
    const rg = new ViewRange();
    // 基准：8~18 恒显示
    let s: number = TimelineUtil.BASE_START_HOUR;
    let e: number = TimelineUtil.BASE_END_HOUR;
    for (const b of blocks) {
      const bh: number = Math.floor(b.topRatio * 24);
      const eh: number = Math.ceil((b.topRatio + b.heightRatio) * 24 - 0.0001);
      if (bh < s) {
        s = bh;
      }
      if (eh > e) {
        e = eh;
      }
    }
    if (includeNowHour) {
      const nh: number = Math.floor(TimelineUtil.nowRatio(nowMs) * 24);
      // 只有"该侧本来就有日程"时才允许把当前小时并进来（否则会违反"8 点前/18 点后无日程则不显示"）
      if (nh < s && s < TimelineUtil.BASE_START_HOUR) {
        s = nh;
      }
      if (nh + 1 > e && e > TimelineUtil.BASE_END_HOUR) {
        e = nh + 1;
      }
    }
    if (s < 0) {
      s = 0;
    }
    if (s > 23) {
      s = 23;
    }
    if (e > 24) {
      e = 24;
    }
    if (e <= s) {
      e = s + 1 > 24 ? 24 : s + 1;
    }
    rg.startHour = s;
    rg.endHour = e;
    return rg;
  }

  /** 某天"有时间"的日程是否已全部结束：最晚结束比例 <= 当前时刻比例。
   *  （全天/跨天色块不参与 —— 它们没有"结束时刻"概念。）
   *  当只剩全天日程、或当天无任何定时日程时，同样返回 true（视为"已无进行中的日程"）。
   *  用于：决定是否显示"当前时间红线"，以及是否把"当前小时"并入时间轴视窗。 */
  static allTimedEnded(blocks: TimelineBlock[], nowMs: number): boolean {
    let maxEnd: number = 0;
    for (const b of blocks) {
      const e: number = b.topRatio + b.heightRatio;
      if (e > maxEnd) {
        maxEnd = e;
      }
    }
    return TimelineUtil.nowRatio(nowMs) >= maxEnd - 0.0001;
  }

  /** 标记"正在进行"的色块（start<=now<end），供视图高亮 */
  static markNow(blocks: TimelineBlock[], nowMs: number): void {
    for (const b of blocks) {
      if (b.ev !== null) {
        b.isNow = b.ev.startTime <= nowMs && nowMs < b.ev.endTime;
      }
    }
  }

  /** 当前时间在当天时间轴上的纵向比例（0~1，超出 0 点/24 点会被夹紧） */
  static nowRatio(nowMs: number): number {
    const dayStart: number = TimelineUtil.startOfDay(nowMs);
    let r: number = (nowMs - dayStart) / 86400000;
    if (r < 0) {
      r = 0;
    }
    if (r > 1) {
      r = 1;
    }
    return r;
  }

  /** 当前时间的小时刻度文字（画在红线左侧），如 '14:05' */
  static nowLabel(ms: number): string {
    return TimelineUtil.fmtTime(ms);
  }
}
