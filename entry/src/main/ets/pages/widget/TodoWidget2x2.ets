// entry/src/main/ets/pages/widget/TodoWidget2x2.ets
// 2x2 待办服务卡片：突出未完成待办总数 + 今日到期提示。
// 本卡片**不展示待办列表**，因此没有打勾交互；点击整卡进入 App 的待办页。
let storageTodo2x2 = new LocalStorage();

@Entry(storageTodo2x2)
@Component
struct TodoWidget2x2Card {
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';
  @LocalStorageProp('todoCount') todoCount: number = 0;
  @LocalStorageProp('todoTodayCount') todoTodayCount: number = 0;

  /** 右上角添加按钮：拉起 App 直接进入新建待办页 */
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
    .backgroundColor('#6A4C93')
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { widgetAction: 'addTodo' }
      });
    })
  }

  /** 打开 App 并进入待办 Tab */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { widgetAction: 'openTodo' }
    });
  }

  build() {
    Column({ space: 6 }) {
      // 顶部：日期 + 添加按钮
      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Text(this.dateMd)
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

        this.addButton()
      }
      .width('100%')

      Divider()
        .strokeWidth(0.5)
        .color('#E5E5E5')

      // 未完成待办大数字
      Row({ space: 8 }) {
        Text(`${this.todoCount}`)
          .fontSize(40)
          .fontWeight(FontWeight.Bold)
          .fontColor('#6A4C93')
        Column({ space: 2 }) {
          Text('待办未完成')
            .fontSize(12)
            .fontColor('#1A1A1A')
            .maxLines(1)
          // 今日到期优先提示，没有则给操作引导
          Text(this.todoTodayCount > 0 ? `今日到期 ${this.todoTodayCount} 项`
            : (this.todoCount === 0 ? '点击添加' : '今日无到期'))
            .fontSize(10)
            .fontColor(this.todoTodayCount > 0 ? '#FF9500' : '#8A8A8A')
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .onClick(() => this.openApp())
  }
}