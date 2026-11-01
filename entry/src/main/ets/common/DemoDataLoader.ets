// entry/src/main/ets/common/DemoDataLoader.ets
// 审核测试与免登录体验数据生成器：
// 为华为应用市场审核人员或无 CalDAV 服务器的用户一键载入全套日程与待办演示数据
import { common } from '@kit.AbilityKit';
import { DavAccount, AccountStore, TYPE_CALDAV } from './AccountStore';
import { EventDb, LocalEvent } from './EventDb';
import { LogUtil } from './LogUtil';

export class DemoDataLoader {
  /**
   * 一键载入全套演示数据（账号 + 常用日历本 + 今日/明日日程 + 待办事项）
   */
  static async installDemoData(ctx: common.Context): Promise<void> {
    const accounts = await AccountStore.loadAll(ctx);
    
    // 如果已经存在 demo 账号，则不再重复添加账号
    let demoAcc = accounts.find((a: DavAccount): boolean => a.id.startsWith('demo_acc_'));
    if (demoAcc === undefined) {
      demoAcc = new DavAccount();
      demoAcc.id = 'demo_acc_' + Date.now();
      demoAcc.name = '演示日历账号 (Demo)';
      demoAcc.type = TYPE_CALDAV;
      demoAcc.serverUrl = 'https://demo.synccalendar.local';
      demoAcc.username = 'demo_reviewer';
      demoAcc.calendarHrefs = ['/demo/calendar/'];
      demoAcc.calendarNames = ['工作与生活演示日历'];
      demoAcc.calendarColors = ['#007DFF'];
      demoAcc.calendarWritable = ['1'];
      demoAcc.lastSyncTime = '刚刚';
      demoAcc.itemCount = 1;

      accounts.push(demoAcc);
      await AccountStore.saveAll(ctx, accounts);
    }

    const now = new Date();
    const todayZero = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();

    // 1. 今日日程 1
    const e1 = new LocalEvent();
    e1.uid = 'demo-event-1';
    e1.calKey = demoAcc.id + '_0';
    e1.href = '/demo/calendar/';
    e1.title = '团队每周例会与技术分享';
    e1.location = '总部第一会议室';
    e1.startTime = todayZero + 9 * 3600000 + 30 * 60000;
    e1.endTime = todayZero + 10 * 3600000 + 30 * 60000;
    e1.kind = 'event';
    await EventDb.insertLocal(ctx, e1);

    // 2. 今日日程 2
    const e2 = new LocalEvent();
    e2.uid = 'demo-event-2';
    e2.calKey = demoAcc.id + '_0';
    e2.href = '/demo/calendar/';
    e2.title = '产品体验与架构评审';
    e2.location = '创新研发中心';
    e2.startTime = todayZero + 14 * 3600000;
    e2.endTime = todayZero + 15 * 3600000 + 30 * 60000;
    e2.kind = 'event';
    await EventDb.insertLocal(ctx, e2);

    // 3. 明日日程
    const e3 = new LocalEvent();
    e3.uid = 'demo-event-3';
    e3.calKey = demoAcc.id + '_0';
    e3.href = '/demo/calendar/';
    e3.title = '鸿蒙 NEXT 应用特性评审会';
    e3.location = '线上会议室';
    e3.startTime = todayZero + 86400000 + 10 * 3600000;
    e3.endTime = todayZero + 86400000 + 11 * 3600000 + 30 * 60000;
    e3.kind = 'event';
    await EventDb.insertLocal(ctx, e3);

    // 4. 示例待办 1 (未完成)
    const t1 = new LocalEvent();
    t1.uid = 'demo-todo-1';
    t1.calKey = demoAcc.id + '_0';
    t1.href = '/demo/calendar/';
    t1.title = '提交 10 月度报销发票与项目单据';
    t1.startTime = todayZero + 18 * 3600000;
    t1.endTime = todayZero + 18 * 3600000;
    t1.kind = 'todo';
    t1.completed = false;
    await EventDb.insertLocal(ctx, t1);

    // 5. 示例待办 2 (未完成)
    const t2 = new LocalEvent();
    t2.uid = 'demo-todo-2';
    t2.calKey = demoAcc.id + '_0';
    t2.href = '/demo/calendar/';
    t2.title = '准备产品新版本功能演示文稿';
    t2.startTime = todayZero + 86400000 + 12 * 3600000;
    t2.endTime = todayZero + 86400000 + 12 * 3600000;
    t2.kind = 'todo';
    t2.completed = false;
    await EventDb.insertLocal(ctx, t2);

    // 6. 示例待办 3 (已完成)
    const t3 = new LocalEvent();
    t3.uid = 'demo-todo-3';
    t3.calKey = demoAcc.id + '_0';
    t3.href = '/demo/calendar/';
    t3.title = '小褚日历基础功能初始化验证';
    t3.startTime = todayZero + 8 * 3600000;
    t3.endTime = todayZero + 8 * 3600000;
    t3.kind = 'todo';
    t3.completed = true;
    await EventDb.insertLocal(ctx, t3);

    LogUtil.write('已载入全套演示数据（账号/日程/待办）');
  }
}
