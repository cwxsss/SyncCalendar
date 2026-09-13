// entry/src/main/ets/pages/widget/Widget2x2.ets
// 2x2 服务卡片：日期 + 农历 + 下一条日程
let storage2x2 = new LocalStorage();

class CardItem2x2 {
  title: string = '';
  time: string = '';
  endTime: string = '';
  date: string = '';
  showDate: boolean = false;
  calName: string = '';
  color: string = '#007DFF';
}

@Entry(storage2x2)
@Component
struct Widget2x2Card {
  @LocalStorageProp('eventsJson') eventsJson: string = '[]';
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';

  private parseItems(): CardItem2x2[] {
    try {
      return JSON.parse(this.eventsJson) as CardItem2x2[];
    } catch (err) {
      return [];
    }
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.dateText)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .maxLines(1)
        Blank()
        Text(this.lunarText)
          .fontSize(11)
          .fontColor('#8A8A8A')
      }
      .width('100%')

      Divider()
        .strokeWidth(0.5)
        .color('#E5E5E5')

      if (this.parseItems().length === 0) {
        Column({ space: 4 }) {
          Text('暂无日程')
            .fontSize(13)
            .fontColor('#8A8A8A')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Circle().width(6).height(6).fill(this.parseItems()[0].color)
            Text(this.parseItems()[0].title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1A1A1A')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.parseItems()[0].calName !== '') {
              Text(this.parseItems()[0].calName)
                .fontSize(9)
                .fontColor(this.parseItems()[0].color)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: '30%' })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Blank()
          Row({ space: 6 }) {
            Text(this.parseItems()[0].date)
              .fontSize(10)
              .fontColor('#8A8A8A')
            Text(this.parseItems()[0].time === '全天'
              ? '全天'
              : `${this.parseItems()[0].time} - ${this.parseItems()[0].endTime}`)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#007DFF')
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
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
