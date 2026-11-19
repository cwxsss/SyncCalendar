// entry/src/main/ets/pages/widget/TodoWidget2x4.ets
// 2x4 待办服务卡片：左侧 = 未完成总数 + 今日到期（同 2x2）；右侧 = 最近 2 条待办。
// 右侧带**圆形勾选框**，点击即完成并推送回服务器。
let storageTodo2x4 = new LocalStorage();

/** 待办卡片单条（解析 todoListJson） */
class TodoItem2x4 {
  id: number = 0;
  title: string = '';
  dueText: string = '';
  /** 副行：截止时间 · 日历本 */
  subText: string = '';
  color: string = '#007DFF';
  calName: string = '';
  completed: boolean = false;
}

@Entry(storageTodo2x4)
@Component
struct TodoWidget2x4Card {
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('lunarText') lunarText: string = '';
  @LocalStorageProp('todoCount') todoCount: number = 0;
  @LocalStorageProp('todoTodayCount') todoTodayCount: number = 0;
  @LocalStorageProp('todoListJson') todoListJson: string = '[]';

  /** 右侧列表数据（可滚动；数据侧已按截止时间排序并限制在 20 条内） */
  private parseTodos(): TodoItem2x4[] {
    try {
      return JSON.parse(this.todoListJson) as TodoItem2x4[];
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

  /** 打开 App 并进入待办 Tab */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { widgetAction: 'openTodo' }
    });
  }

  /**
   * 点击圆形勾选框 → 让 FormExtensionAbility 去完成这条待办。
   *
   * ⭐ 用 message 而不是 call：message 会进入 onFormEvent，能在
   *    FormExtension 的 10 秒窗口内完成"改库 + PUT 推送 + 刷新卡片"，
   *    不需要拉起主 App（拉起会闪界面，体验差）。
   * ⭐ 带上 localId：卡片只知道自己渲染的是哪一条，改库要靠主键。
   */
  private checkTodo(id: number): void {
    postCardAction(this, {
      action: 'message',
      params: { todoCheck: `${id}` }
    });
  }

  /** 右侧单条待办：勾选框 + 标题 + 截止时间 */
  /**
   * 单条待办：与 4×4 / 6×4 同款结构（圆圈用日历本色 + 标题 + 副行），
   * 尺寸再收一档 —— 2×4 只有 2 格高，圈 16 / 标题 12 / 副行 9。
   */
  @Builder
  todoRow(item: TodoItem2x4) {
    Row({ space: 6 }) {
      // 勾选圈：颜色用日历本色，点击即完成
      Row() {
        Text('')
          .width(16)
          .height(16)
          .borderRadius(8)
          .border({ width: 2, color: item.color })
      }
      .padding({ right: 2 })
      .onClick(() => {
        this.checkTodo(item.id);
      })

      Column({ space: 1 }) {
        Text(item.title)
          .fontSize(12)
          .fontColor('#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.subText)
          .fontSize(9)
          .fontColor('#8A8A8A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 4, right: 8, top: 5, bottom: 5 })
    .borderRadius(9)
    .backgroundColor('#F5F7FA')
  }

  /** 右侧空态 */
  @Builder
  emptyHint() {
    Column({ space: 4 }) {
      Text(this.todoCount === 0 ? '暂无待办' : '今日无到期')
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
      // ===== 左半：未完成总数 =====
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Column({ space: 2 }) {
            Text(this.dateMd)
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
          Text(`${this.todoCount}`)
            .fontSize(38)
            .fontWeight(FontWeight.Bold)
            .fontColor('#6A4C93')
          Column({ space: 2 }) {
            Text('待办未完成')
              .fontSize(11)
              .fontColor('#1A1A1A')
              .maxLines(1)
            Text(this.todoTodayCount > 0 ? `今日到期 ${this.todoTodayCount} 项`
              : (this.todoCount === 0 ? '点击添加' : '今日无到期'))
              .fontSize(9)
              .fontColor(this.todoTodayCount > 0 ? '#FF9500' : '#8A8A8A')
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

      // ===== 右半：最近 2 条待办（可打勾）=====
      Column() {
        if (this.parseTodos().length === 0) {
          this.emptyHint()
        } else {
          // ⭐ List 可滚动：2x4 原来只渲染固定 2 条（Column + slice），
          //    待办是清单性质、条数常十几条，只看 2 条价值太低。
          //    List 自带虚拟化与滚动惯性，条目多也不占内存。
          List({ space: 3 }) {
            ForEach(this.parseTodos(), (item: TodoItem2x4, idx: number) => {
              ListItem() {
                this.todoRow(item)
              }
            }, (item: TodoItem2x4, idx: number) => `t${item.id}_${idx}`)
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
    .onClick(() => this.openApp())
  }
}