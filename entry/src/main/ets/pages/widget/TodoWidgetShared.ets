// entry/src/main/ets/pages/widget/TodoWidgetShared.ets
// 待办服务卡片共享组件：统一 4x4 与 6x4 待办卡片的渲染、缓存解析与交互逻辑

/** 待办卡片单条（解析 todoListJson） */
export class TodoCardItem {
  id: number = 0;
  title: string = '';
  dueText: string = '';
  /** 副行：截止时间 · 日历本 */
  subText: string = '';
  color: string = '#007DFF';
  calName: string = '';
  completed: boolean = false;
}

@Component
export struct TodoWidgetBody {
  @Prop dateMd: string = '';
  @Prop weekday: string = '';
  @Prop todoCount: number = 0;
  @Prop todoTodayCount: number = 0;
  @Prop @Watch('onTodoListChange') todoListJson: string = '[]';
  /** 是否为紧凑双行标题栏（4x4 使用双行，6x4 使用单行横向排布） */
  compactHeader: boolean = true;

  @State private cachedTodos: TodoCardItem[] = [];

  aboutToAppear(): void {
    this.onTodoListChange();
  }

  private onTodoListChange(): void {
    try {
      const parsed: Object = JSON.parse(this.todoListJson) as Object;
      this.cachedTodos = Array.isArray(parsed) ? (parsed as TodoCardItem[]) : [];
    } catch (_err) {
      this.cachedTodos = [];
    }
  }

  @Builder
  private addButton() {
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

  private checkTodo(id: number): void {
    postCardAction(this, {
      action: 'message',
      params: { todoCheck: `${id}` }
    });
  }

  @Builder
  private todoRow(item: TodoCardItem) {
    Row({ space: 8 }) {
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
  private headerTitleBadge() {
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
  }

  @Builder
  private headerSubText(fillWeight: boolean) {
    Text(this.todoTodayCount > 0
      ? `${this.dateMd} ${this.weekday} · 今日到期 ${this.todoTodayCount} 项`
      : `${this.dateMd} ${this.weekday} · 今日无到期`)
      .fontSize(10)
      .fontColor(this.todoTodayCount > 0 ? '#FF9500' : '#8A8A8A')
      .maxLines(1)
      .layoutWeight(fillWeight ? 1 : 0)
  }

  @Builder
  private headerBar() {
    Row({ space: 8 }) {
      if (this.compactHeader) {
        Column({ space: 2 }) {
          this.headerTitleBadge()
          this.headerSubText(false)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      } else {
        this.headerTitleBadge()
        this.headerSubText(true)
      }

      this.addButton()
    }
    .width('100%')
  }

  @Builder
  private emptyState() {
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

      if (this.cachedTodos.length === 0) {
        this.emptyState()
      } else {
        List({ space: 4 }) {
          ForEach(this.cachedTodos, (item: TodoCardItem) => {
            ListItem() {
              this.todoRow(item)
            }
          }, (item: TodoCardItem) => `t${item.id}`)
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
