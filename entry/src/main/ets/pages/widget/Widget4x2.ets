// entry/src/main/ets/pages/widget/Widget4x2.ets
// 2x4 服务卡片：2x2 的横向扩展。左侧 = 日期/星期/农历 + 今日日程条数（与 2x2 一致）；
// 右侧 = **当前时间之后最近的两条**日程（不含全天/跨天，不显示"进行中"等字样，不显示日历本名）；
// 整卡点击进入 App，右上角 ＋ 直接新建日程
let storage2x4 = new LocalStorage();

/** 与 eventsJson 同结构的卡片单条日程（本卡片只用到标题/时间/日历色/进行中标记） */
class CardItem2x4 {
  title: string = '';
  time: string = '';
  endTime: string = '';
  calName: string = '';
  color: string = '#007DFF';
  isNow: boolean = false;
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
  /** 卡片当前显示的那一天 0 点毫秒 —— 点卡片进 App 时定位到这一天 */
  @LocalStorageProp('selectedDate') selectedDate: number = 0;

  /** 右侧最多渲染 2 条（数据侧已裁剪，这里再兜底截断） */
  private parseOngoing(): CardItem2x4[] {
    try {
      const all: CardItem2x4[] = JSON.parse(this.ongoingJson) as CardItem2x4[];
      return all.slice(0, 2);
    } catch (err) {
      return [];
    }
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

  /** 右侧单条：左色竖条 + 起止时间 + 标题。
   *  不显示"进行中 / 即将开始"字样，也不显示日历本名 */
  @Builder
  ongoingRow(item: CardItem2x4) {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(40)
        .borderRadius(2)
        .backgroundColor(item.color)
      Column({ space: 2 }) {
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
      .width(36)
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
  }

  /** 右侧空态：今日无日程 / 日程已全部结束 */
  @Builder
  emptyHint() {
    Column() {
      Text(this.todayCount === 0 ? '今日暂无日程' : '今日日程已结束')
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
      // ===== 左半：与 2x2 一致（日期 / 星期 + 农历 / 今日条数大数字） =====
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
          Text(`${this.todayCount}`)
            .fontSize(38)
            .fontWeight(FontWeight.Bold)
            .fontColor('#007DFF')
          Column({ space: 2 }) {
            Row({ space: 4 }) {
              Text('今日日程')
                .fontSize(11)
                .fontColor('#1A1A1A')
                .maxLines(1)
            }
            Text(this.todayCount === 0 ? '点击添加' : '点击查看')
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

      // ===== 右半：当前时间之后最近的两条日程（不滚动）=====
      Column() {
        if (this.parseOngoing().length === 0) {
          this.emptyHint()
        } else {
          Column({ space: 6 }) {
            ForEach(this.parseOngoing(), (item: CardItem2x4, idx: number) => {
              this.ongoingRow(item)
            }, (item: CardItem2x4, idx: number) => `${idx}_${item.title}_${item.time}`)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
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
