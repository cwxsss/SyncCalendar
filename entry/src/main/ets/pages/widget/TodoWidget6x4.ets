// entry/src/main/ets/pages/widget/TodoWidget6x4.ets
// 6x4 待办服务卡片：4x4 的横向扩展。左侧 = 统计概览，右侧 = 可滚动的待办列表（更多条目）。
// 每条待办左侧圆形勾选框，点击即完成并推送回服务器。
let storageTodo6x4 = new LocalStorage();

/** 待办卡片单条（解析 todoListJson） */
class TodoItem6x4 {
  id: number = 0;
  title: string = '';
  dueText: string = '';
  /** 副行：截止时间 · 日历本 */
  subText: string = '';
  color: string = '#007DFF';
  calName: string = '';
  completed: boolean = false;
}

@Entry(storageTodo6x4)
@Component
struct TodoWidget6x4Card {
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('todoCount') todoCount: number = 0;
  @LocalStorageProp('todoTodayCount') todoTodayCount: number = 0;
  @LocalStorageProp('todoListJson') todoListJson: string = '[]';

  private parseTodos(): TodoItem6x4[] {
    try {
      return JSON.parse(this.todoListJson) as TodoItem6x4[];
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

  private checkTodo(id: number): void {
    postCardAction(this, {
      action: 'message',
      params: { todoCheck: `${id}` }
    });
  }

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
      .width(20)
      .height(20)
      .onClick(() => this.checkTodo(id))
  }

  /**
   * 单条待办：与 App 内 Index.todoRow 同款结构 ——
   *   圆圈（颜色跟随日历本）+ 标题 + 副行「截止时间 · 日历本」
   *
   * ⚠️ 未完成=空心环、已完成=实心+✓，这套语义与 App 内一致；
   *    卡片上只显示未完成，所以这里主要是空心环。
   * ⚠️ 4×4 与 6×4 的 todoRow 必须**完全一致**（用户要求），改一处要同步另一处。
   */
  @Builder
  todoRow(item: TodoItem6x4) {
    Row({ space: 8 }) {
      // 勾选圈：颜色用日历本色（与 App 内一致），点击即完成
      Row() {
        Text('')
          .width(18)
          .height(18)
          .borderRadius(9)
          .border({ width: 2, color: item.color })
      }
      .padding({ right: 2 })
      .onClick(() => {
        this.checkTodo(item.id);
      })

      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(13)
          .fontColor('#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.subText)
          .fontSize(10)
          .fontColor('#8A8A8A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 6, right: 8, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor('#F5F7FA')
  }

  @Builder
  headerBar() {
    Row({ space: 8 }) {
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
        .layoutWeight(1)
      this.addButton()
    }
    .width('100%')
  }

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
        List({ space: 4 }) {
          ForEach(this.parseTodos(), (item: TodoItem6x4, idx: number) => {
            ListItem() {
              this.todoRow(item)
            }
          }, (item: TodoItem6x4, idx: number) => `t${item.id}_${idx}`)
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