// entry/src/main/ets/pages/widget/Widget6x4.ets
// 6x4 服务卡片：日期 + 农历 + 从今天开始的日程（时间轴样式，比 4x4 显示更多）
let storage6x4 = new LocalStorage();

class CardItem6x4 {
  title: string = '';
  time: string = '';
  endTime: string = '';
  date: string = '';
  showDate: boolean = false;
  calName: string = '';
  color: string = '#007DFF';
}

@Entry(storage6x4)
@Component
struct Widget6x4Card {
  @LocalStorageProp('eventsJson') eventsJson: string = '[]';
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';

  private parseItems(): CardItem6x4[] {
    try {
      return JSON.parse(this.eventsJson) as CardItem6x4[];
    } catch (err) {
      return [];
    }
  }

  /** 全天事件行：圆角矩形 + 左侧日历色竖条 + 标题 + “全天”标记（无时间轴） */
  @Builder
  buildAllDayRow(item: CardItem6x4) {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(16)
        .borderRadius(2)
        .backgroundColor(item.color)
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
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .borderRadius(8)
    .backgroundColor('#F5F7FA')
  }

  /** 有时间事件行（时间轴）：圆角矩形 + 左色竖条 + 开始时间(上)-竖线-结束时间(下) + 标题 */
  @Builder
  buildTimedRow(item: CardItem6x4) {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(38)
        .borderRadius(2)
        .backgroundColor(item.color)
      // 时间列：开始时间在上、结束时间在下、中间竖线连接
      Column({ space: 2 }) {
        Text(item.time)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
        Column()
          .width(1.5)
          .layoutWeight(1)
          .backgroundColor('#D8D8D8')
          .borderRadius(1)
        Text(item.endTime)
          .fontSize(10)
          .fontColor('#999999')
      }
      .width(38)
      .alignItems(HorizontalAlign.Center)
      .height(38)
      Text(item.title)
        .fontSize(12)
        .fontColor('#1A1A1A')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
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
    .backgroundColor('#F5F7FA')
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.dateText)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
        Text(this.lunarText)
          .fontSize(12)
          .fontColor('#8A8A8A')
        Blank()
        Text('同步日历')
          .fontSize(10)
          .fontColor('#B0B0B0')
      }
      .width('100%')

      Divider().strokeWidth(0.5).color('#E5E5E5')

      if (this.parseItems().length === 0) {
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
          ForEach(this.parseItems(), (item: CardItem6x4, idx: number) => {
            ListItem() {
              Column({ space: 3 }) {
                if (item.showDate) {
                  Text(item.date)
                    .fontSize(10)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#666666')
                    .width('100%')
                }
                if (item.time === '全天') {
                  this.buildAllDayRow(item)
                } else {
                  this.buildTimedRow(item)
                }
              }
              .width('100%')
            }
          }, (item: CardItem6x4, idx: number) => `${idx}_${item.title}_${item.time}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .cachedCount(12)
      }
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {}
      });
    })
  }
}
