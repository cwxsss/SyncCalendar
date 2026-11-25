// entry/src/main/ets/pages/widget/TodoWidget6x4.ets
// 6x4 待办服务卡片：横向扩展待办列表。
import { TodoWidgetBody } from './TodoWidgetShared';

let storageTodo6x4 = new LocalStorage();

@Entry(storageTodo6x4)
@Component
struct TodoWidget6x4Card {
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
        compactHeader: false
      })
    }
    .width('100%')
    .height('100%')
  }
}
