// entry/src/main/ets/pages/widget/TodoWidget4x4.ets
// 4x4 待办服务卡片：顶部标题栏（未完成数 / 今日到期）+ 可滚动待办列表。
// 每条待办左侧为圆形勾选框，点击即完成并推送回服务器。
let storageTodo4x4 = new LocalStorage();

/** 待办卡片单条（解析 todoListJson） */
class TodoItem4x4 {
  id: number = 0;
  title: string = '';
  dueText: string = '';
  color: string = '#007DFF';
  calName: string = '';
  completed: boolean = false;
}

@Entry(storageTodo4x4)
@Component
struct TodoWidget4x4Card {
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('todoCount') todoCount: number = 0;
  @LocalStorageProp('todoTodayCount') todoTodayCount: number = 0;
  @LocalStorageProp('todoListJson') todoListJson: string = '[]';

  private parseTodos(): TodoItem4x4[] {
    try {
      return JSON.parse(this.todoListJson) as TodoItem4x4[];
    } catch (err) {
      return [];
    }
  }

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

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { widgetAction: 'openTodo' }
    });
  }

  /** 点击勾选框 → 交给 FormExtension 完成（带 localId） */
  private checkTodo(id: number): void {
    postCardAction(this, {
      action: 'message',
      params: { todoCheck: `${id}` }
    });
  }

  /** 圆形勾选框（空心圆，点击后由数据刷新从列表中消失） */
  @Builder
  checkbox(id: number) {
    // ⚠️ 不用 Circle().stroke() —— 那是 SDK 26 的 API，本工程 compatibleSdkVersion 为
    //    6.1.1(24)，真机上 stroke 不生效会导致圆圈不可见。
    //    改用 border + 50% 圆角，视觉一致且从 API 7 起就支持。
    Column()
      .width(20)
      .height(20)
      .borderRadius(10)
      .border({ width: 1.5, color: '#B0B0B0' })
      .backgroundColor(Color.Transparent)
      .onClick(() => this.checkTodo(id))
  }

  /** 单条待办：勾选框 + 左色竖条 + 标题/截止时间 + 日历本名 */
  @Builder
  todoRow(item: TodoItem4x4) {
    Row({ space: 8 }) {
      this.checkbox(item.id)
      Column()
        .width(3)
        .height(32)
        .borderRadius(2)
        .backgroundColor(item.color)
      Column({ space: 3 }) {
        Text(item.title)
          .fontSize(13)
          .fontColor('#1A1A1A')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(item.dueText)
            .fontSize(10)
            .fontColor(item.dueText.indexOf('逾期') >= 0 ? '#FF3B30' : '#8A8A8A')
            .maxLines(1)
          if (item.calName !== '') {
            Text(item.calName)
              .fontSize(10)
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
    .padding({ left: 4, right: 10, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor('#F5F7FA')
  }

  /** 顶部标题栏 */
  @Builder
  headerBar() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text('待办')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(`${this.todoCount}`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#6A4C93')
            .borderRadius(9)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        }
        Text(this.todoTodayCount > 0
          ? `${this.dateMd} ${this.weekday} · 今日到期 ${this.todoTodayCount} 项`
          : `${this.dateMd} ${this.weekday} · 今日无到期`)
          .fontSize(10)
          .fontColor(this.todoTodayCount > 0 ? '#FF9500' : '#8A8A8A')
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.addButton()
    }
    .width('100%')
  }

  /** 空态 */
  @Builder
  emptyState() {
    Column({ space: 8 }) {
      Text('✓')
        .fontSize(30)
        .fontColor('#C7C7CC')
      Text(this.todoCount === 0 ? '所有待办都完成了' : '暂无待办')
        .fontSize(13)
        .fontColor('#8A8A8A')
      Text('点右上角 ＋ 新建')
        .fontSize(10)
        .fontColor('#B0B0B0')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column({ space: 8 }) {
      this.headerBar()

      Divider()
        .strokeWidth(0.5)
        .color('#E5E5E5')

      if (this.parseTodos().length === 0) {
        this.emptyState()
      } else {
        // List 虚拟化：待办多时滑动流畅
        List({ space: 4 }) {
          ForEach(this.parseTodos(), (item: TodoItem4x4, idx: number) => {
            ListItem() {
              this.todoRow(item)
            }
          }, (item: TodoItem4x4, idx: number) => `t${item.id}_${idx}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}