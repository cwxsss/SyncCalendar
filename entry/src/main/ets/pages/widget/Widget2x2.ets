// entry/src/main/ets/pages/widget/Widget2x2.ets
// 2x2 服务卡片：突出今天的日期（年月日 / 星期 / 农历）+ 今日日程条数；点击卡片打开 App，右上角 ＋ 直接添加日程
let storage2x2 = new LocalStorage();

@Entry(storage2x2)
@Component
struct Widget2x2Card {
  @LocalStorageProp('eventsJson') eventsJson: string = '[]';
  @LocalStorageProp('dateText') dateText: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('todayCount') todayCount: number = 0;

  /** 右上角添加按钮：拉起 App 直接进入新建日程页（阻止冒泡，避免同时打开 App 首页） */
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

  /** 卡片"打开 App"：点击日期区或今日日程数区域触发；添加按钮是 header 行的兄弟节点，其点击不会冒泡到这里 */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {}
    });
  }

  build() {
    Column({ space: 6 }) {
      // 顶部：大日期 + 添加按钮
      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Text(this.dateMd === '' ? this.dateText : this.dateMd)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .maxLines(1)
          Text(`${this.weekday === '' ? '' : this.weekday + '  '}${this.lunarText}`)
            .fontSize(11)
            .fontColor('#8A8A8A')
            .maxLines(1)
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

      // 今日日程条数（占据剩余空间，垂直居中）
      Row({ space: 8 }) {
        Text(`${this.todayCount}`)
          .fontSize(40)
          .fontWeight(FontWeight.Bold)
          .fontColor('#007DFF')
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Text('今日日程')
              .fontSize(12)
              .fontColor('#1A1A1A')
          }
          Text(this.todayCount === 0 ? '点击添加' : '点击查看')
            .fontSize(10)
            .fontColor('#8A8A8A')
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.openApp())
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}
