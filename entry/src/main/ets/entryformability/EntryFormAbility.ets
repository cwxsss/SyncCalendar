// entry/src/main/ets/entryformability/EntryFormAbility.ets
// 服务卡片 FormExtensionAbility：添加卡片时注入初始数据，定时/触发时更新
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import process from '@ohos.process';
import { CardDataService, CardData } from '../common/CardDataService';
import { BackgroundSyncRunner } from '../common/BackgroundSyncRunner';
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

  /** 组装更新数据并推送到指定卡片 */
  private pushData(formId: string, dayOffset: number = 0): void {
    CardDataService.buildCardData(this.context, dayOffset).then((data: CardData): void => {
      const binding: formBindingData.FormBindingData =
        formBindingData.createFormBindingData(data);
      formProvider.updateForm(formId, binding).catch((err: BusinessError): void => {
        LogUtil.write(`卡片 ${formId} 更新失败: ${err.message}`);
      });
      LogUtil.write(`卡片 ${formId} 数据已推送`);
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

  /** 卡片上「‹ / › / 回到今天」按钮触发：message 里带 pageAction=prev|next|today */
  onFormEvent(formId: string, message: string): void {
    LogUtil.init(this.context);
    const cur: number = CardDataService.getDayOffset(formId);
    let next: number = cur;
    // 不用 JSON 解析：不同版本 message 的格式可能是 {params:{...}} 或直接 {...}，直接子串匹配更稳
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
}
