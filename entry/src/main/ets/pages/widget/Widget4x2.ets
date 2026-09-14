// entry/src/main/ets/pages/widget/Widget4x2.ets
// 2x4 服务卡片：2x2 的横向扩展。左侧 = 日期/星期/农历 + 今日日程条数（与 2x2 一致）；
// 右侧 = 当前正在进行（或下一个）的 1~3 条日程，不做滚动；整卡点击进入 App，右上角 ＋ 直接新建日程
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
  @LocalStorageProp('ongoingCount') ongoingCount: number = 0;
  @LocalStorageProp('ongoingJson') ongoingJson: string = '[]';

  /** 右侧最多渲染 3 条（数据侧已裁剪，这里再兜底截断） */
  private parseOngoing(): CardItem2x4[] {
    try {
      const all: CardItem2x4[] = JSON.parse(this.ongoingJson) as CardItem2x4[];
      return all.slice(0, 3);
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

  /** 卡片"打开 App"：点击左侧日期区、今日条数区、右侧日程区触发；添加按钮是 header 行兄弟节点，不冒泡 */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {}
    });
  }

  /** 右侧"正在进行 / 下一个"单条：左色竖条 + 时间列 + 标题 + 日历本名；进行中用红色高亮 */
  @Builder
  ongoingRow(item: CardItem2x4) {
    Row({ space: 7 }) {
      Column()
        .width(3)
        .height(34)
        .borderRadius(2)
        .backgroundColor(item.isNow ? '#FF3B30' : item.color)
      Column({ space: 2 }) {
        Text(item.time)
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(item.isNow ? '#FF3B30' : '#333333')
          .maxLines(1)
        if (item.endTime !== '' && item.endTime !== '全天') {
          Text(item.endTime)
            .fontSize(9)
            .fontColor('#999999')
            .maxLines(1)
        }
      }
      .width(34)
      .alignItems(HorizontalAlign.Start)
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(12)
          .fontWeight(item.isNow ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(item.isNow ? '#FF3B30' : '#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 4 }) {
          if (item.isNow) {
            Text('● 进行中')
              .fontSize(8)
              .fontColor('#FF3B30')
              .padding({ left: 4, right: 4, top: 0, bottom: 0 })
              .borderRadius(4)
              .backgroundColor('#FFECEA')
          } else {
            Text('即将开始')
              .fontSize(8)
              .fontColor('#8A8A8A')
              .padding({ left: 4, right: 4, top: 0, bottom: 0 })
              .borderRadius(4)
              .backgroundColor('#F0F1F3')
          }
          if (item.calName !== '') {
            Text(item.calName)
              .fontSize(8)
              .fontColor(item.color)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '55%' })
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 7, right: 7, top: 4, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(item.isNow ? '#FFF5F4' : '#F5F7FA')
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
    .onClick(() => this.openApp())
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
          .onClick(() => this.openApp())

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
              if (this.ongoingCount > 0) {
                Column()
                  .width(7)
                  .height(7)
                  .borderRadius(4)
                  .backgroundColor('#FF3B30')
              }
              Text(this.ongoingCount > 0 ? `进行中 ${this.ongoingCount}` : '今日日程')
                .fontSize(11)
                .fontColor(this.ongoingCount > 0 ? '#FF3B30' : '#1A1A1A')
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
        .onClick(() => this.openApp())
      }
      .layoutWeight(1)
      .height('100%')

      Divider()
        .vertical(true)
        .height('92%')
        .strokeWidth(0.5)
        .color('#E5E5E5')

      // ===== 右半：正在进行 / 下一个（不滚动，最多 3 条）=====
      Column() {
        if (this.parseOngoing().length === 0) {
          this.emptyHint()
        } else {
          Column({ space: 5 }) {
            ForEach(this.parseOngoing(), (item: CardItem2x4, idx: number) => {
              this.ongoingRow(item)
            }, (item: CardItem2x4, idx: number) => `${idx}_${item.title}_${item.time}`)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .onClick(() => this.openApp())
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
  }
}
