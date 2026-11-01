// entry/src/main/ets/pages/widget/Widget4x2.ets
// 2x4 服务卡片：2x2 的横向扩展。左侧 = 日期/星期/农历 + 日程条数（支持1天/3天/7天切换）；
// 右侧 = 当前时刻起最近的两条日程（带日期标识，支持展示未来3天、7天的日程）；
// 整卡点击进入 App，右上角 ＋ 直接新建日程
let storage2x4 = new LocalStorage();

/** 与 eventsJson 同结构的卡片单条日程 */
class CardItem2x4 {
  title: string = '';
  time: string = '';
  endTime: string = '';
  calName: string = '';
  color: string = '#007DFF';
  isNow: boolean = false;
  dateTag: string = ''; // '今天' | '明天' | '后天' | '10/31'
  startMs: number = 0;
}

@Entry(storage2x4)
@Component
struct Widget4x2Card {
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';
  @LocalStorageProp('todayCount') todayCount: number = 0;
  @LocalStorageProp('ongoingJson') ongoingJson: string = '[]';
  @LocalStorageProp('cardDays') cardDays: number = 1;
  @LocalStorageProp('rangeCount') rangeCount: number = 0;
  /** 卡片当前显示的那一天 0 点毫秒 —— 点卡片进 App 时定位到这一天 */
  @LocalStorageProp('selectedDate') selectedDate: number = 0;

  /** 右侧最多渲染 2 条（数据侧已裁剪，这里再兜底截断） */
  private parseOngoing(): CardItem2x4[] {
    try {
      return JSON.parse(this.ongoingJson) as CardItem2x4[];
    } catch (err) {
      return [];
    }
  }

  /** 循环切换天数：1天 -> 3天 -> 7天 -> 1天 */
  private cycleDays(): void {
    const nextDays: number = this.cardDays === 1 ? 3 : (this.cardDays === 3 ? 7 : 1);
    postCardAction(this, {
      action: 'message',
      params: { cardDays: nextDays, pageAction: `days_${nextDays}` }
    });
  }

  /** 右上角添加按钮：拉起 App 直接进入新建日程页（兄弟节点布局，点击不会冒泡到左侧日期区） */
  @Builder
  addButton() {
    Button() {
      Text('＋')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
    }
    .width(30)
    .height(30)
    .borderRadius(15)
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

  /** 打开 App 并**定位到卡片当前显示的那一天**（用户可能已翻到其他日期） */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { openDate: `${this.selectedDate}` }
    });
  }

  /** 右侧单条：左色竖条 + 日期标签/起止时间 + 标题。 */
  @Builder
  ongoingRow(item: CardItem2x4) {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(40)
        .borderRadius(2)
        .backgroundColor(item.color)
      Column({ space: 2 }) {
        if (item.dateTag !== '') {
          Text(item.dateTag)
            .fontSize(8.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(item.dateTag === '今天' ? '#007DFF' : '#FF9500')
            .backgroundColor(item.dateTag === '今天' ? '#EBF4FF' : '#FFF5E6')
            .borderRadius(3)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .maxLines(1)
        }
        Text(item.time)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .maxLines(1)
        if (item.endTime !== '' && item.endTime !== '全天') {
          Text(item.endTime)
            .fontSize(9)
            .fontColor('#999999')
            .maxLines(1)
        }
      }
      .width(38)
      .alignItems(HorizontalAlign.Start)
      Text(item.title)
        .fontSize(13)
        .fontColor('#1A1A1A')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .borderRadius(8)
    .backgroundColor('#F5F7FA')
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { openDate: `${item.startMs > 0 ? item.startMs : this.selectedDate}` }
      });
    })
  }

  /** 右侧空态：日程为空或已结束 */
  @Builder
  emptyHint() {
    Column() {
      Text((this.cardDays > 1 ? this.rangeCount : this.todayCount) === 0
        ? (this.cardDays === 7 ? '未来7天暂无日程' : (this.cardDays === 3 ? '未来3天暂无日程' : '今日暂无日程'))
        : (this.cardDays > 1 ? '近期日程已结束' : '今日日程已结束'))
        .fontSize(12)
        .fontColor('#8A8A8A')
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Row({ space: 10 }) {
      // ===== 左半：日期 / 星期 + 农历 / 条数大数字（支持1天/3天/7天） =====
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Column({ space: 2 }) {
            Text(this.dateMd === '' ? this.dateText : this.dateMd)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.weekday === '' ? '' : this.weekday + '  '}${this.lunarText}`)
              .fontSize(10)
              .fontColor('#8A8A8A')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          this.addButton()
        }
        .width('100%')

        Divider()
          .strokeWidth(0.5)
          .color('#E5E5E5')

        Row({ space: 6 }) {
          Text(`${this.cardDays > 1 ? this.rangeCount : this.todayCount}`)
            .fontSize(38)
            .fontWeight(FontWeight.Bold)
            .fontColor('#007DFF')
          Column({ space: 2 }) {
            Row({ space: 4 }) {
              Text(this.cardDays === 7 ? '未来7天' : (this.cardDays === 3 ? '未来3天' : '今日日程'))
                .fontSize(11)
                .fontColor('#1A1A1A')
                .maxLines(1)
              Button() {
                Text(this.cardDays === 7 ? '7天' : (this.cardDays === 3 ? '3天' : '1天'))
                  .fontSize(9)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#007DFF')
              }
              .height(16)
              .padding({ left: 4, right: 4 })
              .borderRadius(8)
              .backgroundColor('#EBF4FF')
              .onClick(() => this.cycleDays())
            }
            Text((this.cardDays > 1 ? this.rangeCount : this.todayCount) === 0 ? '点击添加' : '点击查看')
              .fontSize(9)
              .fontColor('#8A8A8A')
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .height('100%')

      Divider()
        .vertical(true)
        .height('92%')
        .strokeWidth(0.5)
        .color('#E5E5E5')

      // ===== 右半：当前时间之后日程（支持向下滑动查看）=====
      Column() {
        if (this.parseOngoing().length === 0) {
          this.emptyHint()
        } else {
          List({ space: 6 }) {
            ForEach(this.parseOngoing(), (item: CardItem2x4, idx: number) => {
              ListItem() {
                this.ongoingRow(item)
              }
            }, (item: CardItem2x4, idx: number) => `${idx}_${item.title}_${item.time}_${item.dateTag}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    // ⭐ 整卡可点：左右空白处也能进 App 并定位到当前显示日
    .onClick(() => this.openApp())
  }
}
