// entry/src/main/ets/pages/widget/TodoWidget4x4.ets
// 4x4 待办服务卡片：顶部标题栏（未完成数 / 今日到期）+ 可滚动待办列表。
import { TodoWidgetBody } from './TodoWidgetShared';

let storageTodo4x4 = new LocalStorage();

@Entry(storageTodo4x4)
@Component
struct TodoWidget4x4Card {
  @LocalStorageProp('dateMd') dateMd: string = '';
  @LocalStorageProp('weekday') weekday: string = '';
  @LocalStorageProp('todoCount') todoCount: number = 0;
  @LocalStorageProp('todoTodayCount') todoTodayCount: number = 0;
  @LocalStorageProp('todoListJson') todoListJson: string = '[]';

  build() {
    Column() {
      TodoWidgetBody({
        dateMd: this.dateMd,
        weekday: this.weekday,
        todoCount: this.todoCount,
        todoTodayCount: this.todoTodayCount,
        todoListJson: this.todoListJson,
        compactHeader: true
      })
    }
    .width('100%')
    .height('100%')
  }
}
