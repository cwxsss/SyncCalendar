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

  /** 视窗范围：最早日程 ~ 最晚日程结束（今天再并入当前时刻）。
   *  不做"最大跨度截断" —— 现在可以滑动了，没必要砍掉日程。 */
  private w4Range(): W4Range {
    const rg = new W4Range();
    const bs: TBlock[] = this.parseBlocks();
    let s: number = -1;
    let e: number = -1;
    for (const b of bs) {
      const bh: number = Math.floor(b.topRatio * 24);
      const eh: number = Math.ceil((b.topRatio + b.heightRatio) * 24 - 0.0001);
      if (s < 0 || bh < s) {
        s = bh;
      }
      if (e < 0 || eh > e) {
        e = eh;
      }
    }
    const r: number = this.w4NowR();
    // 只有"今天 + 还有未结束的定时日程"时才把当前小时并入视窗（红线会显示）；
    // 定时日程已全部结束 → 不并入 → 时间刻度直接截断到最晚日程
    const nh: number = (r >= 0 && !this.w4AllTimedEnded()) ? Math.floor(r * 24) : -1;
    if (s < 0) {
      s = nh >= 0 ? nh : 8;
    }
    if (e < 0) {
      e = nh >= 0 ? nh + 1 : 20;
    }
    if (nh >= 0) {
      if (nh < s) {
        s = nh;
      }
      if (nh + 1 > e) {
        e = nh + 1;
      }
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

  /** 右上角添加按钮：拉起 App 直接进入新建日程页（兄弟节点布局，不冒泡到其它点击区） */
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
      params: {}
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
      .onClick(() => this.page('today'))
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        this.pageBtn('‹', 'prev')
        Column() {
          Text(this.dateMd)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isToday ? '#007DFF' : '#1A1A1A')
            .maxLines(1)
          Text(this.lunarText)
            .fontSize(9)
            .fontColor('#8A8A8A')
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => this.openApp())
        this.pageBtn('›', 'next')
        this.sideBtn()
      }
      .width('100%')

      Divider().strokeWidth(0.5).color('#E5E5E5')

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
                  .onClick(() => this.openApp())
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
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
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
          .hitTestBehavior(HitTestMode.None) // 装饰层子节点同样不参与命中测试
      }, (h: number) => `gd_${h}`)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None) // 装饰层：不参与命中测试，触碰事件穿透到下层色块
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
                  .onClick(() => this.openApp())
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
        Blank().height(this.w4NowPadVp()).hitTestBehavior(HitTestMode.None) // 占位块：不拦截点击
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
        .hitTestBehavior(HitTestMode.None) // 红线本身也不拦截点击，穿透到色块层
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None) // 装饰层：整层不参与命中测试，触碰事件穿透到下层色块
  }
}
