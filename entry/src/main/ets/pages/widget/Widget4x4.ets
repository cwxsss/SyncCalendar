// entry/src/main/ets/pages/widget/Widget4x4.ets
// 4x4 服务卡片：今日时间轴 —— 与 6x4 完全同一套逻辑，只是尺寸更小：
//   · 用 List 包一个"很高的 ListItem"（整日时间轴按真实 vp 高度撑开）→ 卡片内可以上下滑动
//     （官方卡片能力清单里 List / ListItem 支持，Scroll 与 Scroller 不支持）
//   · 视窗截断：只渲染"最早日程 ~ 最晚日程（+ 当前时刻）"这一段，避免上下大片空白
//   · 三层堆叠：网格层 / 日程层 / 红线层，色块永不被切割
//   · 贪心分列：列数 = 最大同时重叠数
//   · 全天日程同样用色块展示
// ListItem 内必须用**确定 vp 高度**（不能再用百分比，否则撑不开 → 无法滚动）。
let storage4x4 = new LocalStorage();

/** 时间轴色块（与 common/TimelineUtil.TimelineBlock 结构一致，卡片侧只渲染需要的字段） */
class TBlock {
  eventKey: string = '';
  title: string = '';
  timeText: string = '';
  location: string = '';  // 地点（第 2/3 行显示）
  writable: boolean = true; // false → 标题后挂白框「只读」小标
  color: string = '#007DFF';
  topRatio: number = 0;
  heightRatio: number = 0;
  leftRatio: number = 0;
  widthRatio: number = 1;
  groupIndex: number = 0;
  isNow: boolean = false;
}

/** 全天日程（eventKey 由 CardDataService 写入，用于 ForEach 唯一标识） */
class TAllDay {
  eventKey: string = '';
  title: string = '';
  color: string = '#007DFF';
  isAllDay: boolean = true;
}

/** 列表模式单条日程（解析 listJson） */
/** 多日卡片分组 */
class CardDayGroup4 {
  dateKey: number = 0;
  dateLabel: string = '';
  shortDate: string = '';
  weekday: string = '';
  lunar: string = '';
  isToday: boolean = false;
  count: number = 0;
  items: LItem4[] = [];
}

class LItem4 {
  title: string = '';
  time: string = '';
  endTime: string = '';
  color: string = '#007DFF';
  calName: string = '';
  isNow: boolean = false;
  startMs: number = 0;
}

/** 冲突组：组内**贪心分列**，lanes[i] = 第 i 列（同列互不重叠） */
class TGroup4 {
  startRatio: number = 0;
  endRatio: number = 0;
  laneCount: number = 1;
  blocks: TBlock[] = [];
  lanes: TBlock[][] = [];
}

/** 日程层纵向序列中的一行：空隙 / 冲突组（线都在其它两层） */
class T4Row {
  kind: number = 0; // 0=空隙 1=冲突组
  from: number = 0;
  to: number = 0;
  group: TGroup4 = new TGroup4();
  key: string = '';
}

/** 视窗范围（小时） */
class W4Range {
  s: number = 0;
  e: number = 0;
}

/** 每 1 小时的高度（vp）。整日 24h × 36 = 864vp，远超卡片高度 → 可以滑动 */
const W4_HOUR: number = 36;
/** 全天日程最多显示条数（超出折叠为"还有 N 个"） */
const W4_ALLDAY_MAX: number = 2;
/** 左侧刻度占宽 */
const W4_GUTTER: number = 26;
/** 全天色块单条高度 / 间距 */
const W4_ALLDAY_H: number = 18;

@Entry(storage4x4)
@Component
struct Widget4x4Card {
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';
  @LocalStorageProp('timelineJson') timelineJson: string = '[]';
  @LocalStorageProp('allDayJson') allDayJson: string = '[]';
  @LocalStorageProp('nowRatio') nowRatio: number = 0;
  @LocalStorageProp('nowLabel') nowLabel: string = '';
  @LocalStorageProp('todayCount') todayCount: number = 0;
  @LocalStorageProp('isToday') isToday: boolean = true;
  @LocalStorageProp('dayCount') dayCount: number = 0;
  @LocalStorageProp('listJson') listJson: string = '[]';
  @LocalStorageProp('displayStyle') displayStyle: string = 'timeline';
  @LocalStorageProp('selectedDate') selectedDate: number = 0; // 卡片当前显示日 0 点毫秒
  @LocalStorageProp('cardDays') cardDays: number = 1;         // 1 | 3 | 7
  @LocalStorageProp('daysRangeText') daysRangeText: string = '';
  @LocalStorageProp('rangeCount') rangeCount: number = 0;
  @LocalStorageProp('multiDayJson') multiDayJson: string = '[]';

  private parseBlocks(): TBlock[] {
    try {
      return JSON.parse(this.timelineJson) as TBlock[];
    } catch (err) {
      return [];
    }
  }

  /** 当前时间比例（无效返回 -1） */
  private w4NowR(): number {
    return (this.nowRatio > 0.001 && this.nowRatio < 0.999) ? this.nowRatio : -1;
  }
  private w4IsNowHour(h: number): boolean {
    const r: number = this.w4NowR();
    return r >= 0 && Math.floor(r * 24) === h;
  }

  /** 视窗范围：**8:00~18:00 恒显示**；仅当 8 点前 / 18 点后有日程时才向该侧扩展。
   *  （与 App 内时间轴 TimelineUtil.viewRange 同一口径，避免两处漂移。） */
  private w4Range(): W4Range {
    const rg = new W4Range();
    const bs: TBlock[] = this.parseBlocks();
    let s: number = 8;
    let e: number = 18;
    for (const b of bs) {
      const bh: number = Math.floor(b.topRatio * 24);
      const eh: number = Math.ceil((b.topRatio + b.heightRatio) * 24 - 0.0001);
      if (bh < s) {
        s = bh;
      }
      if (eh > e) {
        e = eh;
      }
    }
    const r: number = this.w4NowR();
    // 只有"今天 + 还有未结束的定时日程"时才把当前小时并入视窗（红线会显示）；
    // 且仅在该侧本来就有日程时才允许继续向外扩（不因当前时刻把 8 点前/18 点后空档重新显示）
    const nh: number = (r >= 0 && !this.w4AllTimedEnded()) ? Math.floor(r * 24) : -1;
    if (nh >= 0 && nh < s && s < 8) {
      s = nh;
    }
    if (nh >= 0 && nh + 1 > e && e > 18) {
      e = nh + 1;
    }
    if (s < 0) {
      s = 0;
    }
    if (e > 24) {
      e = 24;
    }
    if (e <= s) {
      e = s + 1 > 24 ? 24 : s + 1;
    }
    rg.s = s;
    rg.e = e;
    return rg;
  }
  /** 视窗起始小时（取 w4Range 的起点，向下取整） */
  private w4StartHour(): number {
    return this.w4Range().s;
  }
  /** 视窗结束小时（取 w4Range 的终点，向上取整） */
  private w4EndHour(): number {
    return this.w4Range().e;
  }
  /** 视窗跨度（小时） */
  private w4Span(): number {
    return this.w4EndHour() - this.w4StartHour();
  }
  /** 时间轴内容总高（vp）= 跨度 × 每小时高度 */
  private w4ContentH(): number {
    return this.w4Span() * W4_HOUR;
  }
  /** 一段（起止为当日比例）换算成 vp 高度 */
  private w4SpanVp(from: number, to: number): number {
    const v: number = (to - from) * 24 * W4_HOUR;
    return v > 0 ? v : 0;
  }

  /** 全天区高度（vp），没有全天日程时为 0 */
  private w4AllDayH(): number {
    const n: number = this.w4AllDay().length;
    if (n === 0) {
      return 0;
    }
    let h: number = n * W4_ALLDAY_H;
    if (this.w4AllDayRest() > 0) {
      h += 13;
    }
    return h + 4;
  }
  /** ListItem 总高（vp）= 全天区 + 时间轴 */
  private w4ItemH(): number {
    return this.w4AllDayH() + this.w4ContentH();
  }

  /** 由色块重建冲突分组：组内按开始时间升序做**贪心分列**（列数 = 最大同时重叠数） */
  private w4Groups(): TGroup4[] {
    const map: Map<number, TBlock[]> = new Map<number, TBlock[]>();
    for (const b of this.parseBlocks()) {
      const arr: TBlock[] | undefined = map.get(b.groupIndex);
      if (arr === undefined) {
        map.set(b.groupIndex, [b]);
      } else {
        arr.push(b);
      }
    }
    const idxs: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    const out: TGroup4[] = [];
    for (const gi of idxs) {
      const bs: TBlock[] = map.get(gi) ?? [];
      bs.sort((a: TBlock, b: TBlock): number => {
        if (a.topRatio !== b.topRatio) {
          return a.topRatio - b.topRatio;
        }
        return b.heightRatio - a.heightRatio;
      });
      const lanes: TBlock[][] = [];
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
      }
      const g = new TGroup4();
      g.blocks = bs;
      g.lanes = lanes;
      g.laneCount = lanes.length > 0 ? lanes.length : 1;
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
      out.push(g);
    }
    return out;
  }

  /** 日程层纵向序列：空隙 / 冲突组（不含任何"线"） */
  private w4Rows(): T4Row[] {
    const rows: T4Row[] = [];
    const gs: TGroup4[] = this.w4Groups();
    const top: number = this.w4StartHour() / 24;
    const bot: number = this.w4EndHour() / 24;
    let cursor: number = top;
    for (const g of gs) {
      const gsx: number = g.startRatio > top ? g.startRatio : top;
      const gex: number = g.endRatio < bot ? g.endRatio : bot;
      if (gex - gsx <= 0.0002) {
        continue;
      }
      this.w4Push(rows, cursor, gsx, null);
      this.w4Push(rows, gsx, gex, g);
      cursor = gex;
    }
    this.w4Push(rows, cursor, bot, null);
    return rows;
  }
  private w4Push(rows: T4Row[], from: number, to: number, g: TGroup4 | null): void {
    if (to - from <= 0.0002) {
      return;
    }
    const r = new T4Row();
    r.from = from;
    r.to = to;
    if (g === null) {
      r.kind = 0;
      r.key = `g_${rows.length}_${Math.round((to - from) * 100000)}`;
    } else {
      r.kind = 1;
      r.group = g;
      // key 必须绑定"内容"：翻页后行序号不变、只有内容变了；
      // 若只用序号，ArkUI 会认为是同一批元素而不重绘 → 残留上一天的数据
      r.key = `b_${rows.length}_${this.w4GroupKey(g, from, to)}`;
    }
    rows.push(r);
  }

  /** 冲突组的内容签名（时间窗 + 各块 eventKey），供 ForEach key 使用 */
  private w4GroupKey(g: TGroup4, from: number, to: number): string {
    let sig: string = `${Math.round(from * 100000)}_${Math.round(to * 100000)}`;
    for (const b of g.blocks) {
      sig = `${sig}_${b.eventKey}`;
    }
    return sig;
  }

  /** 列内第 index 个色块之前的空隙（vp）= 本块顶 − 上一块底 */
  private w4LanePadVp(g: TGroup4, lane: TBlock[], index: number): number {
    let prevEnd: number = g.startRatio;
    if (index > 0) {
      const p: TBlock = lane[index - 1];
      const pe: number = p.topRatio + p.heightRatio;
      prevEnd = pe > g.startRatio ? pe : g.startRatio;
    }
    return this.w4SpanVp(prevEnd, lane[index].topRatio);
  }
  /** 色块高度（vp） */
  private w4BlockVp(b: TBlock): number {
    return b.heightRatio * 24 * W4_HOUR;
  }
  /** 色块信息行数（标题永远打头）：1=标题+时间+地址同行；2=标题 + 时间·地点；3=标题 / 时间 / 地址 */
  private w4Lines(b: TBlock): number {
    const h: number = this.w4BlockVp(b);
    if (h >= 40 && b.location !== '') {
      return 3;
    }
    if (h >= 26) {
      return 2;
    }
    return 1;
  }
  /** 两行色块的第二行：'09:00 - 10:30 · 地点'（无地点时只剩时间） */
  private w4Meta(b: TBlock): string {
    return b.location !== '' ? `${b.timeText} · ${b.location}` : b.timeText;
  }
  /** 今天定时日程是否已全部结束（最晚结束比例 <= 当前时刻比例）；只剩全天 / 无定时日程也算已结束。
   *  非今天（r<0）返回 false，交由原条件判断（非今天本来就不显示红线）。 */
  private w4AllTimedEnded(): boolean {
    const r: number = this.w4NowR();
    if (r < 0) {
      return false;
    }
    let maxEnd: number = 0;
    for (const b of this.parseBlocks()) {
      const e: number = b.topRatio + b.heightRatio;
      if (e > maxEnd) {
        maxEnd = e;
      }
    }
    return r >= maxEnd - 0.0001;
  }
  /** 红线是否显示（当前时刻落在视窗内 + 今天还有未结束的定时日程） */
  private w4NowVisible(): boolean {
    const r: number = this.w4NowR();
    return r >= 0 && !this.w4AllTimedEnded()
      && r >= this.w4StartHour() / 24 - 0.0001 && r <= this.w4EndHour() / 24 + 0.0001;
  }
  /** 红线距内容顶部的偏移（vp） */
  private w4NowPadVp(): number {
    const v: number = (this.w4NowR() - this.w4StartHour() / 24) * 24 * W4_HOUR;
    return v > 0 ? v : 0;
  }

  private parseAllDay(): TAllDay[] {
    try {
      return JSON.parse(this.allDayJson) as TAllDay[];
    } catch (err) {
      return [];
    }
  }
  /** 卡片空间有限：全天最多显示 W4_ALLDAY_MAX 条 */
  private w4AllDay(): TAllDay[] {
    return this.parseAllDay().slice(0, W4_ALLDAY_MAX);
  }
  private w4AllDayRest(): number {
    const n: number = this.parseAllDay().length - W4_ALLDAY_MAX;
    return n > 0 ? n : 0;
  }

  /** 只渲染视窗内的小时 */
  private hourLabels(): number[] {
    const arr: number[] = [];
    for (let h = this.w4StartHour(); h < this.w4EndHour(); h++) {
      arr.push(h);
    }
    return arr;
  }

  private hourText(h: number): string {
    return h < 10 ? `0${h}` : `${h}`;
  }

  /** 右上角添加按钮：拉起 App 直接进入新建日程页。
   *  ⭐ 无需阻止冒泡：ArkUI 的 `onClick` 是**非冒泡**事件，父子同绑时**子组件优先**，
   *     故点 ＋ 不会连带触发根容器的"打开首页"。 */
  @Builder
  addButton() {
    Button() {
      Text('＋')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
    }
    .width(26)
    .height(26)
    .borderRadius(13)
    .padding(0)
    .backgroundColor('#007DFF')
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { widgetAction: 'add' }
      });
    })
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      // 携带卡片当前显示日（用户可能已翻到其他日期），进入日历时定位到这一天。
      // 必须转成字符串：param 的数值按 int32 传递，13 位毫秒时间戳会溢出成 2147483647（曾导致定位到 1970）
      params: { openDate: `${this.selectedDate}` }
    });
  }

  /** 翻页：交给 FormExtensionAbility.onFormEvent 重新取数并推送（跨天查看） */
  private page(act: string): void {
    postCardAction(this, {
      action: 'message',
      params: { pageAction: act }
    });
  }

  /** 上一天 / 下一天 圆按钮 */
  @Builder
  private pageBtn(label: string, act: string) {
    Button() {
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
    }
    .width(22)
    .height(22)
    .borderRadius(11)
    .padding(0)
    .backgroundColor('#F2F3F5')
    // ⭐ 无需阻止冒泡：onClick 非冒泡、子组件优先 → 点翻页不会连带打开 App
    .onClick(() => this.page(act))
  }

  /** 今天时是"＋"（新建日程）；非今天时是"今"（回到今天） */
  @Builder
  private sideBtn() {
    if (this.isToday) {
      this.addButton()
    } else {
      Button() {
        Text('今')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width(22)
      .height(22)
      .borderRadius(11)
      .padding(0)
      .backgroundColor('#007DFF')
      // ⭐ 无需阻止冒泡：onClick 非冒泡、子组件优先
      .onClick(() => this.page('today'))
    }
  }

  /** 列表模式单条日程（解析 listJson） */
  private parseList(): LItem4[] {
    try {
      return JSON.parse(this.listJson) as LItem4[];
    } catch (err) {
      return [];
    }
  }

  /** 列表模式单条行：左侧日历色条（进行中变红）+ 时间 + 标题 + 所属日历本；不画红线 */
  @Builder
  listRow(item: LItem4, fallbackDateMs: number = 0) {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(item.time === '全天' ? 16 : 38)
        .borderRadius(2)
        .backgroundColor(item.isNow ? '#FF3B30' : item.color)
      if (item.time === '全天') {
        Text(item.title)
          .fontSize(12)
          .fontColor('#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('全天')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor(item.color)
          .borderRadius(6)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
      } else {
        Column({ space: 2 }) {
          Text(item.time)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(item.isNow ? '#FF3B30' : '#333333')
          Text(item.endTime)
            .fontSize(10)
            .fontColor('#999999')
        }
        .width(38)
        .alignItems(HorizontalAlign.Center)
        Text(item.title)
          .fontSize(12)
          .fontColor(item.isNow ? '#FF3B30' : '#1A1A1A')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (item.isNow) {
          Text('● 进行中')
            .fontSize(9)
            .fontColor('#FF3B30')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor('#FFECEA')
        }
      }
      if (item.calName !== '') {
        Text(item.calName)
          .fontSize(9)
          .fontColor(item.color)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '25%' })
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .borderRadius(8)
    .backgroundColor(item.isNow ? '#FFF1F0' : '#F5F7FA')
    .onClick(() => {
      const targetDate = item.startMs > 0 ? item.startMs : (fallbackDateMs > 0 ? fallbackDateMs : this.selectedDate);
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { openDate: `${targetDate}` }
      });
    })
  }

  /** 列表模式主体：空态 / 可滚动的"行"列表（无时间轴、无红线） */
  @Builder
  listBody() {
    if (this.parseList().length === 0) {
      Column({ space: 6 }) {
        Text('📅')
          .fontSize(24)
        Text('暂无日程')
          .fontSize(13)
          .fontColor('#8A8A8A')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List({ space: 4 }) {
        ForEach(this.parseList(), (item: LItem4) => {
          ListItem() {
            this.listRow(item)
          }
          .width('100%')
        }, (item: LItem4) => `${item.time}_${item.title}_${item.color}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .cachedCount(8)
    }
  }

  private parseMultiDays(): CardDayGroup4[] {
    try {
      return JSON.parse(this.multiDayJson) as CardDayGroup4[];
    } catch (err) {
      return [];
    }
  }

  private switchDays(days: number): void {
    postCardAction(this, {
      action: 'message',
      params: { cardDays: days, pageAction: `days_${days}` }
    });
  }

  @Builder
  private rangeBtn(days: number, label: string) {
    Button() {
      Text(label)
        .fontSize(10)
        .fontWeight(this.cardDays === days ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.cardDays === days ? '#FFFFFF' : '#666666')
    }
    .height(20)
    .padding({ left: 5, right: 5, top: 0, bottom: 0 })
    .borderRadius(10)
    .backgroundColor(this.cardDays === days ? '#007DFF' : '#00000000')
    .onClick(() => this.switchDays(days))
  }

  @Builder
  private rangeSwitcher() {
    Row({ space: 1 }) {
      this.rangeBtn(1, '1天')
      this.rangeBtn(3, '3天')
      this.rangeBtn(7, '7天')
    }
    .padding(1)
    .borderRadius(11)
    .backgroundColor('#F2F3F5')
  }

  @Builder
  multiDayBody() {
    if (this.rangeCount === 0) {
      Column({ space: 6 }) {
        Text('📅')
          .fontSize(24)
        Text(this.cardDays === 3 ? '未来3天暂无日程' : '未来7天暂无日程')
          .fontSize(13)
          .fontColor('#8A8A8A')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List({ space: 8 }) {
        ForEach(this.parseMultiDays(), (group: CardDayGroup4) => {
          ListItem() {
            Column({ space: 4 }) {
              Row({ space: 4 }) {
                Text(group.dateLabel)
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(group.isToday ? '#007DFF' : '#1A1A1A')
                Text(group.lunar)
                  .fontSize(9)
                  .fontColor('#8A8A8A')
                Blank()
                Text(group.count === 0 ? '无日程' : `${group.count} 条`)
                  .fontSize(9)
                  .fontColor(group.count === 0 ? '#B0B0B0' : '#8A8A8A')
              }
              .width('100%')
              .padding({ left: 2, right: 2, top: 2, bottom: 2 })

              if (group.count === 0) {
                if (this.cardDays === 3 || group.isToday) {
                  Row() {
                    Text('暂无日程安排')
                      .fontSize(10)
                      .fontColor('#B8B8B8')
                  }
                  .width('100%')
                  .padding({ left: 10, top: 2, bottom: 2 })
                }
              } else {
                Column({ space: 4 }) {
                  ForEach(group.items, (item: LItem4) => {
                    this.listRow(item, group.dateKey)
                  }, (item: LItem4, idx: number) => `m_${group.dateKey}_${idx}_${item.time}_${item.title}`)
                }
                .width('100%')
              }
            }
            .width('100%')
          }
          .width('100%')
        }, (group: CardDayGroup4) => `grp_${group.dateKey}_${group.count}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .cachedCount(10)
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        this.pageBtn('‹', 'prev')
        Column() {
          Text(this.cardDays > 1 ? this.daysRangeText : this.dateMd)
            .fontSize(this.cardDays > 1 ? 11 : 12)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isToday ? '#007DFF' : '#1A1A1A')
            .maxLines(1)
          Text(this.cardDays > 1 ? (this.rangeCount === 0 ? '暂无日程' : `共 ${this.rangeCount} 条`) : this.lunarText)
            .fontSize(9)
            .fontColor('#8A8A8A')
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.rangeSwitcher()
        this.pageBtn('›', 'next')
        this.sideBtn()
      }
      .width('100%')

      Divider().strokeWidth(0.5).color('#E5E5E5')

      if (this.cardDays > 1) {
        this.multiDayBody()
      } else if (this.displayStyle === 'list') {
        this.listBody()
      } else {
      // 卡片不支持 Scroll，但支持 List / ListItem：
      // 把"整日时间轴"作为**一个很高的 ListItem**，超出卡片窗口的部分靠上下滑动查看
      List() {
        ListItem() {
          Column() {
            // 全天 / 跨天：同样用**色块**展示（与列表视图一致），随内容一起滚动
            if (this.w4AllDay().length > 0) {
              Column({ space: 2 }) {
                ForEach(this.w4AllDay(), (a: TAllDay) => {
                  Row({ space: 4 }) {
                    Text(a.isAllDay ? '全天' : '跨天')
                      .fontSize(8)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#26000000')
                      .borderRadius(5)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    Text(a.title)
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#FFFFFF')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .alignItems(VerticalAlign.Center)
                  .width('100%')
                  .height(W4_ALLDAY_H - 2)
                  .padding({ left: 5, right: 5 })
                  .borderRadius(5)
                  .backgroundColor(a.color)
                }, (a: TAllDay, idx: number) => `ad_${idx}_${a.eventKey}`)
                if (this.w4AllDayRest() > 0) {
                  Text(`还有 ${this.w4AllDayRest()} 个全天日程`)
                    .fontSize(9)
                    .fontColor('#8A8A8A')
                    .width('100%')
                    .padding({ left: 2 })
                }
              }
              .width('100%')
              .padding({ bottom: 2 })
            }

            // 时间轴主体：左侧小时刻度（放在 Stack 外，避免被色块盖住）+ 右侧三层堆叠
            Row() {
              Column() {
                ForEach(this.hourLabels(), (h: number) => {
                  Text(this.hourText(h))
                    .fontSize(9)
                    .fontColor(this.w4IsNowHour(h) ? '#FF3B30' : '#9AA0A6')
                    .width(W4_GUTTER)
                    .height(W4_HOUR)
                    .textAlign(TextAlign.End)
                    .padding({ right: 3 })
                    .border({ width: { bottom: 0.5 }, color: { bottom: '#14000000' } })
                }, (h: number) => `h${h}`)
              }
              .width(W4_GUTTER)
              .height(this.w4ContentH())

              Stack() {
                this.w4GridLayer()  // 第 1 层：整点网格线
                this.w4EventLayer() // 第 2 层：日程色块
                this.w4NowLayer()   // 第 3 层：当前时间红线
              }
              .layoutWeight(1)
              .height(this.w4ContentH())
              .alignContent(Alignment.TopStart)
              .border({ width: { left: 0.5 }, color: { left: '#14000000' } })
            }
            .width('100%')
            .height(this.w4ContentH())
            .alignItems(VerticalAlign.Top)
          }
          .width('100%')
          .height(this.w4ItemH())
        }
        .width('100%')
        .height(this.w4ItemH())
      }
      .layoutWeight(1)
      .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    // ⭐ 整卡可点：空白处也能进 App 并定位到当前显示日。
    //   ⚠️ onClick 是**非冒泡**事件且**子组件优先** → 内部的 ‹ › 今 ＋ 按钮不会被这里抢走
    .onClick(() => this.openApp())
  }

  /** 第 1 层：整点网格（每小时一格，格底一条灰线） */
  @Builder
  private w4GridLayer() {
    Column() {
      ForEach(this.hourLabels(), (h: number) => {
        Column()
          .width('100%')
          .height(W4_HOUR)
          .border({ width: { bottom: 0.5 }, color: { bottom: '#14000000' } })
           // 装饰层子节点同样不参与命中测试
      }, (h: number) => `gd_${h}`)
    }
    .width('100%')
    .height('100%')
     // 装饰层：不参与命中测试，触碰事件穿透到下层色块
  }

  /** 第 2 层：日程色块（冲突组分行 + 组内 lane 分列） */
  @Builder
  private w4EventLayer() {
    Column() {
      ForEach(this.w4Rows(), (r: T4Row) => {
        if (r.kind === 1) {
          Row() {
            ForEach(r.group.lanes, (lane: TBlock[], li: number) => {
              Column() {
                ForEach(lane, (b: TBlock, index: number) => {
                  Blank().height(this.w4LanePadVp(r.group, lane, index))
                  Column({ space: 1 }) {
                    if (this.w4Lines(b) === 1) {
                      // 一行：标题 · [只读] · 时间 · 地址（时间用完整起止，宽度不够自然省略；
                      // 让位顺序：地址先没 → 时间省略 → 标题只保 50%）
                      Row({ space: 3 }) {
                        Text(b.title)
                          .fontSize(9)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: '50%' })
                          .lineHeight(11)
                        if (!b.writable) {
                          Text('只读')
                            .fontSize(8)
                            .fontColor('#FFFFFF')
                            .border({ width: 0.5, color: '#FFFFFF' })
                            .borderRadius(3)
                            .padding({ left: 3, right: 3, top: 0, bottom: 0 })
                            .maxLines(1)
                        }
                        Text(b.timeText)
                          .fontSize(8)
                          .fontColor('#E6FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: '56%' })
                          .lineHeight(11)
                        if (b.location !== '') {
                          Text(b.location)
                            .fontSize(8)
                            .fontColor('#B3FFFFFF')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .lineHeight(11)
                            .layoutWeight(1)
                        }
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                    } else {
                      // 第一行：标题 · [只读]
                      Row({ space: 3 }) {
                        Text(b.title)
                          .fontSize(10)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .constraintSize({ maxWidth: '70%' })
                        if (!b.writable) {
                          Text('只读')
                            .fontSize(8)
                            .fontColor('#FFFFFF')
                            .border({ width: 0.5, color: '#FFFFFF' })
                            .borderRadius(3)
                            .padding({ left: 3, right: 3, top: 0, bottom: 0 })
                            .maxLines(1)
                        }
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                      if (this.w4Lines(b) >= 3) {
                        Text(b.timeText)
                          .fontSize(8)
                          .fontColor('#E6FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                        Text(b.location)
                          .fontSize(8)
                          .fontColor('#B3FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      } else {
                        Text(this.w4Meta(b))
                          .fontSize(8)
                          .fontColor('#E6FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      }
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .padding({ left: 4, right: 2, top: 1, bottom: 1 })
                  .borderRadius(4)
                  .backgroundColor(b.color)
                  .opacity(b.isNow ? 1 : 0.92)
                  .clip(true)
                  .width('100%')
                  .height(this.w4BlockVp(b))
                  .constraintSize({ minHeight: 14 })
                }, (b: TBlock) => `b_${r.key}_${b.eventKey}`)
              }
              .layoutWeight(1)
              .height('100%')
              .padding({ right: 2 })
              .clip(true)
            }, (lane: TBlock[], li: number) => `ln_${r.key}_${li}`)
          }
          .width('100%')
          .height(this.w4SpanVp(r.from, r.to))
          .alignItems(VerticalAlign.Top)
        } else {
          Blank().height(this.w4SpanVp(r.from, r.to))
        }
      }, (r: T4Row) => r.key)
    }
    .width('100%')
    .height('100%')
  }

  /** 第 3 层：当前时间红线（浮在最上层） */
  @Builder
  private w4NowLayer() {
    Column() {
      if (this.w4NowVisible()) {
        Blank().height(this.w4NowPadVp()) // 占位块：不拦截点击
        Row() {
          Column()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor('#FF3B30')
          Column()
            .height(2)
            .layoutWeight(1)
            .backgroundColor('#FF3B30')
            .borderRadius(1)
        }
        .width('100%')
         // 红线本身也不拦截点击，穿透到色块层
      }
    }
    .width('100%')
    .height('100%')
     // 装饰层：整层不参与命中测试，触碰事件穿透到下层色块
  }
}
