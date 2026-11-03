// entry/src/main/ets/entryformability/EntryFormAbility.ets
// 服务卡片 FormExtensionAbility：添加卡片时注入初始数据，定时/触发时更新
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import process from '@ohos.process';
import { CardDataService, CardData } from '../common/CardDataService';
import { BackgroundSyncRunner } from '../common/BackgroundSyncRunner';
import { TodoService } from '../common/TodoService';
import { LogUtil } from '../common/LogUtil';

export default class EntryFormAbility extends FormExtensionAbility {
  /** 当前进程 pid（取不到返回 -1）：用于判断卡片回调是否与主 App 同进程 */
  private static pidOf(): number {
    try {
      return process.pid;
    } catch (err) {
      return -1;
    }
  }

  /**
   * 组装更新数据并推送到指定卡片。
   *
   * ⭐ 一次同时构建「日程」与「待办」两份数据，合并进同一个 binding。
   *    日程卡片只读 eventsJson 等字段，待办卡片只读 todoListJson 等字段，
   *    彼此不会串味。这样无需维护 formId → 卡片类型的映射（那需要持久化，
   *    且系统重启后容易丢失），一套逻辑服务全部 8 张卡片。
   */
  private pushData(formId: string, dayOffset: number = 0): void {
    Promise.all([
      CardDataService.buildCardData(this.context, dayOffset),
      CardDataService.buildTodoCardData(this.context),
    ]).then((results: CardData[]): void => {
      const ev: CardData = results[0];
      const td: CardData = results[1];
      // 待办字段并入日程数据对象（两者都是 CardData，字段不冲突）
      ev.todoListJson = td.todoListJson;
      ev.todoCount = td.todoCount;
      ev.todoTodayCount = td.todoTodayCount;
      const binding: formBindingData.FormBindingData =
        formBindingData.createFormBindingData(ev);
      formProvider.updateForm(formId, binding).catch((err: BusinessError): void => {
        LogUtil.write(`卡片 ${formId} 更新失败: ${err.message}`);
      });
      LogUtil.write(`卡片 ${formId} 数据已推送（日程+待办）`);
    }).catch((err: BusinessError): void => {
      LogUtil.write(`卡片数据构建失败: ${err.message}`);
    });
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    LogUtil.init(this.context);
    let formId: string = '';
    if (want.parameters !== undefined) {
      const raw = want.parameters['ohos.extra.param.key.form_identity'];
      formId = typeof raw === 'string' ? raw : '';
    }
    LogUtil.write(`添加卡片: formId=${formId}`);
    // 先返回空壳初始数据，异步查库后推送真实数据
    if (formId !== '') {
      CardDataService.registerForm(this.context, formId);
      this.pushData(formId);
    }
    const initial = new CardData();
    return formBindingData.createFormBindingData(initial);
  }

  onUpdateForm(formId: string): void {
    LogUtil.init(this.context);
    LogUtil.write(`系统触发卡片更新: formId=${formId}（进程 pid=${EntryFormAbility.pidOf()}）`);
    CardDataService.registerForm(this.context, formId);
    // ⭐ ① 先用**本地缓存**立刻刷新卡片（几毫秒，不依赖网络）
    //    保留用户翻到的日期（系统定时刷新不应把用户翻走的日期拽回今天）
    this.pushData(formId, CardDataService.getDayOffset(formId));
    // ⭐ ② 再借这次系统刷新顺带跑一次后台同步（见 runOnceThrottledByCard：带节流、永不抛错）
    //    同步成功后再推一次，让卡片显示刚同步回来的最新数据。
    //
    // ⚠️ 关键约束（依据官方 FormExtensionAbility 生命周期文档）：
    //    "FormExtensionAbility 进程不能常驻后台，生命周期回调中无法处理长时间的任务，
    //     生命周期调度完成后会继续存在 **10 秒**……可能需要 10 秒以上才能完成的业务逻辑，
    //     建议拉起主应用进行处理。"
    //   ⇒ 本处同步**可能被进程回收中断**。这是**可接受**的，因为：
    //      · 同步是幂等的（基于 etag 增量比对 + dirty 标记），中断不会损坏任何数据；
    //      · 中断只是"这一次没同步成"，下个 30 分钟卡片再刷新时会重试；
    //      · 正常网络下 1~3 个账号的**增量**同步通常数秒内完成，落在 10 秒窗口内。
    //   ⇒ 因此它是"**尽力而为地提高后台同步频率**"，与 workScheduler 2 小时兜底、
    //     回前台/网络恢复补同步共同构成多层保障，**不承诺 30 分钟必然同步成功**。
    //   （不采用"拉起主应用同步"是因为会每 30 分钟弹出一次界面，体验不可接受。）
    BackgroundSyncRunner.runOnceThrottledByCard(this.context).then((): void => {
      this.pushData(formId, CardDataService.getDayOffset(formId));
    }).catch((err: BusinessError): void => {
      LogUtil.write(`卡片驱动同步失败: ${err.message}`);
    });
  }

  onRemoveForm(formId: string): void {
    LogUtil.init(this.context);
    LogUtil.write(`移除卡片: formId=${formId}`);
    CardDataService.unregisterForm(this.context, formId);
    CardDataService.clearDayOffset(formId);
  }

  /**
   * 卡片事件：既处理日程翻页，也处理待办打勾。
   *
   * ⚠️ 不用 JSON.parse 解析 message —— 不同系统版本下格式可能是
   *    `{params:{...}}` 也可能是直接 `{...}`，格式差异会让 JSON 解析拿到 undefined。
   *    统一用**子串匹配**，稳且不依赖具体结构。
   */
  onFormEvent(formId: string, message: string): void {
    LogUtil.init(this.context);

    // ===== 待办打勾：message 里带 todoCheck=<localId> =====
    const checkIdx: number = message.indexOf('todoCheck');
    if (checkIdx >= 0) {
      const m = /todoCheck\D{0,8}(\d+)/.exec(message);
      const localId: number = m !== null ? parseInt(m[1], 10) : 0;
      LogUtil.write(`卡片打勾待办: formId=${formId} localId=${localId} msg=${message}`);
      if (localId > 0) {
        // onFormEvent 是同步回调，这里异步执行但必须兜住 reject，
        // 否则未捕获的 Promise 会让进程异常（FormExtension 生命周期只有 10 秒）
        this.completeTodoFromCard(formId, localId).catch((err: BusinessError): void => {
          LogUtil.write('卡片打勾未捕获异常: ' + err.message);
        });
      }
      return;
    }

    // ===== 日程翻页 =====
    const cur: number = CardDataService.getDayOffset(formId);
    let next: number = cur;
    if (message.indexOf('prev') >= 0) {
      next = cur - 1;
    } else if (message.indexOf('next') >= 0) {
      next = cur + 1;
    } else if (message.indexOf('today') >= 0) {
      next = 0;
    }
    CardDataService.setDayOffset(formId, next);
    LogUtil.write(`卡片翻页: formId=${formId} ${cur} → ${next}`);
    this.pushData(formId, next);
  }

  /**
   * 在卡片上完成一条待办。
   *
   * 时序设计（关键）：
   *  ① **先推一次数据让该条从卡片消失** —— 用户点勾必须立刻有视觉反馈。
   *     但此时库里还没改成 completed，所以这里不等它完成，
   *     而是先推送"排除该 localId"的临时数据（见 pushDataExcludingTodo）。
   *  ② 再真正调 TodoService.setCompleted（内部 GET 原 ics → 改写 → PUT）。
   *  ③ 成功 → 推真实数据（该条已 completed，本来就不在列表里，效果一致）；
   *     失败 → 也推真实数据（该条会重新出现，用户能看出没成功，可重试或进 App 处理）。
   *
   * 为什么不 await 完再推：
   *   FormExtensionAbility 生命周期回调只有 10 秒窗口，
   *   GET+PUT 两步网络在慢网下可能 10 秒以上，卡片会先"卡住不动"再消失，体验很差。
   */
  private async completeTodoFromCard(formId: string, localId: number): Promise<void> {
    // ⭐ 关键：推给**所有**卡片，不只 formId 这一张。
    //    原来只推 formId ⇒ 用户在 A 卡片打勾后，B 卡片仍显示那条待办，
    //    必须在 B 上再点一次才刷新（用户实测反馈）。
    //    每张卡片是独立实例、各持一份数据，必须逐个 updateForm。

    // ① 乐观移除：所有卡片立即不含该条（先给视觉反馈，不等网络）
    await CardDataService.pushToAllForms(this.context, localId);
    // ② 真正落库 + 推送服务器（GET 原 ics → 改写 → PUT）
    let ok: boolean = false;
    try {
      ok = await TodoService.setCompleted(this.context, localId, true);
      LogUtil.write('卡片打勾结果: localId=' + localId + ' ' + (ok ? '成功' : '失败'));
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write('卡片打勾异常: localId=' + localId + ' ' + e.message);
    }
    // ③ 无论成败都再推一次真实数据：
    //    成功 → 该条已 completed，本就不在未完成列表里，各卡片保持一致
    //    失败 → 该条重新出现，用户能看出没成功，可重试
    await CardDataService.pushToAllForms(this.context);
  }

  /** 推送"排除某条待办"的卡片数据（乐观更新用，只改卡片视图，不动数据库） */
  private pushDataExcludingTodo(formId: string, excludeId: number): void {
    Promise.all([
      CardDataService.buildCardData(this.context, CardDataService.getDayOffset(formId)),
      CardDataService.buildTodoCardData(this.context, excludeId),
    ]).then((results: CardData[]): void => {
      const ev: CardData = results[0];
      const td: CardData = results[1];
      ev.todoListJson = td.todoListJson;
      ev.todoCount = td.todoCount;
      ev.todoTodayCount = td.todoTodayCount;
      const binding: formBindingData.FormBindingData =
        formBindingData.createFormBindingData(ev);
      formProvider.updateForm(formId, binding).catch((err: BusinessError): void => {
        LogUtil.write(`卡片 ${formId} 乐观更新失败: ${err.message}`);
      });
    }).catch((err: BusinessError): void => {
      LogUtil.write(`卡片乐观更新数据构建失败: ${err.message}`);
    });
  }
}
